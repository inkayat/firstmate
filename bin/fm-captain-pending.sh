#!/usr/bin/env bash
# fm-captain-pending.sh - the durable captain-pending ledger, and the one
# combined read-only view of everything waiting on the captain.
#
# Usage:
#   fm-captain-pending.sh add --kind <kind> [--task <task-id>] [--key <key>] \
#     [--due YYYY-MM-DD] [--] <text>...      (or `-` as the text: read stdin)
#   fm-captain-pending.sh answer <id> [--note <text>]
#   fm-captain-pending.sh drop <id> [--note <text>]
#   fm-captain-pending.sh show [--json] <id>
#   fm-captain-pending.sh list [--json] [--ledger-only]
#
# THE LEDGER records what the captain owes that has no backlog task or hold of
# its own: a question asked only in chat, an approval, a command the captain
# must run, a task only the captain can do, or anything else. A captain call
# that gates a backlog task stays a captain hold (bin/fm-captain-hold.sh) and
# is never recorded here as well. The ledger lives in the home's private data
# directory; docs/configuration.md "Captain-pending ledger" owns its location
# and record schema. This script owns the commands and the combined view.
#
# `add` appends one open entry and prints its id (`cp-<n>`) on stdout.
# Kinds: question, approval, command, task, other. --task links the entry to a
# task id for the view's task-state column; it is a pointer, not a hold.
# --key makes `add` idempotent: while an OPEN entry carries the same key, `add`
# prints that entry's id, notes the replay on stderr, and records nothing.
# --due is an optional YYYY-MM-DD answer-by date; an open entry past it reads
# `overdue` in the view. Text is at most 8192 bytes; a note likewise.
# `answer` closes an open entry with the captain's answer as the note; `drop`
# closes one that no longer needs the captain (withdrawn, moot, superseded).
# Both refuse an unknown id or an entry that is already closed (exit 1).
# `show` prints one entry, open or closed, with its closing note.
#
# Writes take a lock beside the ledger (bin/fm-wake-lib.sh lock primitives,
# with their dead-owner recovery), append exactly one JSON line, and first
# terminate a torn final line a crash left behind, so concurrent writers never
# interleave and one bad line never corrupts the next. Readers skip any line
# that is not a well-formed record and report how many they skipped.
#
# `list` changes no record (the snapshot it runs may refresh only its own
# observational cache) and renders ONE view from three sources:
#   ledger   open ledger entries (above);
#   backlog  held backlog rows - captain holds, parked work, and other holds -
#            classified by bin/fm-fleet-snapshot.sh's hold_bucket and hold
#            metadata;
#   status   keyed open status decisions, from the snapshot's
#            hints.open_decisions (bin/fm-classify-lib.sh's
#            status_open_decisions fold, reconciled against current state).
# Backlog and status come from one `bin/fm-fleet-snapshot.sh --json` run of
# this home; nothing here re-reads backlog or status files or re-classifies.
# Secondmate captain calls reach this home as keyed status decisions on the
# secondmate's own task, so they appear under `status`.
#
# Sections and labels (one line per item: id, source, age, task state, then
# `[label] the ask`):
#   WAITING ON CAPTAIN
#     ledger entry             [open] or [overdue]                     live
#     captain hold, live       [live]                                  live
#     captain hold, aged       [aged]  (undated hold past the snapshot's aging threshold)
#     captain hold, expired    [expired <date>] (hold_until reached)
#     needs-decision status    [live], or [stale?] when the task is shadowed
#   PAUSED BY CAPTAIN ORDER
#     parked hold              [parked], [parked until <date>], or [expired <date>]
#     captain hold, dated      [until <date>]  (the captain deferred it)
#   PAUSED OTHER REASON
#     captain hold, blocked    [blocked-by <ids>]
#     other held row           [<hold kind>] or [expired <date>]
#     blocked status decision  [blocked], or [stale?] when the task is shadowed
# A hold_until date is expired on and after that date, matching tasks-axi.
# A status decision is shadowed - labelled `stale?` - when its task's backlog
# row carries an active hold of any kind (the hold, listed separately, owns the
# call now), or when the task's current state or latest status event is a
# declared `paused:` wait. Only items marked live above count as live asks.
# --ledger-only lists open ledger entries alone and runs no snapshot; the
# session-start digest uses it.
# `list --json` prints schema `fm-captain-pending-list.v1`: generated, fm_home,
# ledger {path,present,unreadable_lines}, fleet {available,reason},
# counts {live,waiting_on_captain,paused_by_captain_order,paused_other_reason},
# and one array per section. Each item carries id, source, kind, key, task_id,
# age_seconds, age (rendered; whole days when only a hold date is known),
# task_state, label, live, text, due, and created.
#
# Exit codes: 0 success; 1 refused or failed; 2 usage. `list` exits 3 when the
# snapshot was unavailable: the ledger section is still printed, the output
# names the missing sources, and the result must not be read as complete.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LEDGER="$DATA/captain-pending.jsonl"
LEDGER_LOCK="$DATA/.captain-pending.lock"
MAX_TEXT_BYTES=8192
KINDS="question approval command task other"

