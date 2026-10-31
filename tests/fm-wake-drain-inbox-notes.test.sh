#!/usr/bin/env bash
# tests/fm-wake-drain-inbox-notes.test.sh - a captain inbox note's wake can
# never be acknowledged unseen while the note is still pending.
#
# Pins three consumer-visible properties of bin/fm-wake-drain.sh over synthetic
# homes built with the real bin/fm-inbox.sh: an --ack-through whose range holds
# the `check inbox:<id>` wake of a still-pending note is refused with nothing
# consumed; a drain that carries such a wake lists every pending note in a
# bounded PENDING CAPTAIN NOTES block; and a home with no pending note sees
# the drain exactly as before.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
INBOX_BIN="$ROOT/bin/fm-inbox.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-inbox-notes-tests)

# Status presentation on a home that does not run the supervision host, so the
# BRANCH OUTCOMES section stays out of every drain here.
mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

HOME_DIR=

new_home() {  # <name>
  HOME_DIR=$(make_case "$1")
  mkdir -p "$HOME_DIR/data"
}

run_inbox() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    "$INBOX_BIN" "$@"
}

run_drain() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$DRAIN" "$@"
}

# Queue a note through the real capture path and print its id.
queue_note() {  # <body>
  local out
  out=$(printf '%s' "$1" | run_inbox note -) || fail "fm-inbox note failed for: $1"
  out=${out#queued }
  printf '%s\n' "${out%%$'\n'*}"
}

# Drain into $HOME_DIR/drain.{out,err}; print the "<seq> <generation>" pair the
# WAKE_ACK_REQUIRED line names, tolerating any wording before the command.
drain_to_files() {
  run_drain > "$HOME_DIR/drain.out" 2> "$HOME_DIR/drain.err" || fail "drain failed: $(cat "$HOME_DIR/drain.err")"
  sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1 \2/p' \
    "$HOME_DIR/drain.err" | tail -1
}

queue_snapshot() {
  local f
  for f in .wake-queue .main-eligible-rows .watcher-down; do
    printf '== %s\n' "$f"
    cat "$HOME_DIR/state/$f" 2>/dev/null || printf '(absent)\n'
  done
}

test_ack_refused_while_note_pending_then_accepted_after_handling() {
  local id ack seq gen before rc err
  new_home refuse-then-accept
  id=$(queue_note "please look at the release notes before tonight")
  ack=$(drain_to_files)
  [ -n "$ack" ] || fail "setup: drain printed no acknowledgement: $(cat "$HOME_DIR/drain.err")"
  seq=${ack% *}; gen=${ack#* }
  before=$(queue_snapshot)

  rc=0
  run_drain --ack-through "$seq" --recovery-generation "$gen" > "$HOME_DIR/ack.out" 2> "$HOME_DIR/ack.err" || rc=$?
  err=$(cat "$HOME_DIR/ack.err")
  expect_code 3 "$rc" "acknowledging a pending captain note's wake"
  assert_equals "$before" "$(queue_snapshot)" "a refused acknowledgement consumed queue, claim, or recovery state"
  assert_contains "$err" "$id" "the refusal does not name the pending note"
  assert_contains "$err" "please look at the release notes before tonight" "the refusal does not show the note's first line"
  assert_contains "$err" "bin/fm-inbox.sh reply $id" "the refusal does not name the reply command"
  assert_contains "$err" "bin/fm-inbox.sh drain --ack $id" "the refusal does not name the note acknowledgement"
  assert_contains "$err" "bin/fm-wake-drain.sh --ack-through $seq --recovery-generation $gen" \
    "the refusal does not name the exact acknowledgement to re-run"
  [ -f "$HOME_DIR/state/inbox/$id.note" ] || fail "the refusal touched the pending note"

  run_inbox reply "$id" "read it, will do" >/dev/null || fail "reply failed"
  run_inbox drain --ack "$id" >/dev/null || fail "note acknowledgement failed"
  run_drain --ack-through "$seq" --recovery-generation "$gen" 2> "$HOME_DIR/ack2.err" \
    || fail "the acknowledgement was still refused after the note was handled: $(cat "$HOME_DIR/ack2.err")"
  [ ! -s "$HOME_DIR/state/.wake-queue" ] || fail "the accepted acknowledgement left rows: $(cat "$HOME_DIR/state/.wake-queue")"
  pass "a pending note's wake acknowledgement is refused with nothing consumed, then accepted once the note is handled"
}

test_vanished_unreadable_or_otherwise_handled_notes_do_not_block() {
  local variant id ack seq gen
  for variant in deleted unreadable handled-elsewhere both-copies symlink; do
    new_home "gone-$variant"
    id=$(queue_note "note that will be $variant")
    ack=$(drain_to_files)
    seq=${ack% *}; gen=${ack#* }
    case "$variant" in
      deleted) rm -f "$HOME_DIR/state/inbox/$id.note" ;;
      unreadable)
        chmod 000 "$HOME_DIR/state/inbox/$id.note"
        if [ -r "$HOME_DIR/state/inbox/$id.note" ]; then
          chmod 600 "$HOME_DIR/state/inbox/$id.note"
          pass "skip: unreadable-note case needs a non-root user"
          continue
        fi
        ;;
      handled-elsewhere) run_inbox drain --ack "$id" >/dev/null || fail "concurrent note acknowledgement failed" ;;
      both-copies)
        mkdir -p "$HOME_DIR/state/inbox/handled"
        cp "$HOME_DIR/state/inbox/$id.note" "$HOME_DIR/state/inbox/handled/$id.note"
        ;;
      symlink)
        mv "$HOME_DIR/state/inbox/$id.note" "$HOME_DIR/elsewhere.note"
        ln -s "$HOME_DIR/elsewhere.note" "$HOME_DIR/state/inbox/$id.note"
        ;;
    esac
    run_drain --ack-through "$seq" --recovery-generation "$gen" 2> "$HOME_DIR/ack.err" \
      || fail "a $variant note blocked the acknowledgement: $(cat "$HOME_DIR/ack.err")"
    [ ! -s "$HOME_DIR/state/.wake-queue" ] || fail "the $variant acknowledgement left rows"
    chmod 600 "$HOME_DIR/state/inbox/$id.note" 2>/dev/null || true
  done
  pass "a deleted, unreadable, symlinked, or already-handled note never blocks the acknowledgement"
}

