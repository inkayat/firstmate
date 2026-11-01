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

# --- a captain hold's creation time --------------------------------------------
home=$(make_home hold-time)
cat > "$home/data/backlog.md" <<EOF
# Backlog

## In flight
## Queued
- [ ] timed - Timed call (repo: alpha) (since 2026-10-30) (hold: pick one) (hold-kind: captain)
  Captain hold set: 2026-10-30T09:15:00Z
- [ ] dated - Date-only call (repo: alpha) (since 2026-10-29) (hold: pick two) (hold-kind: captain)
## Done
EOF
view=$(pending "$home" list --json) || fail "hold-time list failed"
assert_equals "2026-10-30T09:15:00Z" "$(field "$(item "$view" waiting_on_captain timed)" '.created')" \
  "a hold with a recorded hold-set time is created then"
assert_equals "2026-10-29" "$(field "$(item "$view" waiting_on_captain dated)" '.created')" \
  "a hold without a hold-set time keeps its since date"
pass "a captain hold is created at its hold-set time when one is recorded"

# --- request generations, buckets, and exact counts ---------------------------
sha256_hex() {  # <text>
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}
encoded() {  # <reason>
  # shellcheck source=bin/fm-hold-reason-lib.sh
  # shellcheck disable=SC1091
  (. "$ROOT/bin/fm-hold-reason-lib.sh" && fm_hold_reason_encode "$1")
}
home=$(make_home generations)
live_reason=$'Pick (A) or B?\nNotes: café ✓'
cat > "$home/data/backlog.md" <<EOF
# Backlog

## In flight
## Queued
- [ ] live-a - Live   call see https://example.com/x (repo: alpha) (since 2026-10-30) (hold: $(encoded "$live_reason")) (hold-kind: captain)
  Captain hold set: 2026-10-30T09:15:00Z
- [ ] reheld - Re-held call (repo: alpha) (since 2026-10-30) (hold: choose again) (hold-kind: captain)
  Captain hold set: 2026-10-31T10:00:00Z
  Resolution recorded by fm-captain-hold.
  Decision digest: 0000
  Resolution mode: released
- [ ] dated - Dated call (repo: alpha) (since 2026-10-30) (hold: later) (hold-kind: captain) (hold-until: 2099-01-01)
  Captain hold set: 2026-10-30T09:15:00Z
- [ ] aged - Aged call (repo: alpha) (since 2020-01-01) (hold: old question) (hold-kind: captain)
  Captain hold set: 2020-01-01T00:00:00Z
- [ ] expired - Expired call (repo: alpha) (since 2026-10-30) (hold: revisit) (hold-kind: captain) (hold-until: 2020-01-01)
  Captain hold set: 2026-10-30T09:15:00Z
- [ ] gated - Gated call blocked-by: open-dep (repo: alpha) (since 2026-10-30) (hold: needs dep) (hold-kind: captain)
  Captain hold set: 2026-10-30T09:15:00Z
- [ ] open-dep - Dependency (repo: alpha) (since 2026-10-30)
- [ ] parked-one - Parked work (repo: alpha) (since 2026-10-30) (hold: captain said stop) (hold-kind: parked)
- [ ] ext-one - External (repo: alpha) (since 2026-10-30) (hold: vendor reply) (hold-kind: external)
## Done
EOF
for task in ship-s ship-q; do
  mkdir -p "$home/projects/$task"
  fm_write_meta "$home/state/$task.meta" "kind=ship" "worktree=$home/projects/$task" "project=alpha" "harness=claude"
done
printf 'needs-decision [key=api]: choose API shape\n' > "$home/state/ship-s.status"
printf 'needs-decision [key=z]: old question\npaused: waiting for upstream release\n' > "$home/state/ship-q.status"
pending "$home" add --kind question -- "Ship on Friday?" >/dev/null
view=$(pending "$home" list --json) || fail "generation list failed"