LOCK_HELD=0
TMP_DIR=
cleanup() {
  if [ "$LOCK_HELD" = 1 ]; then
    fm_lock_release "$LEDGER_LOCK" || true
    LOCK_HELD=0
  fi
  [ -z "$TMP_DIR" ] || rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-captain-pending: %s\n' "$*" >&2
  exit 1
}

usage_fail() {
  printf 'fm-captain-pending: %s\n' "$*" >&2
  printf 'run with --help for usage\n' >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || fail "jq not found"

valid_ident() {  # <value>
  case "$1" in
    ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 120 ]
}

valid_date() {  # <value>
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]) return 0 ;;
  esac
  return 1
}

byte_len() {  # <text>
  printf '%s' "$1" | wc -c | tr -d '[:space:]'
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date +%s; }

# Fold the ledger's events into {present, unreadable, entries[]}, entries in
# creation order. An answer or drop applies only to a still-open entry.
ledger_fold() {
  if [ ! -f "$LEDGER" ]; then
    printf '{"present":false,"unreadable":0,"entries":[]}\n'
    return 0
  fi
  jq -R -s -c '
    [ splits("\n") | select(test("^[[:space:]]*$") | not) | (try fromjson catch null) ] as $parsed
    | def record: type == "object" and .v == 1 and (.id | type) == "string";
      ([ $parsed[] | select(record | not) ] | length) as $bad
    | reduce ($parsed[] | select(record)) as $e ({order:[], by:{}};
        if $e.event == "add" and .by[$e.id] == null then
          .order += [$e.id]
          | .by[$e.id] = {id:$e.id, seq:$e.seq, kind:$e.kind, text:$e.text,
              task:$e.task, key:$e.key, due:$e.due, created:$e.at,
              created_epoch:$e.epoch, status:"open", note:null,
              closed:null, closed_epoch:null}
        elif ($e.event == "answer" or $e.event == "drop")
             and .by[$e.id] != null and .by[$e.id].status == "open" then
          .by[$e.id] += {status:(if $e.event == "answer" then "answered" else "dropped" end),
                         note:$e.note, closed:$e.at, closed_epoch:$e.epoch}
        else . end)
    | {present:true, unreadable:$bad, entries:[.order[] as $id | .by[$id]]}
  ' < "$LEDGER"
}

load_lock_lib() {
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
}

lock_ledger() {
  mkdir -p "$DATA" || fail "cannot create $DATA"
  load_lock_lib
  fm_lock_acquire_wait "$LEDGER_LOCK" || fail "could not take the ledger lock $LEDGER_LOCK"
  LOCK_HELD=1
}

unlock_ledger() {
  fm_lock_release "$LEDGER_LOCK" || true
  LOCK_HELD=0
}

