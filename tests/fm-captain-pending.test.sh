#!/usr/bin/env bash
# Behavior tests for bin/fm-captain-pending.sh: the captain-pending ledger and
# its combined read-only view over the ledger, captain holds, parked work, and
# keyed open status decisions.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

PENDING="$ROOT/bin/fm-captain-pending.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-pending)

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

pending() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" bash "$PENDING" "$@"
}

item() {  # <view-json> <section> <id> [<key>] -> the matching item, compact
  printf '%s' "$1" | jq -c --arg section "$2" --arg id "$3" --arg key "${4:-}" \
    'first(.[$section][] | select(.id == $id and ($key == "" or .key == $key))) // empty'
}

expect_exit() {  # <code> <command...>
  local want=$1 got=0
  shift
  "$@" >/dev/null 2>&1 || got=$?
  expect_code "$want" "$got" "$*"
}

field() {  # <item-json> <jq-path>
  printf '%s' "$1" | jq -r "$2"
}

# --- absent ledger -----------------------------------------------------------
home=$(make_home absent)
out=$(pending "$home" list --ledger-only) || fail "ledger-only list failed on an absent ledger"
assert_equals "(none)" "$out" "absent ledger did not list as empty"
view=$(pending "$home" list --json) || fail "list --json failed on a home with no ledger"
assert_equals "false" "$(field "$view" '.ledger.present')" "absent ledger reported present"
assert_equals "0" "$(field "$view" '.counts.live')" "absent ledger produced live asks"
assert_absent "$home/data/captain-pending.jsonl"
expect_exit 1 pending "$home" show cp-1
expect_exit 1 pending "$home" answer cp-1
pass "an absent ledger reads as empty and refuses closes"

# --- add, list, answer round trip -------------------------------------------
home=$(make_home roundtrip)
id=$(pending "$home" add --kind question --task ship-x -- "Ship on Friday?") || fail "add failed"
assert_equals "cp-1" "$id" "first entry id"
cmd=$(printf 'run gh auth login\nthen retry' | pending "$home" add --kind command --due 2020-01-01 -) \
  || fail "add from stdin failed"
assert_equals "cp-2" "$cmd" "second entry id"
view=$(pending "$home" list --json)
first=$(item "$view" waiting_on_captain cp-1)
[ -n "$first" ] || fail "added question is not waiting on the captain: $view"
assert_equals "open" "$(field "$first" '.label')" "open entry label"
assert_equals "true" "$(field "$first" '.live')" "open entry is not live"
assert_equals "ledger" "$(field "$first" '.source')" "ledger entry source"
assert_equals "ship-x" "$(field "$first" '.task_id')" "task link"
second=$(item "$view" waiting_on_captain cp-2)
assert_equals "overdue" "$(field "$second" '.label')" "past-due entry label"
assert_equals "$(printf 'run gh auth login\nthen retry')" "$(field "$second" '.text')" "multi-line text round trip"
assert_equals "2" "$(field "$view" '.counts.live')" "live count with two open entries"

pending "$home" answer cp-1 --note "yes, Friday" >/dev/null || fail "answer failed"
view=$(pending "$home" list --json)
[ -z "$(item "$view" waiting_on_captain cp-1)" ] || fail "answered entry still listed"
assert_equals "1" "$(field "$view" '.counts.live')" "live count after answer"
shown=$(pending "$home" show --json cp-1) || fail "show failed for an answered entry"
assert_equals "answered" "$(field "$shown" '.status')" "answered status"
assert_equals "yes, Friday" "$(field "$shown" '.note')" "answer note"
expect_exit 1 pending "$home" answer cp-1
expect_exit 1 pending "$home" drop cp-1
pending "$home" drop cp-2 --note "moot" >/dev/null || fail "drop failed"
assert_equals "dropped" "$(field "$(pending "$home" show --json cp-2)" '.status')" "dropped status"
out=$(pending "$home" list --ledger-only)
assert_equals "(none)" "$out" "closed entries still listed"
pass "add, list, answer, and drop round trip through the ledger"

# --- key idempotency and validation -----------------------------------------
home=$(make_home keyed)
a=$(pending "$home" add --kind approval --key merge-x -- "Approve merge" 2>/dev/null)
b=$(pending "$home" add --kind approval --key merge-x -- "Approve merge again" 2>/dev/null)
assert_equals "$a" "$b" "repeat key did not return the open entry"
assert_equals "1" "$(field "$(pending "$home" list --json --ledger-only)" '.counts.waiting_on_captain')" "repeat key recorded twice"
pending "$home" answer "$a" >/dev/null
c=$(pending "$home" add --kind approval --key merge-x -- "Approve the next merge" 2>/dev/null)
assert_not_equals "$a" "$c" "a closed key was reopened instead of recording a new ask"
expect_exit 2 pending "$home" add --kind wish -- "bad kind"
expect_exit 2 pending "$home" add --kind question
expect_exit 2 pending "$home" add --kind question --due tomorrow -- "bad date"
pass "a repeated key is idempotent while open and invalid input is refused"

# --- concurrent appends and torn tail ----------------------------------------
home=$(make_home concurrent)
pids=''
for n in 1 2 3 4 5 6 7 8 9 10; do
  pending "$home" add --kind other -- "parallel ask $n" > "$home/out.$n" &
  pids="$pids $!"
done
for pid in $pids; do
  wait "$pid" || fail "a concurrent add failed"
