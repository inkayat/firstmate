#!/usr/bin/env bash
# tests/fm-console-signals.test.sh - the fm-console-signals.v1 producer.
#
# Drives bin/fm-console-signals.sh against synthetic homes only: a live captain
# hold made through the real bin/fm-captain-hold.sh, handwritten backlog rows
# for hostile and bucketed holds, a stand-in bot lister that answers the
# `fm-bot list --json` / `show NAME --json` interface, and a renamed process as
# the session-lock holder. Every produced file is checked field by field by an
# independent checker written from the consumer's contract (Astro
# docs/firstmate-console-signals.md): bounds in bytes, id rules, unique ids,
# question_id naming a listed question, the 64 KiB cap, and no control
# characters or escape sequences.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

SIGNALS="$ROOT/bin/fm-console-signals.sh"
TMP_ROOT=$(fm_test_tmproot fm-console-signals)
CHECKER="$TMP_ROOT/check.py"
HOLDER_PIDS=()

cleanup() {
  local pid
  for pid in "${HOLDER_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup EXIT

# The consumer-side contract, independent of the producer's code.
cat > "$CHECKER" <<'PY'
import json, os, re, stat, sys, datetime

path, home, lock_pid = sys.argv[1], sys.argv[2], int(sys.argv[3])
errors = []
def err(msg):
    errors.append(msg)

st = os.lstat(path)
if not stat.S_ISREG(st.st_mode):
    err("not a regular file")
raw = open(path, "rb").read()
if len(raw) > 65536:
    err("over 64 KiB")
try:
    doc = json.loads(raw.decode("utf-8"))
except Exception as exc:
    print("invalid json: %s" % exc)
    sys.exit(1)
if not isinstance(doc, dict):
    print("not an object"); sys.exit(1)

ID = re.compile(r"[A-Za-z0-9._-]{1,64}\Z")
def is_id(v):
    return isinstance(v, str) and ID.match(v) and not v.startswith(".") and ".." not in v

def text(where, v, lo, hi, one_line):
    if not isinstance(v, str):
        err("%s: not a string" % where); return
    n = len(v.encode("utf-8"))
    if n < lo or n > hi:
        err("%s: %d bytes outside %d-%d" % (where, n, lo, hi))
    for ch in v:
        o = ord(ch)
        if ch == "\n" and not one_line:
            continue
        if o < 0x20 or o == 0x7f or 0x80 <= o <= 0x9f:
            err("%s: control character U+%04X" % (where, o)); break
    if "\x1b" in v:
        err("%s: escape sequence" % where)
    if lo and not v.strip():
        err("%s: empty after trimming" % where)

def when(where, v):
    if not isinstance(v, str):
        err("%s: not a string" % where); return None
    try:
        return datetime.datetime.fromisoformat(v.replace("Z", "+00:00"))
    except ValueError:
        err("%s: not RFC 3339: %r" % (where, v)); return None

if doc.get("schema") != "fm-console-signals.v1":
    err("schema")
if doc.get("home") != home:
    err("home %r != %r" % (doc.get("home"), home))
if type(doc.get("lock_pid")) is not int or doc.get("lock_pid") != lock_pid:
    err("lock_pid %r != %r" % (doc.get("lock_pid"), lock_pid))
gen = when("generated_at", doc.get("generated_at"))
if gen is not None:
    skew = (gen - datetime.datetime.now(datetime.timezone.utc)).total_seconds()
    if skew > 60 or skew < -120:
        err("generated_at not current (%.0f s)" % skew)

qs = doc.get("questions", [])
if not isinstance(qs, list) or len(qs) > 4:
    err("questions: not a list of at most 4")
    qs = []
qids = set()
for i, q in enumerate(qs):
    w = "questions[%d]" % i
    if not is_id(q.get("id")) or q.get("id") in qids:
        err("%s.id bad or duplicate: %r" % (w, q.get("id")))
    qids.add(q.get("id"))
    text(w + ".text", q.get("text"), 1, 2048, False)
    if "topic" in q:
        text(w + ".topic", q["topic"], 0, 80, True)
    if "since" in q:
        when(w + ".since", q["since"])
    opts = q.get("options", [])
    if not isinstance(opts, list) or len(opts) > 6:
        err(w + ".options")
        opts = []
    oids = set()
    for k, o in enumerate(opts):
        if not is_id(o.get("id")) or o.get("id") in oids:
            err("%s.options[%d].id" % (w, k))
        oids.add(o.get("id"))
        text("%s.options[%d].label" % (w, k), o.get("label"), 1, 48, True)

wt = doc.get("waiting")
if wt is not None:
    if wt.get("state") == "waiting":
        text("waiting.reason", wt.get("reason"), 1, 256, True)
        if "question_id" in wt and wt["question_id"] not in qids:
            err("waiting.question_id names no listed question")
        if "since" in wt:
            when("waiting.since", wt["since"])
    elif wt.get("state") != "none":
        err("waiting.state")

bots = doc.get("bots", [])
if not isinstance(bots, list) or len(bots) > 32:
    err("bots: not a list of at most 32")
    bots = []
bids = set()
for i, b in enumerate(bots):
    w = "bots[%d]" % i
    if not is_id(b.get("id")) or b.get("id") in bids:
        err("%s.id bad or duplicate: %r" % (w, b.get("id")))
    bids.add(b.get("id"))
    text(w + ".name", b.get("name"), 1, 64, True)
    if type(b.get("enabled")) is not bool:
        err(w + ".enabled")
    if b.get("state") not in ("idle", "due", "running", "paused", "unknown"):
        err("%s.state %r" % (w, b.get("state")))
    for key, hi in (("schedule", 80), ("scope", 160), ("project", 64)):
        if key in b:
            text("%s.%s" % (w, key), b[key], 0, hi, True)
    for key in ("last_run", "next_due"):
        if key in b:
            when("%s.%s" % (w, key), b[key])

if errors:
    print("\n".join(errors))
    sys.exit(1)
PY

# make_home <name>: a canonical synthetic home with an empty markdown backlog.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

# hold_lock <home>: a live process whose name is a verified harness holds the
# home's session lock, the way a primary does; sets LOCK_PID. Called in this
# shell, never in a command substitution, so cleanup can stop the holder.
LOCK_PID=
hold_lock() {
  local home=$1 i=0
  perl -e '$0="claude"; sleep 300' </dev/null >/dev/null 2>&1 &
  LOCK_PID=$!
  HOLDER_PIDS+=("$LOCK_PID")
  while [ "$(ps -o comm= -p "$LOCK_PID" 2>/dev/null)" != claude ] && [ "$i" -lt 100 ]; do
    sleep 0.02
    i=$((i + 1))
  done
  printf '%s\n' "$LOCK_PID" > "$home/state/.lock"
}

# make_lister <dir>: a stand-in for the bot code's list/show interface, read
# from <dir>/bin/fm-bot and answering from <dir>/fixture/. It logs each call
# with the home and code root it was given.
make_lister() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/fixture"
  cat > "$dir/bin/fm-bot" <<'SH'
#!/usr/bin/env bash
dir=$(cd "$(dirname "$0")/.." && pwd)
printf '%s|FM_HOME=%s|FIRSTMATE_ROOT=%s\n' "$*" "${FM_HOME:-}" "${FIRSTMATE_ROOT:-}" >> "$dir/calls.log"
[ ! -e "$dir/fixture/hang" ] || exec sleep 60
case "$1 ${2:-} ${3:-}" in
  "list --json ") cat "$dir/fixture/list.json"; exit 0 ;;
  "show "*" --json")
    if [ -f "$dir/fixture/show-$2.json" ]; then cat "$dir/fixture/show-$2.json"; exit 0; fi
    echo "fm-bot: bot '$2' spec is invalid" >&2; exit 1 ;;