# Append one event line. Caller holds the lock. A final line without its
# newline is a torn write from a crash; terminate it first so the new record
# starts on its own line and stays readable.
append_event() {  # <json-line>
  if [ -s "$LEDGER" ] && [ "$(tail -c 1 "$LEDGER" | wc -l | tr -d '[:space:]')" = 0 ]; then
    printf '\n' >> "$LEDGER" || fail "cannot write $LEDGER"
  fi
  printf '%s\n' "$1" >> "$LEDGER" || fail "cannot write $LEDGER"
}

cmd_add() {
  local kind='' task='' key='' due='' text='' fold existing seq id event
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) [ $# -ge 2 ] || usage_fail "--kind needs a value"; kind=$2; shift 2 ;;
      --task) [ $# -ge 2 ] || usage_fail "--task needs a value"; task=$2; shift 2 ;;
      --key) [ $# -ge 2 ] || usage_fail "--key needs a value"; key=$2; shift 2 ;;
      --due) [ $# -ge 2 ] || usage_fail "--due needs a value"; due=$2; shift 2 ;;
      --) shift; break ;;
      -) break ;;
      --*) usage_fail "unknown add option: $1" ;;
      *) break ;;
    esac
  done
  if [ $# -eq 1 ] && [ "$1" = - ]; then
    text=$(cat) || fail "cannot read text from stdin"
  else
    text="$*"
  fi
  case " $KINDS " in
    *" $kind "*) [ -n "$kind" ] || usage_fail "--kind is required ($KINDS)" ;;
    *) usage_fail "--kind must be one of: $KINDS" ;;
  esac
  [ -z "$task" ] || valid_ident "$task" || usage_fail "--task is not a valid task id: $task"
  [ -z "$key" ] || valid_ident "$key" || usage_fail "--key is not a valid key: $key"
  [ -z "$due" ] || valid_date "$due" || usage_fail "--due must be YYYY-MM-DD: $due"
  case "$text" in
    *[![:space:]]*) ;;
    *) usage_fail "the ask text is empty" ;;
  esac
  [ "$(byte_len "$text")" -le "$MAX_TEXT_BYTES" ] || usage_fail "the ask text exceeds $MAX_TEXT_BYTES bytes"

  lock_ledger
  fold=$(ledger_fold) || fail "cannot read $LEDGER"
  if [ -n "$key" ]; then
    existing=$(printf '%s' "$fold" | jq -r --arg key "$key" \
      'first(.entries[] | select(.status == "open" and .key == $key) | .id) // empty')
    if [ -n "$existing" ]; then
      unlock_ledger
      printf 'fm-captain-pending: open entry %s already carries key %s; nothing recorded\n' "$existing" "$key" >&2
      printf '%s\n' "$existing"
      return 0
    fi
  fi
  seq=$(printf '%s' "$fold" | jq '[.entries[].seq | numbers] | (max // 0) + 1')
  id="cp-$seq"
  event=$(jq -n -c --arg id "$id" --argjson seq "$seq" --arg kind "$kind" \
    --arg text "$text" --arg task "$task" --arg key "$key" --arg due "$due" \
    --arg at "$(now_iso)" --argjson epoch "$(now_epoch)" '
    def nullable: if . == "" then null else . end;
    {v:1, event:"add", id:$id, seq:$seq, kind:$kind, text:$text,
     task:($task | nullable), key:($key | nullable), due:($due | nullable),
     at:$at, epoch:$epoch}') || fail "cannot encode the entry"
  append_event "$event"
  unlock_ledger
  printf '%s\n' "$id"
}

