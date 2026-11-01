#!/usr/bin/env bash
# Deterministic tests for the console submit channel: bin/fm-console-submit.sh
# (opt-in, validation, caps, idempotency, and its status sweep) and the omp
# extension that delivers (.omp/extensions/fm-console-submit.ts), loaded
# through its default-export factory with a fake omp host whose
# sendUserMessage, isIdle, hasPendingMessages, and session manager behave like
# omp 18.12.6's, and driven with omp-shaped event payloads. Ownership is
# answered by bin/fm-session-lock-lib.sh, so the extension cases run Node under
# the harness name omp (OMP_NODE below). docs/console-submit.md owns the
# contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-console-submit)
SUBMIT="$ROOT/bin/fm-console-submit.sh"
EXT="$ROOT/.omp/extensions/fm-console-submit.ts"
DRIVER="$TMP_ROOT/driver.mjs"
OMP_NODE="$TMP_ROOT/harness-bin/omp"
SLEEPER_PIDS=()
# Node warns when a test-only dynamic import loads a tracked ESM extension from
# a checkout with no package.json; the cases below require clean output.
export NODE_NO_WARNINGS=1

cleanup() {
  local pid
  for pid in "${SLEEPER_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "${OMP_NODE%/*}"
ln -s "$(command -v node)" "$OMP_NODE"

cat >"$DRIVER" <<'JS'
import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

export const home = process.env.FM_HOME;
export const dir = `${home}/state/console-submit`;
let instances = 0;

export function fail(message) {
  console.error(message);
  process.exit(1);
}

export function assert(condition, message) {
  if (!condition) fail(message);
}

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export async function waitFor(check, label, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = check();
    if (value) return value;
    if (Date.now() > deadline) fail(`timed out waiting for ${label}`);
    await sleep(10);
  }
}

export function prepare({ lock = process.pid, flag = true } = {}) {
  mkdirSync(`${home}/state`, { recursive: true });
  mkdirSync(`${home}/config`, { recursive: true });
  if (lock !== null) writeFileSync(`${home}/state/.lock`, `${lock}\n`);
  setFlag(flag);
}

export function setFlag(on) {
  if (on) writeFileSync(`${home}/config/console-submit`, "");
  else rmSync(`${home}/config/console-submit`, { force: true });
}

export function submit(args, input = "", env = {}) {
  const run = spawnSync("bash", [process.env.SUBMIT, ...args], { input, encoding: "utf8", env: { ...process.env, ...env } });
  let out = null;
  try {
    out = JSON.parse(run.stdout);
  } catch {}
  return { code: run.status, out, stderr: run.stderr };
}

export function enqueue(id, text, env = {}) {
  const result = submit(["enqueue", "--id", id], text, env);
  assert(result.code === 0 && result.out?.outcome === "queued", `enqueue ${id} failed: ${JSON.stringify(result)}`);
  return result.out.receipt;
}

export function receipt(id) {
  return JSON.parse(readFileSync(`${dir}/receipts/${id}.json`, "utf8"));
}

export function names(sub) {
  try {
    return readdirSync(`${dir}/${sub}`).sort();
  } catch {
    return [];
  }
}

export function mode(path) {
  return statSync(path).mode & 0o777;
}

// A fake omp session: sendUserMessage without deliverAs starts a prompt, and
// with deliverAs "followUp" joins the follow-up queue; the test plays omp's
// side of the run with the helpers below.
export function createOmp({ streaming = false, sessionId = "sess-1", branch = [], hasUI = true } = {}) {
  const omp = { streaming, queue: [], branch, sent: [], throwOnSend: false };
  omp.ctx = {
    hasUI,
    isIdle: () => !omp.streaming,
    hasPendingMessages: () => omp.queue.length > 0,
    sessionManager: { getSessionId: () => sessionId, getBranch: () => omp.branch },
  };
  return omp;
}

// A fresh module instance per load, the way an omp reload re-imports it.
export async function loadExt(omp) {
  instances += 1;
  const mod = await import(`${pathToFileURL(process.env.EXT).href}?instance=${instances}`);
  const handlers = new Map();
  const forbidden = [];
  const refuse = (name) => () => {
    forbidden.push(name);
    throw new Error(`${name} is not part of the submit channel`);
  };
  const pi = {
    on(name, handler) {
      if (!handlers.has(name)) handlers.set(name, []);
      handlers.get(name).push(handler);
    },
    sendUserMessage(text, options) {
      if (omp.throwOnSend) throw new Error("omp refused the message");
      omp.sent.push({ text, deliverAs: options?.deliverAs ?? null });
      if (options?.deliverAs === "followUp") omp.queue.push(text);
    },
    sendMessage: refuse("sendMessage"),
    appendEntry: refuse("appendEntry"),
    registerTool: refuse("registerTool"),
    registerCommand: refuse("registerCommand"),
  };
  mod.default(pi);
  return {
    forbidden,
    async emit(name, fields = {}) {
      for (const handler of handlers.get(name) ?? []) await handler({ type: name, ...fields }, omp.ctx);
    },
  };
}

// omp puts a user message into the conversation: a queued follow-up leaves
// the queue, the message joins the branch, and message_start fires.
export async function read(ext, omp, text, timestamp = Date.now()) {
  const index = omp.queue.indexOf(text);
  if (index >= 0) omp.queue.splice(index, 1);
  const message = { role: "user", content: [{ type: "text", text }], attribution: "user", timestamp };
  omp.branch.push({ type: "message", id: `e${omp.branch.length}`, message });
  await ext.emit("message_start", { message });
}
JS
DRIVER_URL="file://$DRIVER"

run_omp() {  # <home> [ENV=value...] ; script on stdin
  local home=$1
  shift
  env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$home" EXT="$EXT" SUBMIT="$SUBMIT" DRIVER_URL="$DRIVER_URL" OMP_NODE="$OMP_NODE" \
    FM_TEST_CONSOLE_SUBMIT_POLL_MS=20 "$@" \
    "$OMP_NODE" --input-type=module
}

submit_in() {  # <home> <args...> ; text on stdin
  local home=$1
  shift
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$home" bash "$SUBMIT" "$@"
}

json_field() {  # <json> <dotted.path>
  python3 -c '
import json, sys
value = json.loads(sys.argv[1])
for key in sys.argv[2].split("."):
    value = value[key]
print(json.dumps(value) if not isinstance(value, str) else value)
' "$1" "$2"
}

entries() {  # <dir>... : the sorted names in each existing directory, space-separated
  python3 -c '
import os, sys
print(" ".join(sorted(n for d in sys.argv[1:] if os.path.isdir(d) for n in os.listdir(d))))
' "$@"
}

mode_of() {  # <path>
  python3 -c 'import os, sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$1"
}

new_home() {  # <name> [flag]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  [ "${2:-}" = flag ] && : >"$home/config/console-submit"
  printf '%s\n' "$home"
}

test_enqueue_is_opt_in_and_needs_an_explicit_home() {
  local home out rc
  home=$(new_home optin)
  rc=0
  out=$(printf 'hello' | env -u FM_HOME bash "$SUBMIT" enqueue --id m1 2>&1) || rc=$?
  expect_code 1 "$rc" "enqueue without FM_HOME"
  assert_contains "$out" "FM_HOME is not set" "enqueue without FM_HOME must say why"
  rc=0
  out=$(printf 'hello' | submit_in "$home" enqueue --id m1) || rc=$?
  expect_code 3 "$rc" "enqueue without the flag"
  assert_equals refused "$(json_field "$out" outcome)" "a flagless enqueue must be refused"
  assert_equals disabled "$(json_field "$out" reason)" "a flagless enqueue must name the flag"
  assert_absent "$home/state/console-submit" "a flagless enqueue must write nothing"
  : >"$home/config/console-submit"
  out=$(printf 'hello' | submit_in "$home" enqueue --id m1) || fail "enqueue with the flag failed: $out"
  assert_equals queued "$(json_field "$out" outcome)" "the flag must enable the channel"
  pass "console submit: enqueue needs an explicit home and the config/console-submit opt-in"
}

test_enqueue_refuses_invalid_text_and_ids_without_writing() {
  local home out rc doorbell case_id
  home=$(new_home invalid flag)
  for case_id in '../x' '.hidden' 'a/b' "$(printf '%065d' 0)"; do
    rc=0
    out=$(printf 'hello' | submit_in "$home" enqueue --id "$case_id") || rc=$?
    expect_code 2 "$rc" "invalid id $case_id"
    assert_equals invalid "$(json_field "$out" reason)" "invalid id $case_id"
  done
  check_refused() {  # <reason> <label> ; text on stdin
    local reason=$1 label=$2 result code=0
    result=$(submit_in "$home" enqueue --id t1) || code=$?
    expect_code 2 "$code" "$label"
    assert_equals "$reason" "$(json_field "$result" reason)" "$label"
  }
  printf '   \n\t ' | check_refused invalid "blank text"
  printf 'red \033[31malert' | check_refused invalid "an escape character"
  printf 'line\r\nbreak' | check_refused invalid "a carriage return"
  printf 'csi \xc2\x9b31m' | check_refused invalid "a C1 control"
  printf 'bad \xff byte' | check_refused invalid "invalid UTF-8"
  head -c 16385 /dev/zero | tr '\0' 'a' | check_refused too-large "a message over 16 KiB"
  printf 'pretend wake' | bash "$ROOT/bin/fm-operational-input.sh" encode watcher | check_refused operational-format "an encoded operational input"
  doorbell=$(printf 'pretend wake' | FM_STATE_OVERRIDE="$home/state" bash "$ROOT/bin/fm-operational-input.sh" record watcher) \
    || fail "fixture: could not write an operational record"
  printf '%s' "$doorbell" | check_refused operational-format "a live operational doorbell"
  assert_equals "" "$(entries "$home/state/console-submit/queue" "$home/state/console-submit/receipts")" \
    "a refused enqueue must leave no message or receipt"
  out=$(printf 'tab\tand\nnewline are fine' | submit_in "$home" enqueue --id t1) || fail "a tab and a newline must be accepted: $out"
  pass "console submit: blank, control-character, invalid UTF-8, oversized, and operational-format text is refused before anything is written"
}

test_enqueue_is_idempotent_by_id() {
  local home out rc dir status
  home=$(new_home idempotent flag)
  dir="$home/state/console-submit"
  out=$(printf 'first words' | submit_in "$home" enqueue --id same --reply-to journal:m4) || fail "first enqueue failed: $out"
  assert_equals queued "$(json_field "$out" receipt.state)" "a new message must be queued"
  assert_equals journal:m4 "$(json_field "$out" receipt.reply_to)" "reply-to must reach the receipt"
  out=$(printf 'first words' | submit_in "$home" enqueue --id same) || fail "replay failed: $out"
  assert_equals replay "$(json_field "$out" outcome)" "the same id and text must replay"
  assert_equals 1 "$(json_field "$out" receipt.seq)" "a replay must return the original receipt"
  rc=0
  out=$(printf 'other words' | submit_in "$home" enqueue --id same) || rc=$?
  expect_code 2 "$rc" "the same id with different text"
  assert_equals id-conflict "$(json_field "$out" reason)" "the same id with different text must conflict"
  out=$(printf 'second' | submit_in "$home" enqueue --id next) || fail "second enqueue failed: $out"
  assert_equals 2 "$(json_field "$out" receipt.seq)" "a later message must get a later seq"
  assert_equals "next.json same.json" "$(entries "$dir/queue")" "exactly one queued file per id"
  assert_equals 700 "$(mode_of "$dir")" "the channel directory must be private"
  assert_equals 600 "$(mode_of "$dir/queue/same.json")" "a queued message must be private"
  assert_equals 600 "$(mode_of "$dir/receipts/same.json")" "a receipt must be private"
  out=$(submit_in "$home" status same) || fail "status failed: $out"
  assert_equals queued "$(json_field "$out" state)" "status must print the receipt"
  rc=0
  submit_in "$home" status unknown-id >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "status of an unknown id"
  status=$(submit_in "$home" status) || fail "status without an id failed: $status"
  assert_equals true "$(json_field "$status" enabled)" "status must report the flag"
  assert_equals false "$(json_field "$status" consumer.live)" "no consumer runs in this case"
  assert_equals 2 "$(json_field "$status" queued)" "status must count queued messages"
  pass "console submit: an id is accepted once, replays with the same text, and conflicts with another"
}

test_concurrent_enqueues_keep_one_message_per_id() {
  local home dir i pids=()
  home=$(new_home concurrent flag)
  dir="$home/state/console-submit"
  for i in 1 2 3 4; do
    { printf 'shared text' | submit_in "$home" enqueue --id shared >"$TMP_ROOT/concurrent-shared-$i.out"; } &
    pids+=("$!")
    { printf 'own text %s' "$i" | submit_in "$home" enqueue --id "own$i" >"$TMP_ROOT/concurrent-own-$i.out"; } &
    pids+=("$!")
  done
  for i in "${pids[@]}"; do wait "$i" || fail "a concurrent enqueue failed"; done
  assert_equals 1 "$(grep -l '"outcome":"queued"' "$TMP_ROOT"/concurrent-shared-*.out | wc -l | tr -d ' ')" \
    "exactly one concurrent enqueue of one id may queue it"
  assert_equals 5 "$(entries "$dir/queue" | wc -w | tr -d ' ')" "one queued file per id"
  assert_equals "1 2 3 4 5" "$(python3 -c '
import json, os, sys
d = sys.argv[1]
print(" ".join(str(s) for s in sorted(json.load(open(os.path.join(d, n)))["seq"] for n in os.listdir(d))))
' "$dir/queue")" "concurrent enqueues must get distinct consecutive seqs"
  pass "console submit: concurrent enqueues of one id queue it once, and every message gets its own seq"
}

test_caps_refuse_without_writing() {
  local home now out rc i
  home=$(new_home caps flag)
  now=$(( $(date +%s) * 1000 ))
  for i in $(seq 1 10); do
    out=$(printf 'burst %s' "$i" | FM_TEST_CONSOLE_SUBMIT_NOW_MS=$((now + i)) submit_in "$home" enqueue --id "r$i") || fail "burst $i failed: $out"
  done
  rc=0
  out=$(printf 'one too many' | FM_TEST_CONSOLE_SUBMIT_NOW_MS=$((now + 59000)) submit_in "$home" enqueue --id r11) || rc=$?
  expect_code 4 "$rc" "the eleventh message in a minute"
  assert_equals rate-limited "$(json_field "$out" reason)" "the rate cap must name itself"
  assert_absent "$home/state/console-submit/receipts/r11.json" "a rate-limited message must leave no receipt"
  out=$(printf 'one too many' | FM_TEST_CONSOLE_SUBMIT_NOW_MS=$((now + 61000)) submit_in "$home" enqueue --id r11) \
    || fail "the same id must be accepted once the window passes: $out"
  for i in $(seq 12 20); do
    out=$(printf 'later %s' "$i" | FM_TEST_CONSOLE_SUBMIT_NOW_MS=$((now + 130000 + i)) submit_in "$home" enqueue --id "r$i") || fail "later $i failed: $out"
  done
  rc=0
  out=$(printf 'no room' | FM_TEST_CONSOLE_SUBMIT_NOW_MS=$((now + 200000)) submit_in "$home" enqueue --id r21) || rc=$?
  expect_code 4 "$rc" "the twenty-first waiting message"
  assert_equals queue-full "$(json_field "$out" reason)" "the depth cap must name itself"
  assert_absent "$home/state/console-submit/receipts/r21.json" "a queue-full message must leave no receipt"
  pass "console submit: the rate and depth caps refuse without writing, and the id may be sent again"
}

test_status_expires_and_retention_frees_ids() {
  local home now out
  home=$(new_home ttl flag)
  now=$(( $(date +%s) * 1000 ))
  out=$(printf 'nobody listens' | FM_TEST_CONSOLE_SUBMIT_NOW_MS=$now submit_in "$home" enqueue --id old) || fail "enqueue failed: $out"
  out=$(FM_TEST_CONSOLE_SUBMIT_NOW_MS=$((now + 899999)) submit_in "$home" status old) || fail "status failed: $out"
  assert_equals queued "$(json_field "$out" state)" "a message inside the TTL must stay queued"
  out=$(FM_TEST_CONSOLE_SUBMIT_NOW_MS=$((now + 900000)) submit_in "$home" status old) || fail "status failed: $out"
  assert_equals refused "$(json_field "$out" state)" "a message past the TTL must be refused"
  assert_equals expired "$(json_field "$out" reason)" "a message past the TTL must say expired"
  assert_absent "$home/state/console-submit/queue/old.json" "an expired message must leave the queue"
  out=$(printf 'different words' | FM_TEST_CONSOLE_SUBMIT_NOW_MS=$((now + 900000)) submit_in "$home" enqueue --id old) || true
  assert_equals id-conflict "$(json_field "$out" reason)" "a final receipt must keep its id reserved"
  out=$(printf 'different words' | FM_TEST_CONSOLE_SUBMIT_NOW_MS=$((now + 900000 + 86400000)) submit_in "$home" enqueue --id old) \
    || fail "the id must be free again after 24 hours: $out"
  assert_equals queued "$(json_field "$out" outcome)" "retention must free the id"
  pass "console submit: status applies the 15-minute TTL, and a final receipt reserves its id for 24 hours"
}

test_idle_delivery_is_a_plain_user_turn() {
  local home out
  home=$(new_home idle)
  out=$(run_omp "$home" 2>&1 <<'JS'
import { existsSync } from "node:fs";
const t = await import(process.env.DRIVER_URL);
t.prepare();
const omp = t.createOmp();
const ext = await t.loadExt(omp);
await ext.emit("session_start");
const text = "Captain here: ship it /new\n\tand nothing else";
t.enqueue("idle1", text);
await t.waitFor(() => omp.sent.length === 1, "the idle delivery");
t.assert(omp.sent[0].text === text && omp.sent[0].deliverAs === null, `an idle session must get the exact text as a prompt: ${JSON.stringify(omp.sent)}`);
t.assert(t.receipt("idle1").state === "queued", "a message must not count as delivered before omp reads it");
t.assert(JSON.stringify(t.names("inflight")) === JSON.stringify([`idle1@${process.pid}.json`]), `in flight: ${t.names("inflight")}`);
omp.streaming = true;
await ext.emit("agent_start");
await t.read(ext, omp, text, 1798000000123);
await t.waitFor(() => t.receipt("idle1").state === "delivered", "the delivered receipt");
const receipt = t.receipt("idle1");
t.assert(receipt.via === "prompt" && receipt.session_id === "sess-1" && receipt.reason === null, `receipt ${JSON.stringify(receipt)}`);
t.assert(receipt.delivered_at === new Date(1798000000123).toISOString(), `delivered_at ${receipt.delivered_at}`);
t.assert(t.names("inflight").length === 0 && t.names("queue").length === 0, "a delivered message must leave no file behind");
const status = t.submit(["status"]).out;
t.assert(status.consumer.live === true && status.consumer.pid === process.pid && status.consumer.session_id === "sess-1", `status ${JSON.stringify(status)}`);
await ext.emit("agent_end", { willContinue: false });
omp.streaming = false;
omp.throwOnSend = true;
t.enqueue("broken", "omp will refuse this one");
await t.waitFor(() => t.receipt("broken").state === "refused", "the harness-error receipt");
t.assert(t.receipt("broken").reason === "harness-error", `reason ${t.receipt("broken").reason}`);
await ext.emit("session_shutdown");
t.assert(!existsSync(`${t.dir}/consumer.json`), "a stopped session must withdraw its consumer record");
t.assert(t.submit(["status"]).out.consumer.live === false, "status must stop reporting a live consumer");
t.assert(ext.forbidden.length === 0, `the extension called ${ext.forbidden}`);
console.log("ok");
JS
  ) || fail "idle delivery: $out"
  [ "$out" = ok ] || fail "idle delivery printed unexpected output: $out"
  pass "console submit on omp: an idle session gets the exact text as an ordinary prompt and the receipt says delivered once omp reads it"
}

test_busy_delivery_uses_followups_in_order() {
  local home out
  home=$(new_home busy)
  out=$(run_omp "$home" 2>&1 <<'JS'
const t = await import(process.env.DRIVER_URL);
t.prepare();
const omp = t.createOmp({ streaming: true });
const ext = await t.loadExt(omp);
t.enqueue("a1", "first");
t.enqueue("a2", "second");
t.enqueue("a3", "first");
await ext.emit("session_start");
await t.waitFor(() => omp.sent.length === 3, "three follow-ups");
t.assert(JSON.stringify(omp.sent) === JSON.stringify([
  { text: "first", deliverAs: "followUp" },
  { text: "second", deliverAs: "followUp" },
  { text: "first", deliverAs: "followUp" },
]), `a busy session must get follow-ups in seq order: ${JSON.stringify(omp.sent)}`);
await t.read(ext, omp, "first");
await t.waitFor(() => t.receipt("a1").state === "delivered", "a1");
t.assert(t.receipt("a3").state === "queued", "an equal later text must not be marked by the earlier read");
await t.read(ext, omp, "second");
await t.read(ext, omp, "first");
await t.waitFor(() => t.receipt("a2").state === "delivered" && t.receipt("a3").state === "delivered", "a2 and a3");
t.assert(["a1", "a2", "a3"].every((id) => t.receipt(id).via === "followUp"), "follow-up receipts must say followUp");
await ext.emit("agent_end", { willContinue: false });
omp.streaming = false;
// An idle prompt holds every later message until omp reads it.
t.enqueue("b1", "start please");
await t.waitFor(() => omp.sent.length === 4, "the idle prompt");
t.enqueue("b2", "and then this");
await t.sleep(200);
t.assert(omp.sent.length === 4, `a message was handed over before the prompt was read: ${JSON.stringify(omp.sent)}`);
t.assert(t.names("queue").includes("b2.json"), "the later message must wait in the queue");
omp.streaming = true;
await ext.emit("agent_start");
await t.sleep(150);
t.assert(omp.sent.length === 4, `a message was handed over while the prompt was still starting: ${JSON.stringify(omp.sent)}`);
await t.read(ext, omp, "start please");
await t.waitFor(() => omp.sent.length === 5, "the next message");
t.assert(omp.sent[3].deliverAs === null && omp.sent[4].text === "and then this" && omp.sent[4].deliverAs === "followUp",
  `after the prompt was read the next message must follow it: ${JSON.stringify(omp.sent)}`);
await t.read(ext, omp, "and then this");
await t.waitFor(() => t.receipt("b2").state === "delivered", "b2");
console.log("ok");
JS
  ) || fail "busy delivery: $out"
  [ "$out" = ok ] || fail "busy delivery printed unexpected output: $out"
  pass "console submit on omp: a busy session gets follow-ups in order and never a steer, and an idle prompt holds later messages"
}

test_unread_handoffs_are_reported_not_replayed() {
  local home out
  home=$(new_home unread)
  out=$(run_omp "$home" 2>&1 <<'JS'
const t = await import(process.env.DRIVER_URL);
t.prepare();
const omp = t.createOmp({ streaming: true });
const ext = await t.loadExt(omp);
await ext.emit("session_start");
t.enqueue("w1", "taken back");
await t.waitFor(() => omp.sent.length === 1, "the follow-up");
await t.sleep(100);
t.assert(t.receipt("w1").state === "queued", "a follow-up must stay queued while the run goes on");
// The run ended but omp has not started reading its queue yet: a new message
// must not overtake the queued follow-up as a prompt.
omp.streaming = false;
t.enqueue("w2", "after the taken-back one");
await t.sleep(150);
t.assert(omp.sent.length === 1, `a prompt overtook a queued follow-up: ${JSON.stringify(omp.sent)}`);
// An interrupt returns the queued message to the editor; the session idles.
omp.queue.length = 0;
await ext.emit("agent_end", { willContinue: false });
await t.waitFor(() => t.receipt("w1").state === "refused", "the withdrawn receipt");
t.assert(t.receipt("w1").reason === "withdrawn", `reason ${t.receipt("w1").reason}`);
await t.waitFor(() => omp.sent.length === 2, "the next message once the queue is settled");
t.assert(omp.sent[1].text === "after the taken-back one" && omp.sent[1].deliverAs === null, `sent ${JSON.stringify(omp.sent)}`);
omp.streaming = true;
await ext.emit("agent_start");
await t.read(ext, omp, "after the taken-back one");
await ext.emit("agent_end", { willContinue: false });
omp.streaming = false;
await t.waitFor(() => t.receipt("w2").state === "delivered", "w2");
// omp rewrote the text of the prompt (a ^model mention); the run it started settles.
t.enqueue("p1", "ask ^opus about it");
await t.waitFor(() => omp.sent.length === 3, "the prompt");
omp.streaming = true;
await ext.emit("agent_start");
await t.read(ext, omp, "ask @m1 about it");
await ext.emit("agent_end", { willContinue: true });
await t.sleep(100);
t.assert(t.receipt("p1").state === "queued", "a continuing run must not settle the prompt");
await ext.emit("agent_end", { willContinue: false });
omp.streaming = false;
await t.waitFor(() => t.receipt("p1").state === "delivered", "the settled prompt");
t.assert(t.receipt("p1").via === "prompt", `via ${t.receipt("p1").via}`);
t.assert(omp.sent.length === 3, `nothing may be sent twice: ${JSON.stringify(omp.sent)}`);
console.log("ok");
JS
  ) || fail "unread handoffs: $out"
  [ "$out" = ok ] || fail "unread handoffs printed unexpected output: $out"
  pass "console submit on omp: a follow-up taken back at the terminal is refused as withdrawn, and a rewritten prompt counts once its run settles"
}

test_session_end_is_resolved_without_replay() {
  local home out
  home=$(new_home reload)
  out=$(run_omp "$home" 2>&1 <<'JS'
const t = await import(process.env.DRIVER_URL);
t.prepare();
// omp kept its queue across the session change: the next session reads it.
const omp = t.createOmp({ streaming: true });
let ext = await t.loadExt(omp);
await ext.emit("session_start");
t.enqueue("r1", "survives a reload");
await t.waitFor(() => omp.sent.length === 1, "r1 handed over");
await ext.emit("session_shutdown");
ext = await t.loadExt(omp);
await ext.emit("session_start");
await t.sleep(150);
t.assert(t.receipt("r1").state === "queued", "a handoff still in the omp queue must wait for omp");
await t.read(ext, omp, "survives a reload");
await t.waitFor(() => t.receipt("r1").state === "delivered", "r1 delivered after the reload");
// omp read it while no extension listened: the branch proves it.
t.enqueue("r2", "read in between");
await t.waitFor(() => omp.sent.length === 2, "r2 handed over");
await ext.emit("session_shutdown");
omp.queue.length = 0;
omp.branch.push({ type: "message", id: "late", message: { role: "user", content: [{ type: "text", text: "read in between" }], attribution: "user", timestamp: Date.now() + 5 } });
omp.streaming = false;
ext = await t.loadExt(omp);
await ext.emit("session_start");
await t.waitFor(() => t.receipt("r2").state === "delivered", "r2 found in the branch");
// A new session drops the omp queue: refused, never replayed.
omp.streaming = true;
t.enqueue("r3", "lost with the session");
await t.waitFor(() => omp.sent.length === 3, "r3 handed over");
await ext.emit("session_shutdown");
const fresh = t.createOmp({ sessionId: "sess-2" });
ext = await t.loadExt(fresh);
await ext.emit("session_start");
await t.waitFor(() => t.receipt("r3").state === "refused", "r3 refused");
t.assert(t.receipt("r3").reason === "session-ended", `reason ${t.receipt("r3").reason}`);
t.assert(fresh.sent.length === 0 && omp.sent.length === 3, "a handoff must never be sent again");
t.assert(t.names("inflight").length === 0, `in flight: ${t.names("inflight")}`);
console.log("ok");
JS
  ) || fail "session end: $out"
  [ "$out" = ok ] || fail "session end printed unexpected output: $out"
  pass "console submit on omp: a handoff across a session end is delivered when omp read it and otherwise refused as session-ended, never replayed"
}

test_dead_process_handoffs_end_as_session_ended() {
  local home out child dead_pid
  home=$(new_home dead)
  child=$(cat <<'JS'
const t = await import(process.env.DRIVER_URL);
t.prepare();
const omp = t.createOmp({ streaming: true });
const ext = await t.loadExt(omp);
await ext.emit("session_start");
t.enqueue(process.env.MESSAGE_ID, `handed by ${process.env.MESSAGE_ID}`);
await t.waitFor(() => omp.sent.length === 1, "the handoff");
await t.waitFor(() => t.names("inflight").length === 1, "the inflight record");
process.exit(0);
JS
)
  printf '%s\n' "$child" | run_omp "$home" MESSAGE_ID=d1 >/dev/null 2>&1 || fail "fixture: the first omp did not hand d1 over"
  out=$(submit_in "$home" status d1) || fail "status failed: $out"
  assert_equals session-ended "$(json_field "$out" reason)" "status must refuse a handoff whose omp process is gone"
  assert_equals "" "$(entries "$home/state/console-submit/inflight")" "the dead handoff must leave in-flight"
  printf '%s\n' "$child" | run_omp "$home" MESSAGE_ID=d2 >/dev/null 2>&1 || fail "fixture: the second omp did not hand d2 over"
  # A process that died after claiming d3 but before stamping and sending it.
  dead_pid=$(sh -c 'echo $$')
  printf 'claimed but never sent' | submit_in "$home" enqueue --id d3 >/dev/null || fail "fixture: enqueue d3 failed"
  mv "$home/state/console-submit/queue/d3.json" "$home/state/console-submit/inflight/d3@$dead_pid.json"
  out=$(run_omp "$home" 2>&1 <<'JS'
const t = await import(process.env.DRIVER_URL);
t.prepare();
const omp = t.createOmp({ streaming: true });
const ext = await t.loadExt(omp);
await ext.emit("session_start");
await t.waitFor(() => t.receipt("d2").state === "refused", "d2 refused by the next primary");
t.assert(t.receipt("d2").reason === "session-ended", `reason ${t.receipt("d2").reason}`);
await t.waitFor(() => omp.sent.length === 1, "the never-sent claim delivered");
t.assert(omp.sent[0].text === "claimed but never sent" && omp.sent[0].deliverAs === "followUp",
  `only the never-sent claim may be sent, once: ${JSON.stringify(omp.sent)}`);
await t.read(ext, omp, "claimed but never sent");
await t.waitFor(() => t.receipt("d3").state === "delivered", "d3 delivered");
await t.sleep(100);
t.assert(omp.sent.length === 1, `the handoff of a dead process must never be sent again: ${JSON.stringify(omp.sent)}`);
console.log("ok");
JS
  ) || fail "dead process: $out"
  [ "$out" = ok ] || fail "dead process printed unexpected output: $out"
  pass "console submit: a handoff whose omp process died ends as session-ended, and a claim it never sent is delivered once"
}

test_only_the_flagged_lock_owner_with_a_ui_reads() {
  local home out sleeper
  home=$(new_home gating)
  sleep 60 &
  sleeper=$!
  SLEEPER_PIDS+=("$sleeper")
  out=$(run_omp "$home" OTHER_PID="$sleeper" 2>&1 <<'JS'
import { existsSync, writeFileSync } from "node:fs";
const t = await import(process.env.DRIVER_URL);
t.prepare({ lock: process.env.OTHER_PID });
const omp = t.createOmp();
const other = await t.loadExt(omp);
await other.emit("session_start");
t.enqueue("g1", "for the real primary");
await t.sleep(250);
t.assert(omp.sent.length === 0, "a session that does not own the lock must read nothing");
t.assert(!existsSync(`${t.dir}/consumer.json`), "a non-owner must not publish a consumer");
await other.emit("session_shutdown");
writeFileSync(`${t.home}/state/.lock`, `${process.pid}\n`);
const headless = t.createOmp({ hasUI: false });
const sub = await t.loadExt(headless);
await sub.emit("session_start");
await t.sleep(250);
t.assert(headless.sent.length === 0, "a session without a UI must read nothing");
t.setFlag(false);
const main = t.createOmp();
const ext = await t.loadExt(main);
await ext.emit("session_start");
await t.sleep(250);
t.assert(main.sent.length === 0, "without the flag nothing may be read");
t.assert(t.names("queue").includes("g1.json"), "without the flag a message must stay queued");
t.setFlag(true);
await t.waitFor(() => main.sent.length === 1, "delivery once the flag returns");
t.assert(main.sent[0].text === "for the real primary", `sent ${JSON.stringify(main.sent)}`);
console.log("ok");
JS
  ) || fail "gating: $out"
  [ "$out" = ok ] || fail "gating printed unexpected output: $out"
  pass "console submit on omp: only the lock-owning session with a UI reads, and only while the flag exists"
}

test_expired_and_invalid_queue_files_are_refused() {
  local home out
  home=$(new_home stale)
  out=$(run_omp "$home" 2>&1 <<'JS'
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
const t = await import(process.env.DRIVER_URL);
t.prepare();
t.enqueue("x2", "the real words");
const path = `${t.dir}/queue/x2.json`;
const record = JSON.parse(readFileSync(path, "utf8"));
writeFileSync(path, JSON.stringify({ ...record, text: "swapped words" }));
// A consistent replacement: its own text and digest, not those of the receipt.
t.enqueue("x3", "the original");
const other = `${t.dir}/queue/x3.json`;
const replacement = { ...JSON.parse(readFileSync(other, "utf8")), text: "a replacement" };
replacement.sha256 = createHash("sha256").update(replacement.text).digest("hex");
writeFileSync(other, JSON.stringify(replacement));
// Enqueued last, so no enqueue sweep sees it expire before the primary does.
t.enqueue("x1", "too old", { FM_TEST_CONSOLE_SUBMIT_NOW_MS: String(Date.now() - 16 * 60_000) });
const omp = t.createOmp();
const ext = await t.loadExt(omp);
await ext.emit("session_start");
await t.waitFor(() => ["x1", "x2", "x3"].every((id) => t.receipt(id).state === "refused"), "the three refusals");
const reasons = ["x1", "x2", "x3"].map((id) => t.receipt(id).reason);
t.assert(JSON.stringify(reasons) === JSON.stringify(["expired", "invalid", "invalid"]), `reasons ${reasons}`);
t.assert(omp.sent.length === 0, `nothing may be sent: ${JSON.stringify(omp.sent)}`);
t.assert(t.names("queue").length === 0, `queue: ${t.names("queue")}`);
console.log("ok");
JS
  ) || fail "stale queue: $out"
  [ "$out" = ok ] || fail "stale queue printed unexpected output: $out"
  pass "console submit on omp: an expired or altered queued message is refused, never sent"
}

test_enqueue_is_opt_in_and_needs_an_explicit_home
test_enqueue_refuses_invalid_text_and_ids_without_writing
test_enqueue_is_idempotent_by_id
test_concurrent_enqueues_keep_one_message_per_id
test_caps_refuse_without_writing
test_status_expires_and_retention_frees_ids
test_idle_delivery_is_a_plain_user_turn
test_busy_delivery_uses_followups_in_order
test_unread_handoffs_are_reported_not_replayed
test_session_end_is_resolved_without_replay
test_dead_process_handoffs_end_as_session_ended
test_only_the_flagged_lock_owner_with_a_ui_reads
test_expired_and_invalid_queue_files_are_refused