esac
echo "fm-bot: unexpected call: $*" >&2
exit 2
SH
  chmod +x "$dir/bin/fm-bot"
  printf '[]\n' > "$dir/fixture/list.json"
}

run_signals() {  # <home> <config-root> <args...>
  local home=$1 config_root=$2
  shift 2
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    FM_HOME="$home" FM_CONFIG_ROOT="$config_root" PATH="$PATH" "$SIGNALS" "$@"
}

run_captain() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

check() {  # <file> <home> <lock-pid> <message>
  local out
  out=$(python3 "$CHECKER" "$1" "$2" "$3" 2>&1) || fail "$4: $out"
}

utc_ago() {  # <seconds>
  python3 -c 'import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"
}

# held_row <id> <title> <reason> <hold-set> [extra metadata]: one captain-held
# queued backlog row in the format bin/fm-captain-hold.sh writes, with the
# reason stored through the one reversible hold-reason encoding.
held_row() {
  local id=$1 title=$2 reason=$3 set=$4 extra=${5:-} encoded
  # shellcheck source=bin/fm-hold-reason-lib.sh
  encoded=$(. "$ROOT/bin/fm-hold-reason-lib.sh" && fm_hold_reason_encode "$reason")
  printf -- '- [ ] %s - %s (repo: sample) (kind: captain) (since %s)%s (hold: %s) (hold-kind: captain)\n  Captain hold set: %s\n' \
    "$id" "$title" "${set%%T*}" "$extra" "$encoded" "$set"
}