bucket_of() {  # <id> [<key>]
  printf '%s' "$view" | jq -r --arg id "$1" --arg key "${2:-}" \
    'first(.waiting_on_captain[], .paused_by_captain_order[], .paused_other_reason[]
       | select(.id == $id and ($key == "" or .key == $key))) | "\(.bucket)|\(.generation)|\(.reply.answer_to // "-")"'
}
live_gen="2026-10-30T09:15:00Z#0#$(sha256_hex "Live call see"$'\n'"$live_reason")"
assert_equals "live|$live_gen|backlog:live-a@$live_gen" "$(bucket_of live-a)" \
  "a live hold's generation is its hold-set stamp, answer count, and the digest of its title and decoded reason"
reheld_gen="2026-10-31T10:00:00Z#1#$(sha256_hex $'Re-held call\nchoose again')"
assert_equals "live|$reheld_gen|backlog:reheld@$reheld_gen" "$(bucket_of reheld)" \
  "a re-held call counts the answers already recorded on it"
assert_equals "deferred|2026-10-30T09:15:00Z#0#$(sha256_hex $'Dated call\nlater')|backlog:dated@2026-10-30T09:15:00Z#0#$(sha256_hex $'Dated call\nlater')" \
  "$(bucket_of dated)" "a deferred hold keeps its generation and stays answerable"
assert_equals needs_recheck "$(bucket_of aged | cut -d'|' -f1)" "an aged hold is a re-check, not gone"
assert_equals needs_recheck "$(bucket_of expired | cut -d'|' -f1)" "a hold past its deferral date is a re-check"
assert_equals blocked "$(bucket_of gated | cut -d'|' -f1)" "a blocked hold stays blocked"
assert_equals 'parked|null|-' "$(bucket_of parked-one)" "parked work carries no generation and takes no console reply"
assert_equals 'other|null|-' "$(bucket_of ext-one)" "another hold kind carries no generation and takes no console reply"
assert_equals 'live|cp-1|ledger:cp-1@cp-1' "$(bucket_of cp-1)" "a ledger entry's text never changes, so its id is its generation"
assert_equals 'live|null|-' "$(bucket_of ship-s api)" \
  "a status decision has no opening-event identity, so it carries no generation and takes no console reply"
assert_equals 'stale|null|-' "$(bucket_of ship-q z)" "a shadowed status decision is its own bucket"
assert_equals '4|2|1|1|1|1|1|11' \
  "$(field "$view" '.counts | "\(.live)|\(.needs_recheck)|\(.deferred)|\(.blocked)|\(.parked)|\(.other)|\(.stale)|\(.total)"')" \
  "exact counts per bucket, summing to the total"
pass "every pending item carries a bucket, and replyable requests a generation and answer reference"

# An in-place re-hold that rewrites the reason keeps the stamp and answer count
# but must change the generation; rewriting it back restores the generation.
sed -i.bak "s/(hold: later)/(hold: later, after launch)/" "$home/data/backlog.md"
view=$(pending "$home" list --json) || fail "rewritten list failed"
assert_equals "deferred|2026-10-30T09:15:00Z#0#$(sha256_hex $'Dated call\nlater, after launch')" \
  "$(bucket_of dated | cut -d'|' -f1-2)" "a rewritten reason changes the generation under the same stamp"
pass "a reason rewritten in place changes the generation"