test_malformed_inbox_key_does_not_block() {
  local ack seq gen
  new_home malformed-key
  mkdir -p "$HOME_DIR/state/inbox"
  printf 'x\n' > "$HOME_DIR/state/inbox/..note"
  append_wake "$HOME_DIR/state" check 'inbox:../inbox/.' 'check: captain inbox note ../inbox/. - traversal' \
    || fail "setup: queueing the malformed key failed"
  ack=$(drain_to_files)
  seq=${ack% *}; gen=${ack#* }
  run_drain --ack-through "$seq" --recovery-generation "$gen" 2> "$HOME_DIR/ack.err" \
    || fail "a malformed inbox key blocked the acknowledgement: $(cat "$HOME_DIR/ack.err")"
  pass "an inbox key that names no valid note id never blocks the acknowledgement"
}

test_override_names_exact_ids_and_is_logged() {
  local a b ack seq gen rc err list
  new_home override
  a=$(queue_note "first emergency note")
  b=$(queue_note "second emergency note")
  ack=$(drain_to_files)
  seq=${ack% *}; gen=${ack#* }

  rc=0
  run_drain --ack-through "$seq" --recovery-generation "$gen" --allow-pending-notes "$a" \
    2> "$HOME_DIR/ack.err" || rc=$?
  expect_code 3 "$rc" "an override naming only one of two pending notes"
  err=$(cat "$HOME_DIR/ack.err")
  assert_contains "$err" "$b" "the partial override refusal does not name the unlisted note"
  assert_not_contains "$err" "first emergency note" "the partial override refusal still lists the allowed note"
  [ "$(awk 'END { print NR }' "$HOME_DIR/state/.wake-queue")" = 2 ] || fail "a refused override consumed rows"

  for list in '' '*' "$a,,$b" "$a,../x" "$a b"; do
    rc=0
    run_drain --ack-through "$seq" --recovery-generation "$gen" --allow-pending-notes "$list" 2>/dev/null || rc=$?
    expect_code 2 "$rc" "override list '$list'"
  done
  rc=0
  run_drain --ack-through "$seq" --recovery-generation "$gen" --allow-pending-notes 2>/dev/null || rc=$?
  expect_code 2 "$rc" "an override flag without ids"

  run_drain --ack-through "$seq" --recovery-generation "$gen" --allow-pending-notes "$b,$a" \
    2> "$HOME_DIR/ack.err" || fail "an override naming every pending note was refused: $(cat "$HOME_DIR/ack.err")"
  [ ! -s "$HOME_DIR/state/.wake-queue" ] || fail "the override acknowledgement left rows"
  [ -f "$HOME_DIR/state/inbox/$a.note" ] && [ -f "$HOME_DIR/state/inbox/$b.note" ] \
    || fail "the override handled the notes instead of leaving them pending"
  assert_grep "$a" "$HOME_DIR/state/inbox/.ack-overrides.log" "the override did not log the first note"
  assert_grep "$b" "$HOME_DIR/state/inbox/.ack-overrides.log" "the override did not log the second note"
  [ "$(awk 'END { print NR }' "$HOME_DIR/state/inbox/.ack-overrides.log")" = 2 ] \
    || fail "the override log is not one line per note: $(cat "$HOME_DIR/state/inbox/.ack-overrides.log")"
  assert_contains "$(cat "$HOME_DIR/ack.err")" "$a" "the override did not report the note it let through"
  pass "the override takes exact note ids, refuses blanket or malformed lists, and logs one line per note"
}

test_pending_block_lists_every_note_with_bounded_clean_text() {
  local a b c huge line bytes id i out err
  new_home pending-block
  a=$(queue_note $'first line of note A\nsecond line SECRET-A')
  b=$(queue_note "note B")
  huge=$(printf 'H%.0s' $(seq 1 20000))
  c=$(queue_note "$(printf '\033[31mRED\033[0m \342\200\256evil\342\200\254 \302\233c1 \342\201\246iso\342\201\251 tab\there %s' "$huge")")
  drain_to_files >/dev/null
  out=$(cat "$HOME_DIR/drain.out")
  err=$(cat "$HOME_DIR/drain.err")
  assert_contains "$out" "PENDING CAPTAIN NOTES" "a drain carrying note wakes printed no PENDING block"
  for id in "$a" "$b" "$c"; do
    line=$(grep -a "^$id " "$HOME_DIR/drain.out") || fail "the PENDING block does not list $id: $out"
    case "$line" in *"saved "[0-9]*[smhd]" ago"*) ;; *) fail "the PENDING line for $id has no age: $line" ;; esac
  done
  line=$(grep -a "^$a " "$HOME_DIR/drain.out")
  assert_contains "$line" "first line of note A" "the PENDING block lost a note's first line"
  assert_not_contains "$line" "SECRET-A" "the PENDING block printed past a note's first line"
  line=$(grep -a "^$c " "$HOME_DIR/drain.out")
  bytes=$(printf '%s' "$line" | LC_ALL=C wc -c | tr -d ' ')
  [ "$bytes" -le 220 ] || fail "a huge note produced a $bytes-byte PENDING line"
  assert_contains "$line" "RED" "the cleaned PENDING line lost visible text"
  for i in $'\033' $'\342\200\256' $'\342\200\254' $'\342\201\246' $'\342\201\251' $'\302\233' $'\t'; do
    case "$line" in *"$i"*) fail "the PENDING line kept a control or bidi byte sequence: $(printf '%s' "$line" | od -c | head -5)" ;; esac
  done
  # The block follows the wake lines, so the note sits in the same output.
  [ "$(grep -an 'PENDING CAPTAIN NOTES' "$HOME_DIR/drain.out" | head -1 | cut -d: -f1)" \
    -gt "$(grep -an "inbox:$c" "$HOME_DIR/drain.out" | head -1 | cut -d: -f1)" ] \
    || fail "the PENDING block is not after the wake lines: $out"
  case "$err" in
    *"WAKE_ACK_REQUIRED:"*"PENDING CAPTAIN NOTES"*"--ack-through "*) ;;
    *) fail "the WAKE_ACK_REQUIRED line does not mention the pending-note guard: $err" ;;
  esac
  ack_drain_err "$HOME_DIR/state" "$HOME_DIR/drain.err" 2>/dev/null \
    && fail "the shared acknowledgement parser bypassed the guard"
  pass "the PENDING block lists every pending note after the wake lines, bounded and stripped of control and bidi text"
}