write_backlog() {  # <home> <queued rows> [in-flight rows]
  { printf '%s\n' '## In flight'; printf '%s' "${3:-}"; printf '\n%s\n' '## Queued'; printf '%s' "$2"; printf '\n%s\n' '## Done'; } \
    > "$1/data/backlog.md"
}

# --- refusals -------------------------------------------------------------

test_requires_explicit_home() {
  local home out rc
  home=$(make_home no-home)
  out=$(env -u FM_HOME "$SIGNALS" write 2>&1) && fail "write without FM_HOME must refuse"
  assert_contains "$out" "FM_HOME" "the refusal must name FM_HOME"
  rc=0
  FM_HOME= "$SIGNALS" print >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "print with an empty FM_HOME must refuse"
  assert_absent "$home/state/console-signals.json" "a refused run must write nothing"
  "$SIGNALS" --help | grep -q 'fm-console-signals.v1' || fail "--help must name the contract"
  pass "the producer refuses without an explicit FM_HOME"
}

# --- lock binding -----------------------------------------------------------

test_lock_binding() {
  local home link pid out rc
  home=$(make_home lock)
  link="$TMP_ROOT/lock-link"
  ln -s "$home" "$link"

  # Free lock: nothing is published, and a leftover file is removed.
  printf '{"stale":true}\n' > "$home/state/console-signals.json"
  run_signals "$link" "" write 2>/dev/null || fail "write with a free lock must exit 0"
  assert_absent "$home/state/console-signals.json" "a free lock must leave no signals file"
  rc=0
  out=$(run_signals "$link" "" print 2>/dev/null) || rc=$?
  assert_equals 3 "$rc" "print with a free lock reports nothing to publish"
  assert_equals "" "$out" "print with a free lock prints no document"

  # Stale lock (dead pid): the same.
  printf '999999\n' > "$home/state/.lock"
  printf '{"stale":true}\n' > "$home/state/console-signals.json"
  run_signals "$link" "" write 2>/dev/null || fail "write with a stale lock must exit 0"
  assert_absent "$home/state/console-signals.json" "a stale lock must leave no signals file"

  # Held lock: the file names the canonical home and the holder pid, and the
  # lock record itself is untouched.
  hold_lock "$home"; pid=$LOCK_PID
  run_signals "$link" "" write || fail "write with a held lock failed"
  check "$home/state/console-signals.json" "$home" "$pid" "held-lock file"
  assert_equals "$pid" "$(cat "$home/state/.lock")" "the producer must not touch the session lock"
  pass "the file is bound to the held lock's pid and the canonical home, and absent without a held lock"
}

# --- empty state ------------------------------------------------------------