done
ids=$(cat "$home"/out.* | sort -u | wc -l | tr -d '[:space:]')
assert_equals "10" "$ids" "concurrent adds did not get distinct ids"
view=$(pending "$home" list --json --ledger-only)
assert_equals "10" "$(field "$view" '.counts.waiting_on_captain')" "concurrent adds lost an entry"
assert_equals "0" "$(field "$view" '.ledger.unreadable_lines')" "concurrent adds interleaved a line"
printf '{"v":1,"event":"add","id":"cp-99","te' >> "$home/data/captain-pending.jsonl"
id=$(pending "$home" add --kind question -- "after the crash") || fail "add after a torn line failed"
view=$(pending "$home" list --json --ledger-only)
assert_equals "1" "$(field "$view" '.ledger.unreadable_lines')" "torn line not reported"
[ -n "$(item "$view" waiting_on_captain "$id")" ] || fail "entry after a torn line is unreadable: $view"
assert_equals "11" "$(field "$view" '.counts.waiting_on_captain')" "torn line hid other entries"
pass "concurrent adds stay distinct and a torn final line never corrupts the next record"

# --- combined view: sections and labels ---------------------------------------
home=$(make_home combined)
today=$(date -u +%Y-%m-%d)
cat > "$home/data/backlog.md" <<EOF
# Backlog

## In flight
## Queued
- [ ] capt-live - Pick API (repo: alpha) (since $today) (hold: choose A or B) (hold-kind: captain)
- [ ] capt-exp - Old call (repo: alpha) (since $today) (hold: revisit) (hold-kind: captain) (hold-until: 2020-01-01)
- [ ] capt-dated - Later call (repo: alpha) (since $today) (hold: after launch) (hold-kind: captain) (hold-until: 2099-01-01)
- [ ] capt-blocked - Gated call blocked-by: open-dep (repo: alpha) (since $today) (hold: needs dep first) (hold-kind: captain)
- [ ] open-dep - Dependency (repo: alpha) (since $today)
- [ ] parked-one - Parked work (repo: alpha) (since $today) (hold: captain said stop) (hold-kind: parked)
- [ ] parked-exp - Parked until past (repo: alpha) (since $today) (hold: wait) (hold-kind: parked) (hold-until: 2020-01-01)
- [ ] ext-one - External (repo: alpha) (since $today) (hold: vendor reply) (hold-kind: external)
## Done
- [x] capt-done - Closed call (repo: alpha) (hold: old) (hold-kind: captain) (merged 2026-01-02)
EOF
for task in ship-a capt-live ship-p; do
  mkdir -p "$home/projects/$task"
  fm_write_meta "$home/state/$task.meta" "kind=ship" "worktree=$home/projects/$task" "project=alpha" "harness=claude"
done
printf 'needs-decision [key=api]: choose API shape\nblocked [key=creds]: need a token\n' > "$home/state/ship-a.status"
printf 'needs-decision [key=q]: pick API\n' > "$home/state/capt-live.status"
printf 'needs-decision [key=z]: old question\npaused: waiting for upstream release\n' > "$home/state/ship-p.status"
pending "$home" add --kind command -- "run the release script" >/dev/null

view=$(pending "$home" list --json) || fail "combined list failed"
assert_equals "true" "$(field "$view" '.fleet.available')" "snapshot source unavailable"
check() {  # <section> <id> <key-or-empty> <label> <live>
  local got
  got=$(item "$view" "$1" "$2" "$3")
  [ -n "$got" ] || fail "$2${3:+[$3]} is not in $1: $view"
  assert_equals "$4" "$(field "$got" '.label')" "$2${3:+[$3]} label"
  assert_equals "$5" "$(field "$got" '.live')" "$2${3:+[$3]} live flag"
}
check waiting_on_captain cp-1 '' open true
check waiting_on_captain capt-live '' live true
check waiting_on_captain capt-exp '' "expired 2020-01-01" false
check paused_by_captain_order capt-dated '' "until 2099-01-01" false
check paused_other_reason capt-blocked '' "blocked-by open-dep" false
check paused_by_captain_order parked-one '' parked false
check paused_by_captain_order parked-exp '' "expired 2020-01-01" false
check paused_other_reason ext-one '' external false
check waiting_on_captain ship-a api live true
check paused_other_reason ship-a creds blocked false
check waiting_on_captain capt-live q "stale?" false
check waiting_on_captain ship-p z "stale?" false
assert_equals "0" "$(field "$view" '[.waiting_on_captain[], .paused_by_captain_order[], .paused_other_reason[] | select(.id == "capt-done" or .id == "open-dep")] | length')" \
  "a closed or unheld row was listed"
assert_equals "3" "$(field "$view" '.counts.live')" "live asks must count only live items"
pass "the combined view sorts every source into its section with expired and stale labels"

aged=$(FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=0 pending "$home" list --json) || fail "aged list failed"
got=$(item "$aged" waiting_on_captain capt-live)
assert_equals "aged" "$(field "$got" '.label')" "aged captain hold label"
assert_equals "false" "$(field "$got" '.live')" "an aged hold counted as live"
pass "an aged captain hold stays visible but is not a live ask"

# --- unavailable snapshot ----------------------------------------------------
out=$(FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=invalid pending "$home" list --json)
rc=$?
assert_equals "3" "$rc" "an unavailable snapshot did not exit 3"
assert_equals "false" "$(field "$out" '.fleet.available')" "an unavailable snapshot reported available"
[ -n "$(item "$out" waiting_on_captain cp-1)" ] || fail "ledger entries missing when the snapshot failed: $out"
assert_equals "0" "$(field "$out" '[.waiting_on_captain[] | select(.source != "ledger")] | length')" \
  "non-ledger items listed without a snapshot"
pass "an unavailable snapshot still lists the ledger and exits incomplete"