# --- ledger answers through the console's answer notes -------------------------
inbox() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash "$ROOT/bin/fm-inbox.sh" "$@"
}
answer_note() {  # <home> <reply-id> <answer-to> <words>: prints the note id
  printf '%s' "$4" | inbox "$1" note --request-id "$2" --answer-to "$3" --json - | jq -r .id
}
note_outcome() {  # <home> <note-id>
  inbox "$1" show --json "$2" | jq -r '.outcome.outcome // "none"'
}
home=$(make_home ledger-notes)
pending "$home" add --kind question -- "Ship on Friday?" >/dev/null
pending "$home" add --kind approval -- "Approve the release notes" >/dev/null
n1=$(answer_note "$home" reply-1 ledger:cp-1@cp-1 $'Yes, Friday.\n(After the demo.)')
pending "$home" answer cp-1 --note-ref "$n1" >/dev/null || fail "a ledger answer note did not apply"
shown=$(pending "$home" show --json cp-1)
assert_equals $'answered|Yes, Friday.\n(After the demo.)|'"$n1" "$(field "$shown" '"\(.status)|\(.note)|\(.note_ref)"')" \
  "the ledger entry records the captain's words and the note they came from"
assert_equals answered "$(note_outcome "$home" "$n1")" "the applied outcome is not on the note"
pending "$home" answer cp-1 --note-ref "$n1" >/dev/null || fail "an exact replay of a ledger answer was not idempotent"
assert_equals 1 "$(grep -c '"event":"answer"' "$home/data/captain-pending.jsonl")" "a replay appended a second answer"
n2=$(answer_note "$home" reply-2 ledger:cp-1@cp-1 "No.")
expect_exit 4 pending "$home" answer cp-1 --note-ref "$n2"
assert_equals already-closed "$(note_outcome "$home" "$n2")" "a late second reply is not marked already closed"
n3=$(answer_note "$home" reply-3 ledger:cp-2@cp-2 "Not needed any more.")
expect_exit 1 pending "$home" answer cp-1 --note-ref "$n3"
pending "$home" drop cp-2 --note-ref "$n3" >/dev/null || fail "a ledger drop by answer note did not apply"
assert_equals 'dropped|dropped' "$(field "$(pending "$home" show --json cp-2)" .status)|$(note_outcome "$home" "$n3")" \
  "the drop is recorded on the entry and the note"
n4=$(answer_note "$home" reply-4 ledger:cp-9@cp-9 "Whatever this was.")
expect_exit 4 pending "$home" answer cp-9 --note-ref "$n4"
assert_equals not-found "$(note_outcome "$home" "$n4")" "an unknown entry is not marked not-found"
assert_equals 0 "$(field "$(pending "$home" list --json --ledger-only)" .counts.live)" "answered and dropped entries still count"
pass "a ledger entry is answered or dropped by its answer note once, with the outcome on the note"

# --- honest coverage: an unread backlog backend or secondmate is never a zero ---
home=$(make_home other-backend)
printf 'backend = "beads"\n' > "$home/.tasks.toml"
cat > "$home/data/backlog.md" <<EOF2
## In flight
## Queued
- [ ] stale-call - Stale markdown call (repo: alpha) (since 2026-10-30) (hold: pick one) (hold-kind: captain)
  Captain hold set: 2026-10-30T09:15:00Z
## Done
EOF2
pending "$home" add --kind question -- "Ship on Friday?" >/dev/null
view=$(pending "$home" list --json) || fail "a home on another backlog backend could not be listed"
assert_equals 'false|backlog|1|0' \
  "$(field "$view" '"\(.coverage.complete)|\([.coverage.missing[].source] | join(","))|\(.counts.live)|\([.waiting_on_captain[] | select(.source == "backlog")] | length)"')" \
  "captain holds on a backlog backend the view does not read are unknown, and no stale markdown row stands in for them"
assert_contains "$(field "$view" '.coverage.missing[0].reason')" "beads" "the reason does not name the unread backend"
assert_contains "$(pending "$home" list)" "INCOMPLETE" "the human view does not say it is incomplete"
pass "a backlog backend the view cannot read leaves its captain holds unknown, never zero"