test_empty_state() {
  local home pid out
  home=$(make_home empty)
  hold_lock "$home"; pid=$LOCK_PID
  out=$(run_signals "$home" "" print) || fail "print on an empty home failed"
  printf '%s' "$out" > "$TMP_ROOT/empty.json"
  check "$TMP_ROOT/empty.json" "$home" "$pid" "empty-home document"
  assert_equals 'none|0|0' \
    "$(printf '%s' "$out" | jq -r '"\(.waiting.state // "none")|\(.questions // [] | length)|\(.bots // [] | length)"')" \
    "an empty home waits on nothing and lists no questions or bots"
  assert_absent "$home/state/console-signals.json" "print must not write"
  pass "an empty home publishes a valid document with nothing waiting"
}

# --- live holds -------------------------------------------------------------

test_live_hold_through_real_hold() {
  local home pid doc
  home=$(make_home real-hold)
  hold_lock "$home"; pid=$LOCK_PID
  run_captain "$home" hold launch-q --title "App launch behavior" \
    --reason $'How should a shortcut open an app (already running)?\nReuse or open new.' \
    --repo sample >/dev/null || fail "fm-captain-hold.sh hold failed"
  run_signals "$home" "" write || fail "write failed"
  check "$home/state/console-signals.json" "$home" "$pid" "real-hold file"
  doc=$(cat "$home/state/console-signals.json")
  assert_equals 'waiting|App launch behavior|launch-q' \
    "$(printf '%s' "$doc" | jq -r '"\(.waiting.state)|\(.waiting.reason)|\(.waiting.question_id)"')" \
    "a live hold makes FirstMate wait on its question"
  assert_equals $'How should a shortcut open an app (already running)?\nReuse or open new.' \
    "$(printf '%s' "$doc" | jq -r '.questions[0].text')" "the question text is the decoded hold reason, line breaks kept"
  assert_equals 'launch-q|App launch behavior|false' \
    "$(printf '%s' "$doc" | jq -r '.questions[0] | "\(.id)|\(.topic)|\(has("options"))"')" \
    "the question carries id and topic and invents no options"
  [ "$(printf '%s' "$doc" | jq -r '.questions[0].since == .waiting.since and (.waiting.since | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))')" = true ] \
    || fail "the hold time must be the question's and the wait's since"

  # Answering the call clears the wait on the next write.
  printf 'Reuse the running instance.\n' > "$TMP_ROOT/answer.txt"
  run_captain "$home" answer launch-q --decision-file "$TMP_ROOT/answer.txt" >/dev/null \
    || fail "answer failed"
  run_signals "$home" "" write || fail "write after the answer failed"
  check "$home/state/console-signals.json" "$home" "$pid" "answered file"
  assert_equals 'none|0' \
    "$(jq -r '"\(.waiting.state // "none")|\(.questions // [] | length)"' "$home/state/console-signals.json")" \
    "a recorded answer clears the wait and the question"
  pass "a live captain hold becomes the waiting question and clears when answered"
}

test_only_live_holds_newest_first_capped() {
  local home pid rows i doc
  home=$(make_home buckets)
  hold_lock "$home"; pid=$LOCK_PID
  rows=
  for i in 1 2 3 4 5 6; do
    rows+=$(held_row "call-$i" "Call $i" "Question $i?" "$(utc_ago $((7000 - i * 60)))")$'\n'
  done
  rows+=$(held_row dated "Deferred call" "Later?" "$(utc_ago 60)" " (hold-until: 2099-01-01)")$'\n'
  rows+=$(held_row blocked "Blocked call" "Blocked?" "$(utc_ago 60)" " (blocked-by: call-1)")$'\n'
  rows+=$(held_row aged "Old call" "Old?" "2020-01-01T00:00:00Z")$'\n'
  write_backlog "$home" "$rows"
  run_signals "$home" "" write || fail "write failed"
  check "$home/state/console-signals.json" "$home" "$pid" "bucketed file"
  doc=$(cat "$home/state/console-signals.json")
  assert_equals 'call-6,call-5,call-4,call-3' "$(printf '%s' "$doc" | jq -r '[.questions[].id] | join(",")')" \
    "only live holds, newest hold first, at most four"
  assert_equals 'call-6|Call 6' "$(printf '%s' "$doc" | jq -r '"\(.waiting.question_id)|\(.waiting.reason)"')" \
    "the wait names the first question"
  pass "dated, blocked, and aged holds never wait; live holds are newest first and capped at four"
}

test_hostile_hold_content() {
  local home pid title reason long doc
  home=$(make_home hostile)
  hold_lock "$home"; pid=$LOCK_PID
  # A title whose 80-byte cut lands inside a three-byte rune, with an escape
  # sequence and a bell; a reason with CR LF, colour and OSC sequences, C0/C1
  # controls, and far more than 2048 bytes of multibyte text.
  title=$'\e[31mÖ'"$(printf 'ş%.0s' $(seq 1 30))"$'\a'"$(printf '€%.0s' $(seq 1 20))"
  long=$(printf 'ğ€%.0s' $(seq 1 700))
  reason=$'Line one\r\nLine two\e]0;title\a\e[1mbold\e[0m\x01\x7f'$'\xc2\x85'"$long"
  write_backlog "$home" "$(held_row 'Weird..id/with:colon' "$title" "$reason" "$(utc_ago 30)")"$'\n'"$(held_row '.dot-led' "Second" "  " "$(utc_ago 90)")"$'\n'
  run_signals "$home" "" write 2>/dev/null || fail "write failed on hostile content"
  check "$home/state/console-signals.json" "$home" "$pid" "hostile-content file"
  doc=$(cat "$home/state/console-signals.json")
  assert_equals 'Weird.id-with-colon' "$(printf '%s' "$doc" | jq -r '.questions[0].id')" \
    "a task id is reduced to the contract's id alphabet"
  assert_equals 'dot-led' "$(printf '%s' "$doc" | jq -r '.questions[1].id')" "an id never starts with a dot"
  assert_equals 'Second' "$(printf '%s' "$doc" | jq -r '.questions[1].text')" \
    "a blank reason falls back to the topic so the required text is never empty"
  case "$(printf '%s' "$doc" | jq -r '.questions[0].text')" in
    $'Line one\nLine two'*) ;;
    *) fail "CR LF must become a kept line break, escapes removed" ;;
  esac
  assert_equals true "$(printf '%s' "$doc" | jq -r '.questions[0].text | split("\n")[1] | startswith("Line twoboldğ€")')" \
    "escape sequences are removed whole, controls dropped, and nothing of them is left as text"
  assert_equals "Ö$(printf 'ş%.0s' $(seq 1 30))€€€€€…" "$(printf '%s' "$doc" | jq -r '.questions[0].topic')" \
    "the topic is cleaned, then cut to 80 bytes on a rune boundary with an ellipsis"
  pass "hostile hold ids, titles, and reasons are cut on rune boundaries and cleaned"
}