cmd_close() {  # <answer|drop> <args...>
  local verb=$1 id='' note='' fold status event
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --note) [ $# -ge 2 ] || usage_fail "--note needs a value"; note=$2; shift 2 ;;
      --*) usage_fail "unknown $verb option: $1" ;;
      *) [ -z "$id" ] || usage_fail "$verb takes one id"; id=$1; shift ;;
    esac
  done
  [ -n "$id" ] || usage_fail "$verb needs an entry id"
  [ "$(byte_len "$note")" -le "$MAX_TEXT_BYTES" ] || usage_fail "the note exceeds $MAX_TEXT_BYTES bytes"

  lock_ledger
  fold=$(ledger_fold) || fail "cannot read $LEDGER"
  status=$(printf '%s' "$fold" | jq -r --arg id "$id" \
    'first(.entries[] | select(.id == $id) | .status) // empty')
  [ -n "$status" ] || fail "no ledger entry $id"
  [ "$status" = open ] || fail "entry $id is already $status"
  event=$(jq -n -c --arg id "$id" --arg event "$verb" --arg note "$note" \
    --arg at "$(now_iso)" --argjson epoch "$(now_epoch)" '
    {v:1, event:$event, id:$id, note:(if $note == "" then null else $note end),
     at:$at, epoch:$epoch}') || fail "cannot encode the close"
  append_event "$event"
  unlock_ledger
  case "$verb" in
    answer) printf 'answered: %s\n' "$id" ;;
    drop) printf 'dropped: %s\n' "$id" ;;
  esac
}

cmd_show() {
  local json=0 id='' entry
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --*) usage_fail "unknown show option: $1" ;;
      *) [ -z "$id" ] || usage_fail "show takes one id"; id=$1; shift ;;
    esac
  done
  [ -n "$id" ] || usage_fail "show needs an entry id"
  entry=$(ledger_fold | jq -c --arg id "$id" 'first(.entries[] | select(.id == $id)) // empty') \
    || fail "cannot read $LEDGER"
  [ -n "$entry" ] || fail "no ledger entry $id"
  if [ "$json" = 1 ]; then
    printf '%s\n' "$entry" | jq 'del(.seq)'
    return 0
  fi
  printf '%s\n' "$entry" | jq -r '
    "id: \(.id)", "kind: \(.kind)", "status: \(.status)", "created: \(.created)",
    (if .due then "due: \(.due)" else empty end),
    (if .task then "task: \(.task)" else empty end),
    (if .key then "key: \(.key)" else empty end),
    (if .closed then "\(.status): \(.closed)" else empty end),
    "text: \(.text)",
    (if .note then "note: \(.note)" else empty end)'
}