mate_summary() {  # <mate-home> <decisions-shown> <decisions-total>
  jq -n --arg home "$1" --argjson shown "$2" --argjson total "$3" --argjson epoch "$(date +%s)" '{
    schema:"fm-secondmate-home-summary.v1", hold_classifier_schema:"fm-captain-hold-buckets.v1",
    generated:(now | todate), generated_epoch:$epoch, home:$home, valid:true, reason:null,
    invalidity:{kind:null, ids:[]}, state:"captain_decision", active_children:[],
    decisions_open:[range(0; $shown) | {id:"call-\(.)", key:"call-\(.)", verb:"captain-hold", summary:"Call \(.)",
      reason:"choose", hold_until:null, hold_bucket:"live", hold_age_days:null, source:"backlog"}],
    holds:[], queued:[], landed:[], endpoints:[],
    counts:{active_children:0, decisions_open:$total, holds:0, queued:0, landed:0, endpoints:0}, omitted:[]}' \
    > "$1/state/home-summary.json"
}
home=$(make_home secondmates)
for m in mate-a mate-b; do
  mkdir -p "$TMP_ROOT/$m/data" "$TMP_ROOT/$m/state" "$TMP_ROOT/$m/config" "$TMP_ROOT/$m/projects" "$TMP_ROOT/$m/bin"
  printf '# fixture\n' > "$TMP_ROOT/$m/AGENTS.md"
  printf '%s\n' "$m" > "$TMP_ROOT/$m/.fm-secondmate-home"
done
printf -- '- mate-a - fixture (home: %s; scope: fixture; projects: alpha; added 2026-10-30)\n' "$TMP_ROOT/mate-a" > "$home/data/secondmates.md"
mate_summary "$TMP_ROOT/mate-a" 1 1
view=$(pending "$home" list --json) || fail "a home with a fully read secondmate could not be listed"
assert_equals 'true|' "$(field "$view" '"\(.coverage.complete)|\([.coverage.missing[].source] | join(","))"')" \
  "a fully read secondmate leaves the view complete"
mate_summary "$TMP_ROOT/mate-a" 1 3
printf -- '- mate-b - fixture (home: %s; scope: fixture; projects: alpha; added 2026-10-30)\n' "$TMP_ROOT/mate-b" >> "$home/data/secondmates.md"
view=$(pending "$home" list --json) || fail "a home with unread secondmates could not be listed"
assert_equals 'false|secondmate:mate-a,secondmate:mate-b' "$(field "$view" '"\(.coverage.complete)|\([.coverage.missing[].source] | join(","))"')" \
  "a secondmate whose captain calls were cut, or whose summary is unreadable, leaves the view incomplete"
assert_contains "$(field "$view" '.coverage.missing[0].reason')" "1 of 3" "the cut is not disclosed"
view=$(FM_SNAPSHOT_SECONDMATES=1 pending "$home" list --json) || fail "a bounded secondmate read could not be listed"
assert_contains "$(field "$view" '[.coverage.missing[].source] | join(",")')" "secondmates" \
  "secondmates beyond the snapshot bound are not disclosed"
pass "an unread or truncated secondmate leaves the view incomplete instead of counting it as complete"

home=$(make_home registry-truncated)
printf '# fixture header one\n# fixture header two\n# fixture header three\n' > "$home/data/secondmates.md"
view=$(FM_SNAPSHOT_REGISTRY_LINES=1 pending "$home" list --json) || fail "a home with a truncated secondmate registry could not be listed"
assert_equals 'false|secondmates' "$(field "$view" '"\(.coverage.complete)|\([.coverage.missing[].source] | join(","))"')" \
  "a secondmate registry read short of its end, with no registered secondmate, is published as complete"
assert_contains "$(field "$view" '.coverage.missing[0].reason')" "not read in full" "the incomplete registry is not disclosed"
view=$(pending "$home" list --json) || fail "a home with an untruncated empty secondmate registry could not be listed"
assert_equals 'true|' "$(field "$view" '"\(.coverage.complete)|\([.coverage.missing[].source] | join(","))"')" \
  "a fully read registry with no secondmate leaves the view complete"
pass "an incompletely read secondmate registry leaves the view incomplete even with no registered secondmate"