# --- bots -------------------------------------------------------------------

test_bots_from_lister() {
  local home pid lister doc err
  home=$(make_home bots)
  hold_lock "$home"; pid=$LOCK_PID
  lister="$TMP_ROOT/bots-config"
  make_lister "$lister"
  cat > "$lister/fixture/list.json" <<'JSON'
[{"name":"broken","spec":"data/bots/broken.md","state":"invalid","detail":"unparseable spec line: 'garbage'","last_run":"none"},
 {"name":"gone","spec":"data/bots/gone.md","state":"active","project":"sample","schedule":"daily 09:00-10:00 Europe/Stockholm","next":"in window now","last_run":"none"},
 {"name":"nightly","spec":"data/bots/nightly.md","state":"active","project":"astro","schedule":"daily 09:00-10:00 Europe/Stockholm","next":"2026-11-01 09:00 CET","last_run":"nightly-20261030"},
 {"name":"runner","spec":"data/bots/runner.md","state":"active","project":"astro","schedule":"daily 09:00-10:00 Europe/Stockholm","next":"2026-11-01 09:00 CET","last_run":"runner-20261031"},
 {"name":"sweeper","spec":"data/bots/sweeper.md","state":"paused","project":"astro","schedule":"every 6 elapsed hours from 2026-10-31T19:12:42Z","next":"paused","last_run":"none"},
 {"name":"window","spec":"data/bots/window.md","state":"active","project":"astro","schedule":"mon,fri 09:00-10:00 Europe/Stockholm","next":"in window now","last_run":"none"},
 {"name":"watcher","spec":"data/bots/watcher.md","state":"active","project":"astro","schedule":"remote origin branch main","next":"next successful remote observation","last_run":"none"}]
JSON
  printf '%s' '{"name":"nightly","state":"active","project":"astro","days":"daily","at":"09:00","until":"10:00","scope":"Scan the repo\u001b[31m and report","next":"2026-11-01 09:00 CET","last_run":"nightly-20261030","level":"local-proposal"}' > "$lister/fixture/show-nightly.json"
  printf '%s' '{"name":"runner","state":"active","project":"astro","days":"daily","at":"09:00","until":"10:00","scope":"Run","next":"2026-11-01 09:00 CET","last_run":"runner-20261031"}' > "$lister/fixture/show-runner.json"
  printf '%s' '{"name":"sweeper","state":"paused","project":"astro","trigger":"interval","every_hours":"6","interval_anchor":"2026-10-31T19:12:42Z","scope":"Sweep","next":"paused","last_run":"none"}' > "$lister/fixture/show-sweeper.json"
  printf '%s' '{"name":"window","state":"active","project":"astro","days":"mon,fri","at":"09:00","until":"10:00","scope":"Window","next":"in window now","last_run":"none"}' > "$lister/fixture/show-window.json"
  printf '%s' '{"name":"watcher","state":"active","project":"astro","trigger":"remote","on_remote":"origin","on_branch":"main","scope":"Watch main","next":"next successful remote observation","last_run":"none"}' > "$lister/fixture/show-watcher.json"
  write_backlog "$home" "" "- [ ] runner-20261031 - Bot run (repo: astro) (kind: scout) (since 2026-10-31)"$'\n'
  err=$(run_signals "$home" "$lister" write 2>&1 >/dev/null) || fail "write failed with bots: $err"
  check "$home/state/console-signals.json" "$home" "$pid" "bots file"
  doc=$(cat "$home/state/console-signals.json")
  assert_equals 'nightly|true|idle|daily 09:00-10:00|Scan the repo and report|astro|2026-11-01T08:00:00Z' \
    "$(printf '%s' "$doc" | jq -r '.bots[] | select(.id == "nightly") | "\(.name)|\(.enabled)|\(.state)|\(.schedule)|\(.scope)|\(.project)|\(.next_due)"')" \
    "an active daily bot outside its window is idle with its schedule, scope, and next window"
  assert_equals 'running' "$(printf '%s' "$doc" | jq -r '.bots[] | select(.id == "runner") | .state')" \
    "a bot whose last run is in flight is running"
  assert_equals 'false|paused|every 6 h' \
    "$(printf '%s' "$doc" | jq -r '.bots[] | select(.id == "sweeper") | "\(.enabled)|\(.state)|\(.schedule)"')" \
    "a paused interval bot is disabled and paused"
  assert_equals 'due|mon,fri 09:00-10:00' \
    "$(printf '%s' "$doc" | jq -r '.bots[] | select(.id == "window") | "\(.state)|\(.schedule)"')" \
    "a daily bot the bot code reports in its window now is due"
  assert_equals 'unknown|on origin/main' \
    "$(printf '%s' "$doc" | jq -r '.bots[] | select(.id == "watcher") | "\(.state)|\(.schedule)"')" \
    "an active remote bot that is not running cannot be told apart, so it is unknown"
  assert_equals 'nightly,runner,sweeper,window,watcher' "$(printf '%s' "$doc" | jq -r '[.bots[].id] | join(",")')" \
    "invalid and unreadable specs are skipped, the rest keep the lister's order"
  assert_contains "$err" "broken" "a skipped invalid spec is named on stderr"
  assert_contains "$err" "gone" "a spec the lister cannot show is named on stderr"
  assert_not_contains "$(cat "$lister/calls.log")" "check-install" "the producer never installs the bot check"
  assert_not_contains "$(cat "$lister/calls.log")" "due" "the producer never runs a due evaluation"
  grep -q "^list --json|FM_HOME=$home|FIRSTMATE_ROOT=$ROOT\$" "$lister/calls.log" \
    || fail "the lister must be called with this home and code root: $(cat "$lister/calls.log")"
  pass "bots come from the bot code's list and show interface; broken specs are skipped with a reason"
}