# Build the combined view JSON from the ledger fold and an optional snapshot.
# Inputs are files so a large snapshot never rides on the command line.
build_view() {  # <fold-file> <snapshot-file-or-empty> <fleet-reason> <today> <now-epoch> <now-iso> <paused-verb>
  local fold_file=$1 snap_file=$2 reason=$3 today=$4 now=$5 now_iso=$6 paused_verb=$7 snap_args
  if [ -n "$snap_file" ]; then
    snap_args="$snap_file"
  else
    snap_args=/dev/null
  fi
  jq -n -c \
    --slurpfile fold "$fold_file" \
    --slurpfile snaps "$snap_args" \
    --arg reason "$reason" \
    --arg today "$today" \
    --argjson now "$now" \
    --arg generated "$now_iso" \
    --arg fm_home "$FM_HOME" \
    --arg ledger_path "$LEDGER" \
    --arg paused_verb "$paused_verb" '
    ($fold[0]) as $ledger
    | ($snaps[0] // null) as $snap
    | ([ $snap.backlog.records[]? | select(.structured == true) ]) as $rows
    | ([ $snap.tasks[]? ]) as $tasks
    | def row($id): first($rows[] | select(.id == $id)) // null;
      def task($id): first($tasks[] | select(.id == $id)) // null;
      def task_state($id):
        if $id == null then null
        elif $snap == null then "unknown"
        else ([(row($id) | if . == null then null else .state end),
               (task($id) | if . == null then null else .current_state.state end)]
              | map(select(. != null)) | join("/")
              | if . == "" then "untracked" else . end)
        end;
      def held: .hold_reason != null and .state != "done";
      def expired: .hold_until != null and .hold_until <= $today;
      def age_of($s):
        if $s == null or $s < 0 then {seconds:null, text:"-"}
        elif $s < 3600 then {seconds:$s, text:"\(($s / 60) | floor)m"}
        elif $s < 86400 then {seconds:$s, text:"\(($s / 3600) | floor)h"}
        else {seconds:$s, text:"\(($s / 86400) | floor)d"} end;
      def item($source; $kind; $key; $task_id; $age; $label; $live; $text; $due; $created):
        {id:.id, source:$source, kind:$kind, key:$key, task_id:$task_id,
         age_seconds:$age.seconds, age:$age.text, task_state:task_state($task_id),
         label:$label, live:$live, text:$text, due:$due, created:$created};
      def hold_text: (.title // .id) + (if .hold_reason then ": " + .hold_reason else "" end);
      # A hold-set stamp with a time gives an exact age; a date-only stamp or
      # the since date gives the snapshot hold_age_days, shown in whole days.
      def hold_age:
        if ((.hold_set // "") | test("T")) then age_of($now - (.hold_set | fromdateiso8601))
        elif .hold_age_days == null then age_of(null)
        else {seconds:(.hold_age_days * 86400), text:"\(.hold_age_days)d"} end;

    ([ $ledger.entries[] | select(.status == "open")
       | item("ledger"; .kind; .key; .task;
              age_of(if .created_epoch == null then null else ($now - .created_epoch) end);
              (if .due != null and .due < $today then "overdue" else "open" end);
              true; .text; .due; .created) ]) as $ledger_items

    | ([ $rows[] | select(held)
         | (.hold_kind // "held") as $hk
         | if $hk == "captain" then
             if .hold_bucket == "blocked" then
               {section:"other", v:item("backlog"; $hk; null; .id; hold_age;
                 "blocked-by " + (.unresolved_blocker_ids | join(",")); false; hold_text; null; .since)}
             elif expired then
               {section:"waiting", v:item("backlog"; $hk; null; .id; hold_age;
                 "expired " + .hold_until; false; hold_text; null; .since)}
             elif .hold_bucket == "dated" then
               {section:"order", v:item("backlog"; $hk; null; .id; hold_age;
                 "until " + .hold_until; false; hold_text; null; .since)}
             elif .hold_bucket == "aged" then
               {section:"waiting", v:item("backlog"; $hk; null; .id; hold_age;
                 "aged"; false; hold_text; null; .since)}
             else
               {section:"waiting", v:item("backlog"; $hk; null; .id; hold_age;
                 "live"; true; hold_text; null; .since)}
             end
           elif $hk == "parked" then
             {section:"order", v:item("backlog"; $hk; null; .id; hold_age;
               (if expired then "expired " + .hold_until
                elif .hold_until != null then "parked until " + .hold_until
                else "parked" end); false; hold_text; null; .since)}
           else
             {section:"other", v:item("backlog"; $hk; null; .id; hold_age;
               (if expired then "expired " + .hold_until else $hk end);
               false; hold_text; null; .since)}
           end ]) as $hold_items

    | ([ $tasks[] as $t
         | (row($t.id)) as $r
         | ((($r != null) and ($r | held))
            or $t.current_state.state == "paused"
            or ($t.paths.status_log.last_event.state // "") == $paused_verb) as $shadowed
         | ($t.hints.open_decisions // [])[] as $d
         | {id:$t.id}
         | {section:(if $d.verb == "needs-decision" then "waiting" else "other" end),
            v:item("status"; $d.verb; $d.key; $t.id; age_of(null);
               (if $shadowed then "stale?" elif $d.verb == "blocked" then "blocked" else "live" end);
               (($shadowed | not) and $d.verb == "needs-decision");
               $d.summary; null; null)} ]) as $status_items

    | ($ledger_items
       + [ $hold_items[] | select(.section == "waiting") | .v ]
       + [ $status_items[] | select(.section == "waiting") | .v ]) as $waiting
    | ([ $hold_items[] | select(.section == "order") | .v ]) as $order
    | ([ $hold_items[] | select(.section == "other") | .v ]
       + [ $status_items[] | select(.section == "other") | .v ]) as $other
    | {
        schema:"fm-captain-pending-list.v1",
        generated:$generated,
        fm_home:$fm_home,
        ledger:{path:$ledger_path, present:$ledger.present, unreadable_lines:$ledger.unreadable},
        fleet:{available:($snap != null), reason:(if $snap != null then null else $reason end)},
        counts:{
          live:([ $waiting[], $order[], $other[] | select(.live) ] | length),
          waiting_on_captain:($waiting | length),
          paused_by_captain_order:($order | length),
          paused_other_reason:($other | length)
        },
        waiting_on_captain:$waiting,
        paused_by_captain_order:$order,
        paused_other_reason:$other
      }
  '
}

render_view() {  # <ledger-only 0|1>; reads the view JSON on stdin
  jq -r --argjson ledger_only "$1" '
    def ask:
      (.text // "" | split("\n")) as $lines
      | ($lines[0] // "") as $first
      | (if ($first | length) > 200 then $first[:200] + "..."
         elif ($lines | length) > 1 then $first + " ..." else $first end);
    def line:
      "  \(.id)  \(.source):\(.kind)\(if .source == "status" and .key then "[" + .key + "]" else "" end)  \(.age)  \(.task_state // "-")  [\(.label)] \(ask)";
    def section($title; $items):
      "\($title) (\($items | length))",
      (if ($items | length) == 0 then "  (none)" else ($items[] | line) end);
    (if .ledger.unreadable_lines > 0 then
       "WARNING: \(.ledger.unreadable_lines) unreadable ledger line(s) skipped in \(.ledger.path)"
     else empty end),
    if $ledger_only == 1 then
      (if (.waiting_on_captain | length) == 0 then "(none)" else (.waiting_on_captain[] | line) end)
    else
      (if .fleet.available | not then
         "INCOMPLETE: backlog and status sources unavailable (\(.fleet.reason)); only the ledger is shown"
       else empty end),
      "live asks: \(.counts.live)",
      section("WAITING ON CAPTAIN"; .waiting_on_captain),
      section("PAUSED BY CAPTAIN ORDER"; .paused_by_captain_order),
      section("PAUSED OTHER REASON"; .paused_other_reason)
    end
  '
}

cmd_list() {
  local json=0 ledger_only=0 fold_file snap_file='' reason='' today now now_iso_v view paused_verb rc=0 err_file
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --ledger-only) ledger_only=1; shift ;;
      *) usage_fail "unknown list option: $1" ;;
    esac
  done
  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-captain-pending.XXXXXX") || fail "cannot create a temporary directory"
  fold_file="$TMP_DIR/fold.json"
  ledger_fold > "$fold_file" || fail "cannot read $LEDGER"
  now=$(now_epoch)
  now_iso_v=$(now_iso)
  today=${now_iso_v%%T*}
  # shellcheck source=bin/fm-classify-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-classify-lib.sh"
  paused_verb=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}

  if [ "$ledger_only" = 1 ]; then
    reason="not requested (--ledger-only)"
  else
    snap_file="$TMP_DIR/snapshot.json"
    err_file="$TMP_DIR/snapshot.err"
    if "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json > "$snap_file" 2> "$err_file" \
      && jq -e '.schema == "fm-fleet-snapshot.v1"' "$snap_file" >/dev/null 2>&1; then
      today=$(jq -r '.generated[:10]' "$snap_file")
      valid_date "$today" || today=${now_iso_v%%T*}
    else
      reason=$(grep -v '^[[:space:]]*$' "$err_file" 2>/dev/null | head -1)
      [ -n "$reason" ] || reason="fleet snapshot failed"
      snap_file=''
      rc=3
    fi
  fi

  view=$(build_view "$fold_file" "$snap_file" "$reason" "$today" "$now" "$now_iso_v" "$paused_verb") \
    || fail "cannot build the combined view"
  if [ "$json" = 1 ]; then
    printf '%s\n' "$view" | jq .
  else
    printf '%s\n' "$view" | render_view "$ledger_only"
  fi
  return "$rc"
}

case "${1:-}" in
  add) shift; cmd_add "$@" ;;
  answer) shift; cmd_close answer "$@" ;;
  drop) shift; cmd_close drop "$@" ;;
  show) shift; cmd_show "$@" ;;
  list) shift; cmd_list "$@" ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 2 ;;
  *) usage_fail "unknown command: $1" ;;
esac