test_pending_block_with_nul_bytes_and_note_count_cap() {
  local i id out shown
  new_home pending-cap
  mkdir -p "$HOME_DIR/state/inbox"
  for i in $(seq 10 23); do
    id="17000000$i-fixture$i"
    printf 'id=%s\nat=2026-10-31T00:00:00Z\nsource=text\nannounce_marker=1\n--\nbody\000with nul %s\n' "$id" "$i" \
      > "$HOME_DIR/state/inbox/$id.note"
    append_wake "$HOME_DIR/state" check "inbox:$id" "check: captain inbox note $id - fixture" \
      || fail "setup: queueing fixture note $id failed"
  done
  drain_to_files >/dev/null
  out=$(cat "$HOME_DIR/drain.out")
  if grep -aq 'ignored null byte' "$HOME_DIR/drain.err"; then fail "a NUL byte in a note leaked a shell warning"; fi
  shown=$(grep -ac '^17000000[0-9]*-fixture' "$HOME_DIR/drain.out")
  [ "$shown" -le 10 ] || fail "the PENDING block listed $shown notes past its cap"
  assert_contains "$out" "bodywith nul" "a NUL byte broke the note's first line"
  assert_contains "$out" "more pending" "the PENDING block hid notes without saying how many"
  pass "the PENDING block caps its note count, names the rest, and survives NUL bytes"
}