test_bot_cap_and_missing_lister() {
  local home pid lister i list err rows=
  home=$(make_home many-bots)
  hold_lock "$home"; pid=$LOCK_PID
  lister="$TMP_ROOT/many-config"
  make_lister "$lister"
  list='['
  for i in $(seq -w 1 40); do
    [ "$i" = 01 ] || list+=','
    list+="{\"name\":\"bot-$i\",\"state\":\"active\",\"project\":\"$(printf 'p%.0s' $(seq 1 100))\",\"schedule\":\"daily 09:00-10:00 Europe/Stockholm\",\"next\":\"2026-11-01 09:00 CET\",\"last_run\":\"none\"}"
    printf '{"name":"bot-%s","state":"active","project":"%s","days":"daily","at":"09:00","until":"10:00","scope":"%s","next":"2026-11-01 09:00 CET","last_run":"none"}' \
      "$i" "$(printf 'p%.0s' $(seq 1 100))" "$(printf 'ş%.0s' $(seq 1 300))" > "$lister/fixture/show-bot-$i.json"
  done
  printf '%s]\n' "$list" > "$lister/fixture/list.json"
  for i in 1 2 3 4; do
    rows+=$(held_row "big-$i" "$(printf 'Ü%.0s' $(seq 1 100))" "$(printf '€%.0s' $(seq 1 3000))" "$(utc_ago $((i * 10)))")$'\n'
  done
  write_backlog "$home" "$rows"
  run_signals "$home" "$lister" write 2>/dev/null || fail "write failed at the bounds"
  check "$home/state/console-signals.json" "$home" "$pid" "bounded file"
  assert_equals 32 "$(jq '.bots | length' "$home/state/console-signals.json")" "at most 32 bots are listed"
  [ "$(wc -c < "$home/state/console-signals.json")" -le 65536 ] || fail "the file must stay within 64 KiB"

  # A home with bot specs but no reachable lister still publishes, without bots.
  mkdir -p "$home/data/bots"
  err=$(run_signals "$home" "$TMP_ROOT/no-such-config" write 2>&1 >/dev/null) || fail "write without a lister failed"
  check "$home/state/console-signals.json" "$home" "$pid" "lister-less file"
  assert_equals 0 "$(jq '.bots // [] | length' "$home/state/console-signals.json")" "no lister lists no bots"
  assert_contains "$err" "fm-bot" "a missing lister is reported on stderr"
  pass "bounds hold at the contract's maxima, and a missing lister drops only the bots"
}

# --- file discipline --------------------------------------------------------

test_atomic_fresh_and_contained() {
  local home pid before after first second writer i
  home=$(make_home atomic)
  hold_lock "$home"; pid=$LOCK_PID
  write_backlog "$home" "$(held_row call "Call" "$(printf 'x%.0s' $(seq 1 1500))" "$(utc_ago 30)")"$'\n'
  run_signals "$home" "" write || fail "first write failed"
  first=$(jq -r .generated_at "$home/state/console-signals.json")
  sleep 1.2
  run_signals "$home" "" write || fail "second write failed"
  second=$(jq -r .generated_at "$home/state/console-signals.json")
  [ "$second" \> "$first" ] || fail "a rewrite must refresh generated_at ($first -> $second)"
  assert_equals "$(jq -S 'del(.generated_at)' <<<"$(run_signals "$home" "" print)")" \
    "$(jq -S 'del(.generated_at)' "$home/state/console-signals.json")" "print shows what write publishes"

  # Readers never see a partial file while writes repeat.
  ( for i in $(seq 1 12); do run_signals "$home" "" write 2>/dev/null; done ) &
  writer=$!
  python3 - "$home/state/console-signals.json" "$writer" <<'PY' || fail "a reader saw a partial or missing file"
import json, os, sys
path, writer = sys.argv[1], int(sys.argv[2])
while True:
    try:
        os.kill(writer, 0)
        alive = True
    except OSError:
        alive = False
    with open(path, "rb") as f:
        json.loads(f.read())
    if not alive:
        break
PY
  wait "$writer" 2>/dev/null || true

  # Nothing outside state/console-signals.json changed, and no temp file stayed.
  before=$(cd "$home" && find . -path ./state/console-signals.json -prune -o -type f -print0 | sort -z | xargs -0 cksum)
  run_signals "$home" "" write || fail "containment write failed"
  after=$(cd "$home" && find . -path ./state/console-signals.json -prune -o -type f -print0 | sort -z | xargs -0 cksum)
  assert_equals "$before" "$after" "a write changes nothing but its own file"
  assert_equals "" "$(find "$home/state" -name '*console-signals*' ! -name console-signals.json)" \
    "no temporary file remains in state/"
  pass "writes are atomic, refresh generated_at, and touch nothing else"
}