test_no_pending_note_leaves_drain_output_unchanged() {
  local seq gen ack
  new_home no-notes
  append_wake "$HOME_DIR/state" heartbeat heartbeat heartbeat || fail "setup: heartbeat append failed"
  ack=$(drain_to_files)
  seq=${ack% *}; gen=${ack#* }
  if grep -aq 'PENDING CAPTAIN NOTES' "$HOME_DIR/drain.out" "$HOME_DIR/drain.err"; then
    fail "a home with no pending note printed a PENDING block"
  fi
  assert_equals "WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through $seq --recovery-generation $gen" \
    "$(grep '^WAKE_ACK_REQUIRED:' "$HOME_DIR/drain.err")" "the acknowledgement line changed without a pending note"
  run_drain --ack-through "$seq" --recovery-generation "$gen" > "$HOME_DIR/ack.out" 2> "$HOME_DIR/ack.err" \
    || fail "a note-free acknowledgement failed"
  [ ! -s "$HOME_DIR/ack.out" ] && [ ! -s "$HOME_DIR/ack.err" ] || fail "a note-free acknowledgement printed output"
  run_drain > "$HOME_DIR/empty.out" 2> "$HOME_DIR/empty.err" || fail "the empty-queue drain failed"
  [ ! -s "$HOME_DIR/empty.out" ] || fail "the empty-queue drain printed: $(cat "$HOME_DIR/empty.out")"
  pass "with no pending note the drain, its acknowledgement line, and the empty drain stay as before"
}

test_range_without_note_wakes_acknowledges_as_before() {
  local id ack seq gen
  new_home range-without-notes
  append_wake "$HOME_DIR/state" heartbeat heartbeat heartbeat || fail "setup: heartbeat append failed"
  ack=$(drain_to_files)
  seq=${ack% *}; gen=${ack#* }
  # A note queued after the presentation sits above the cutoff.
  id=$(queue_note "arrived after the drain")
  run_drain --ack-through "$seq" --recovery-generation "$gen" 2> "$HOME_DIR/ack.err" \
    || fail "a range holding no note wake was refused: $(cat "$HOME_DIR/ack.err")"
  grep -q "inbox:$id" "$HOME_DIR/state/.wake-queue" || fail "the later note's wake was consumed"
  [ "$(awk 'END { print NR }' "$HOME_DIR/state/.wake-queue")" = 1 ] || fail "the heartbeat row was not consumed"
  pass "an acknowledgement whose range holds no pending note's wake consumes exactly as before"
}

test_ack_refused_while_note_pending_then_accepted_after_handling
test_vanished_unreadable_or_otherwise_handled_notes_do_not_block
test_malformed_inbox_key_does_not_block
test_override_names_exact_ids_and_is_logged
test_pending_block_lists_every_note_with_bounded_clean_text
test_pending_block_with_nul_bytes_and_note_count_cap
test_no_pending_note_leaves_drain_output_unchanged
test_range_without_note_wakes_acknowledges_as_before