# --- watcher wiring ---------------------------------------------------------

start_watcher() {  # <home> <config-root>
  fm_test_track_watcher_state "$1/state"
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$1/config" FM_CONFIG_ROOT="$2" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1 &
}

stop_watcher() {  # <home>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
}

beat_epoch() {  # <file>
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

test_watcher_publishes_only_when_opted_in() {
  local on off hang lister pid_on i first_beat later_beat
  on=$(make_home watch-on)
  off=$(make_home watch-off)
  hang=$(make_home watch-hang)
  hold_lock "$on"; pid_on=$LOCK_PID
  hold_lock "$off"
  hold_lock "$hang"
  touch "$on/config/console-signals" "$hang/config/console-signals"
  write_backlog "$on" "$(held_row call "Watched call" "Watched?" "$(utc_ago 30)")"$'\n'
  lister="$TMP_ROOT/hang-config"
  make_lister "$lister"
  touch "$lister/fixture/hang"
  start_watcher "$on" ""
  start_watcher "$off" ""
  start_watcher "$hang" "$lister"
  i=0
  while [ "$i" -lt 100 ] && { [ ! -s "$on/state/console-signals.json" ] || [ ! -e "$off/state/.last-watcher-beat" ] || [ ! -s "$lister/calls.log" ]; }; do
    sleep 0.1
    i=$((i + 1))
  done
  grep -q '^list --json' "$lister/calls.log" 2>/dev/null || fail "the opted-in watcher must have reached the hanging bot lister"
  first_beat=$(beat_epoch "$hang/state/.last-watcher-beat")
  later_beat=$first_beat
  i=0
  while [ "$later_beat" -le "$first_beat" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    later_beat=$(beat_epoch "$hang/state/.last-watcher-beat")
    i=$((i + 1))
  done
  stop_watcher "$on"
  stop_watcher "$off"
  stop_watcher "$hang"
  check "$on/state/console-signals.json" "$on" "$pid_on" "watcher-published file"
  assert_equals call "$(jq -r .waiting.question_id "$on/state/console-signals.json")" "the watcher publishes the live hold"
  assert_present "$off/state/.last-watcher-beat" "the unconfigured watcher must have polled"
  assert_absent "$off/state/console-signals.json" "an unconfigured home publishes nothing"
  [ "$later_beat" -gt "$first_beat" ] || fail "a hanging bot lister must not stall the watcher's poll loop"
  pass "the watcher publishes only for an opted-in home, and a hanging producer never stalls it"
}

test_requires_explicit_home
test_lock_binding
test_empty_state
test_live_hold_through_real_hold
test_only_live_holds_newest_first_capped
test_hostile_hold_content
test_bots_from_lister
test_bot_cap_and_missing_lister
test_atomic_fresh_and_contained
test_watcher_publishes_only_when_opted_in

echo '# all fm-console-signals tests passed'
