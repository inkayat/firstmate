#!/usr/bin/env bash
# Deterministic tests for the read-only Pi console journal extension
# (.pi/extensions/fm-console-bridge.ts). Every case loads the real extension
# through its default-export factory with a recording ExtensionAPI whose
# sending, tool, command, and event-bus surfaces refuse every call, and drives
# it with synthetic session managers and event payloads shaped like the ones
# Pi 1.4.0's agent loop emits (extension handlers run before a finished
# message joins the session). docs/pi-console-journal.md owns the contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-console-bridge)
BRIDGE="$ROOT/.pi/extensions/fm-console-bridge.ts"
DRIVER="$TMP_ROOT/bridge-driver.mjs"
# Node warns when a test-only dynamic import loads a tracked ESM extension from
# a checkout with no package.json; the cases below require clean stderr.
export NODE_NO_WARNINGS=1

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

cat >"$DRIVER" <<'JS'
import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { performance } from "node:perf_hooks";
import { pathToFileURL } from "node:url";

export const RECORD_MAX = 65536;
let instances = 0;
let entries = 0;

export function fail(message) {
  console.error(message);
  process.exit(1);
}

export function assert(condition, message) {
  if (!condition) fail(message);
}

export function journalDir(home) {
  return `${home}/state/extensions/pi-console-bridge`;
}

export function prepareHome(home, lockPid = process.pid) {
  mkdirSync(`${home}/state`, { recursive: true });
  if (lockPid !== null) writeFileSync(`${home}/state/.lock`, `${lockPid}\n`);
}

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// A fresh module instance per load, the way a Pi reload re-imports project
// extensions; module-level state is therefore not shared between loads.
export async function loadBridge() {
  instances += 1;
  const mod = await import(`${pathToFileURL(process.env.BRIDGE).href}?instance=${instances}`);
  const handlers = new Map();
  const forbidden = [];
  const refuse = (name) => () => {
    forbidden.push(name);
    throw new Error(`${name} is not part of the read-only journal`);
  };
  const pi = {
    on(name, handler) {
      if (!handlers.has(name)) handlers.set(name, []);
      handlers.get(name).push(handler);
      return () => {};
    },
    sendUserMessage: refuse("sendUserMessage"),
    sendMessage: refuse("sendMessage"),
    appendEntry: refuse("appendEntry"),
    registerTool: refuse("registerTool"),
    registerCommand: refuse("registerCommand"),
    registerShortcut: refuse("registerShortcut"),
    registerFlag: refuse("registerFlag"),
    registerProvider: refuse("registerProvider"),
    registerMessageRenderer: refuse("registerMessageRenderer"),
    exec: refuse("exec"),
    events: { on: refuse("events.on"), emit: refuse("events.emit") },
  };
  const loaded = mod.default(pi);
  if (loaded && typeof loaded.then === "function") await loaded;
  const bridge = {
    handlers,
    forbidden,
    errors: [],
    maxSyncMs: 0,
    async emit(name, fields, ctx) {
      for (const handler of handlers.get(name) ?? []) {
        const started = performance.now();
        let pending;
        try {
          pending = handler({ type: name, ...fields }, ctx);
        } catch (error) {
          bridge.errors.push(`${name}: ${error?.stack ?? error}`);
          continue;
        } finally {
          bridge.maxSyncMs = Math.max(bridge.maxSyncMs, performance.now() - started);
        }
        try {
          await pending;
        } catch (error) {
          bridge.errors.push(`${name}: ${error?.stack ?? error}`);
        }
      }
    },
    // Fire handlers without yielding to the event loop, so no asynchronous
    // writer can make progress until the caller awaits.
    emitSync(name, fields, ctx) {
      for (const handler of handlers.get(name) ?? []) {
        const started = performance.now();
        try {
          const pending = handler({ type: name, ...fields }, ctx);
          if (pending && typeof pending.catch === "function") {
            pending.catch((error) => bridge.errors.push(`${name}: ${error?.stack ?? error}`));
          }
        } catch (error) {
          bridge.errors.push(`${name}: ${error?.stack ?? error}`);
        }
        bridge.maxSyncMs = Math.max(bridge.maxSyncMs, performance.now() - started);
      }
    },
  };
  return bridge;
}

export function assertClean(bridge, label) {
  assert(bridge.forbidden.length === 0, `${label}: the journal called ${bridge.forbidden.join(", ")}`);
  assert(bridge.errors.length === 0, `${label}: a handler threw:\n${bridge.errors.join("\n")}`);
}

// A session manager with the read surface Pi's ReadonlySessionManager exposes
// to extensions: an append-only entry tree with a movable leaf.
export function createSession({ file, id }) {
  const byId = new Map();
  let leaf = null;
  const manager = {
    getSessionFile: () => file,
    getSessionId: () => id,
    getLeafId: () => leaf,
    getEntry: (entryId) => byId.get(entryId),
    getEntries: () => [...byId.values()],
    getBranch(fromId) {
      const path = [];
      let current = (fromId ?? leaf) ? byId.get(fromId ?? leaf) : undefined;
      while (current) {
        path.push(current);
        current = current.parentId ? byId.get(current.parentId) : undefined;
      }
      return path.reverse();
    },
  };
  const add = (fields) => {
    entries += 1;
    const entry = {
      id: entries.toString(16).padStart(8, "0"),
      parentId: leaf,
      timestamp: new Date().toISOString(),
      ...fields,
    };
    byId.set(entry.id, entry);
    leaf = entry.id;
    return entry;
  };
  return {
    manager,
    appendMessage: (message) => add({ type: "message", message }),
    appendEntry: (fields) => add(fields),
    moveTo(entryId) {
      leaf = entryId;
    },
  };
}

export function contextFor(session, idle = () => true) {
  return { sessionManager: session.manager, isIdle: idle, hasUI: false, mode: "print", cwd: process.cwd() };
}

const usage = {
  input: 3,
  output: 5,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: 8,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};

export function userMessage(content) {
  return { role: "user", content, timestamp: Date.now() };
}

export function assistantMessage(content, extra = {}) {
  return {
    role: "assistant",
    content,
    api: "faux-test-api",
    provider: "faux-test",
    model: "deterministic",
    usage,
    stopReason: "stop",
    timestamp: Date.now(),
    ...extra,
  };
}

// One user message, then it joins the session, as in Pi's agent loop.
export async function userTurn(bridge, session, ctx, content) {
  const message = userMessage(content);
  await bridge.emit("message_start", { message }, ctx);
  await bridge.emit("message_end", { message }, ctx);
  session.appendMessage(message);
  return message;
}

// One streamed assistant message: every block's start/delta/end update with
// Pi's cumulative partial snapshot, then message_end, then the session append.
export async function assistantTurn(bridge, session, ctx, blocks, { extra = {}, chunk = 5 } = {}) {
  const partial = assistantMessage([], { stopReason: "pending" });
  const update = (type, fields) => bridge.emit("message_update", {
    message: { ...partial, content: [...partial.content] },
    assistantMessageEvent: { type, ...fields, partial: { ...partial, content: [...partial.content] } },
  }, ctx);
  await bridge.emit("message_start", { message: { ...partial, content: [] } }, ctx);
  for (let index = 0; index < blocks.length; index += 1) {
    const block = blocks[index];
    if (block.type === "text" || block.type === "thinking") {
      const field = block.type === "text" ? "text" : "thinking";
      const source = block[field];
      partial.content[index] = { type: block.type, [field]: "" };
      await update(`${block.type}_start`, { contentIndex: index });
      for (let at = 0; at < source.length; at += chunk) {
        const delta = source.slice(at, at + chunk);
        partial.content[index] = { type: block.type, [field]: partial.content[index][field] + delta };
        await update(`${block.type}_delta`, { contentIndex: index, delta });
      }
      await update(`${block.type}_end`, { contentIndex: index, content: source });
    } else if (block.type === "toolCall") {
      partial.content[index] = { type: "toolCall", id: block.id, name: block.name, arguments: {} };
      await update("toolcall_start", { contentIndex: index, id: block.id, toolName: block.name });
      await update("toolcall_delta", { contentIndex: index, delta: JSON.stringify(block.arguments) });
      partial.content[index] = block;
      await update("toolcall_end", { contentIndex: index, toolCall: block });
    }
  }
  const final = assistantMessage(blocks, extra);
  await bridge.emit("message_end", { message: final }, ctx);
  session.appendMessage(final);
  return final;
}

export async function toolRun(bridge, session, ctx, { id, name, args, result, isError = false, durationMs = 12 }) {
  await bridge.emit("tool_execution_start", { toolCallId: id, toolName: name, args }, ctx);
  await bridge.emit("tool_execution_update", { toolCallId: id, toolName: name, args, partialResult: result }, ctx);
  await bridge.emit("tool_execution_end", { toolCallId: id, toolName: name, result, isError, durationMs }, ctx);
  const message = {
    role: "toolResult",
    toolCallId: id,
    toolName: name,
    content: result.content,
    details: result.details,
    isError,
    timestamp: Date.now(),
  };
  await bridge.emit("message_start", { message }, ctx);
  await bridge.emit("message_end", { message }, ctx);
  session.appendMessage(message);
}

export async function waitFor(predicate, label, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  let lastError = "";
  for (;;) {
    try {
      const value = predicate();
      if (value) return value;
    } catch (error) {
      lastError = String(error?.message ?? error);
    }
    if (Date.now() > deadline) fail(`timed out waiting for ${label}${lastError ? ` (${lastError})` : ""}`);
    await sleep(10);
  }
}

export function readCurrent(home) {
  return JSON.parse(readFileSync(`${journalDir(home)}/current.json`, "utf8"));
}

// Strict LF framing: only complete lines are records, each at most 64 KiB
// including its LF, with seq starting at 1 and rising by exactly one.
export function readJournal(home, gen) {
  const bytes = readFileSync(`${journalDir(home)}/${gen}.jsonl`);
  const records = [];
  let start = 0;
  while (start < bytes.length) {
    const end = bytes.indexOf(0x0a, start);
    if (end < 0) throw new Error(`torn tail in journal ${gen}`);
    if (end + 1 - start > RECORD_MAX) fail(`journal ${gen} record ${records.length + 1} is ${end + 1 - start} bytes`);
    records.push(JSON.parse(bytes.subarray(start, end).toString("utf8")));
    start = end + 1;
  }
  records.forEach((record, index) => {
    if (record.seq !== index + 1 || record.gen !== gen) {
      fail(`journal ${gen} record ${index + 1} broke seq/gen: ${JSON.stringify(record).slice(0, 300)}`);
    }
  });
  return records;
}

export function lastRecord(home, gen) {
  const records = readJournal(home, gen);
  return records[records.length - 1];
}

export function journalNames(home) {
  return readdirSync(journalDir(home)).sort();
}

export function allBytes(home) {
  const dir = journalDir(home);
  if (!existsSync(dir)) return "";
  return readdirSync(dir)
    .filter((name) => lstatSync(`${dir}/${name}`).isFile())
    .map((name) => readFileSync(`${dir}/${name}`, "latin1"))
    .join("\n");
}

export function byteLength(text) {
  return Buffer.byteLength(text, "utf8");
}
JS

DRIVER_URL="file://$DRIVER"

run_node() {  # <home> [ENV=value...] ; script on stdin
  local home=$1
  shift
  env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_OPERATIONAL_INPUT_SCRIPT \
    FM_HOME="$home" BRIDGE="$BRIDGE" DRIVER_URL="$DRIVER_URL" "$@" \
    node --input-type=module
}

test_sessions_that_do_not_own_the_lock_write_nothing() {
  local scenario home out
  for scenario in import-only missing-lock other-holder nested-session; do
    home="$TMP_ROOT/non-owner-$scenario"
    mkdir -p "$home"
    out=$(run_node "$home" SCENARIO="$scenario" 2>&1 <<'JS'
import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
const t = await import(process.env.DRIVER_URL);
const home = process.env.FM_HOME;
const scenario = process.env.SCENARIO;
let holder = null;
let recorded = "";
if (scenario === "missing-lock") t.prepareHome(home, null);
if (scenario === "import-only") t.prepareHome(home);
if (scenario === "other-holder") {
  holder = spawn("sleep", ["30"], { stdio: "ignore" });
  t.prepareHome(home, holder.pid);
}
if (scenario === "nested-session") {
  // The parent process holds the lock and is the live primary recorded in
  // current.json, so this process is a Pi session started inside it.
  t.prepareHome(home, process.ppid);
  mkdirSync(t.journalDir(home), { recursive: true, mode: 0o700 });
  recorded = JSON.stringify({ schema: "fm-console-journal.v1", piPid: process.ppid, gen: "a".repeat(32), state: "live" });
  writeFileSync(`${t.journalDir(home)}/current.json`, recorded, { mode: 0o600 });
}
try {
  const bridge = await t.loadBridge();
  if (scenario !== "import-only") {
    const session = t.createSession({ file: "/sessions/2026-10-31_main.jsonl", id: "main-session" });
    session.appendMessage(t.userMessage("EARLIER_CAPTAIN_TEXT"));
    const ctx = t.contextFor(session);
    await bridge.emit("session_start", { reason: "startup" }, ctx);
    // Ownership is answered asynchronously; yield wherever a check starts so
    // a wrong "owned" answer would activate before the case asserts.
    await t.sleep(300);
    for (let run = 0; run < 2; run += 1) {
      await bridge.emit("agent_start", {}, ctx);
      await t.sleep(100);
      await t.userTurn(bridge, session, ctx, `NON_OWNER_PROMPT_${run}`);
      await t.assistantTurn(bridge, session, ctx, [{ type: "text", text: `NON_OWNER_ANSWER_${run}` }]);
      await t.toolRun(bridge, session, ctx, { id: `call_${run}`, name: "read", args: { path: "x" }, result: { content: [{ type: "text", text: "r" }], details: {} } });
      await bridge.emit("agent_settled", { aborted: false }, ctx);
      await t.sleep(300);
    }
    await bridge.emit("session_shutdown", { reason: "quit" }, ctx);
  }
  // Give any wrongly started writer time to touch the disk before asserting.
  await t.sleep(400);
  t.assertClean(bridge, scenario);
  if (scenario === "nested-session") {
    t.assert(readdirSync(t.journalDir(home)).join(",") === "current.json", `${scenario}: files appeared beside the primary's record`);
    t.assert(readFileSync(`${t.journalDir(home)}/current.json`, "utf8") === recorded, `${scenario}: the primary's record was rewritten`);
  } else {
    t.assert(!existsSync(`${home}/state/extensions`), `${scenario}: a non-owner created ${home}/state/extensions`);
  }
} finally {
  holder?.kill();
}
console.log("ok");
JS
    ) || fail "non-owner $scenario: $out"
    [ "$out" = ok ] || fail "non-owner $scenario printed unexpected output: $out"
  done
  pass "Pi console journal: import alone, a missing lock, a foreign live holder, and a Pi nested inside the primary all write nothing"
}

test_lock_owner_publishes_snapshot_then_ordered_live_events() {
  local home="$TMP_ROOT/owner-live" out
  mkdir -p "$home"
  out=$(run_node "$home" 2>&1 <<'JS'
import { realpathSync, statSync, existsSync, writeFileSync } from "node:fs";
const t = await import(process.env.DRIVER_URL);
const home = process.env.FM_HOME;
t.prepareHome(home, null);
const session = t.createSession({ file: "/sessions/--home--/2026-10-31T10-00-00_conv-1.jsonl", id: "conv-1" });
session.appendMessage(t.userMessage("PRIOR_CAPTAIN"));
session.appendMessage(t.assistantMessage([{ type: "text", text: "PRIOR_ANSWER" }]));
const bridge = await t.loadBridge();
let busy = false;
const ctx = t.contextFor(session, () => !busy);
await bridge.emit("session_start", { reason: "startup" }, ctx);
await t.sleep(300);
t.assert(!existsSync(t.journalDir(home)), "the journal started before the session held the lock");

// The session-start script takes the lock during the first run.
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
busy = true;
await bridge.emit("agent_start", {}, ctx);
await t.userTurn(bridge, session, ctx, "FIRST_PROMPT");
await t.assistantTurn(bridge, session, ctx, [{ type: "text", text: "FIRST_ANSWER" }]);
busy = false;
await bridge.emit("agent_settled", { aborted: false }, ctx);
const first = await t.waitFor(() => {
  const current = t.readCurrent(home);
  return current.state === "live" ? current : null;
}, "activation after the lock appeared");
t.assert(first.startedReason === "activate", `activation reason was ${first.startedReason}`);
const opened = t.readJournal(home, first.gen);
const snapshot = opened[0];
t.assert(snapshot.type === "snapshot" && snapshot.seq === 1, "the generation did not open with a snapshot");
t.assert(JSON.stringify(snapshot.items.map((item) => [item.role, item.text])) === JSON.stringify([
  ["captain", "PRIOR_CAPTAIN"], ["assistant", "PRIOR_ANSWER"], ["captain", "FIRST_PROMPT"], ["assistant", "FIRST_ANSWER"],
]), `snapshot items were ${JSON.stringify(snapshot.items)}`);
t.assert(snapshot.omittedBefore === 0 && snapshot.busy === false, `snapshot header was ${JSON.stringify(snapshot)}`);
t.assert(snapshot.leafId === session.manager.getLeafId(), "snapshot leaf did not match the session leaf");
t.assert(snapshot.conversation === "2026-10-31T10-00-00_conv-1.jsonl" && snapshot.sessionId === "conv-1", "snapshot identity was wrong");

busy = true;
await bridge.emit("agent_start", {}, ctx);
await t.userTurn(bridge, session, ctx, "SECOND_PROMPT");
await t.assistantTurn(bridge, session, ctx, [
  { type: "thinking", thinking: "private reasoning" },
  { type: "text", text: "Hello world" },
  { type: "toolCall", id: "call_live", name: "read", arguments: { path: "notes.txt" } },
  { type: "text", text: "Second block" },
], { extra: { stopReason: "toolUse" } });
await t.toolRun(bridge, session, ctx, { id: "call_live", name: "read", args: { path: "notes.txt" }, result: { content: [{ type: "text", text: "file body" }], details: {} }, durationMs: 41 });
await t.assistantTurn(bridge, session, ctx, [{ type: "text", text: "WRAP" }]);
busy = false;
await bridge.emit("agent_settled", { aborted: false }, ctx);
const records = await t.waitFor(() => {
  const all = t.readJournal(home, first.gen);
  return all[all.length - 1].type === "run" && all[all.length - 1].state === "settled" ? all : null;
}, "the second run to settle in the journal");

const live = records.slice(opened.length);
const shape = live.filter((record) => record.type !== "delta").map((record) => {
  if (record.type === "run") return `run:${record.state}`;
  if (record.type === "tool") return `tool:${record.phase}:${record.name}`;
  return `message:${record.phase}:${record.role}:${record.msg}`;
});
const expected = [
  "run:started",
  "message:end:captain:m1",
  "message:start:assistant:m2",
  "message:end:assistant:m2",
  "tool:start:read",
  "tool:end:read",
  "message:start:assistant:m3",
  "message:end:assistant:m3",
  "run:settled",
];
t.assert(JSON.stringify(shape) === JSON.stringify(expected), `live record order was ${JSON.stringify(shape)}`);
const byMessage = (msg, block) => live.filter((r) => r.type === "delta" && r.msg === msg && r.block === block).map((r) => r.text).join("");
t.assert(byMessage("m2", 1) === "Hello world" && byMessage("m2", 3) === "Second block" && byMessage("m3", 0) === "WRAP", "deltas did not rebuild each text block");
t.assert(live.filter((r) => r.type === "delta").every((r) => r.msg !== "m2" || r.block === 1 || r.block === 3), "a non-text block produced a delta");
const ends = live.filter((r) => r.type === "message" && r.phase === "end");
t.assert(ends[0].text === "SECOND_PROMPT", "captain text was wrong");
t.assert(ends[1].text === "Hello world\nSecond block" && ends[1].stopReason === "toolUse", `assistant end was ${JSON.stringify(ends[1])}`);
t.assert(ends[2].text === "WRAP" && ends[2].stopReason === "stop", "final assistant end was wrong");
const toolEnd = live.find((r) => r.type === "tool" && r.phase === "end");
t.assert(toolEnd.durationMs === 41 && toolEnd.isError === false && toolEnd.tool === live.find((r) => r.type === "tool").tool, "tool end did not carry its state and timing");
t.assert(live.find((r) => r.type === "run" && r.state === "settled").aborted === false, "settled record lost aborted");
t.assert(records.every((record, index) => index === 0 || record.at >= records[index - 1].at), "record times went backwards against seq");

const current = t.readCurrent(home);
t.assert(current.schema === "fm-console-journal.v1", "schema was wrong");
t.assert(current.capabilities?.journal === true && current.capabilities?.submit === false, "capabilities must say read-only");
t.assert(current.harness === "pi" && current.home === realpathSync(home), "home identity was wrong");
t.assert(current.lockPid === String(process.pid) && current.piPid === process.pid, "process identity was wrong");
t.assert(current.sessionId === "conv-1" && current.conversation === "2026-10-31T10-00-00_conv-1.jsonl", "conversation identity was wrong");
t.assert(/^[0-9a-f]{32}$/.test(current.gen) && current.journal === `${current.gen}.jsonl` && current.previousGen === null, "generation identity was wrong");
t.assert((statSync(t.journalDir(home)).mode & 0o777) === 0o700, "journal directory is not 0700");
for (const name of t.journalNames(home)) {
  t.assert((statSync(`${t.journalDir(home)}/${name}`).mode & 0o777) === 0o600, `${name} is not 0600`);
}
t.assert(JSON.stringify(t.journalNames(home)) === JSON.stringify([`${current.gen}.jsonl`, "current.json"].sort()), `unexpected files ${t.journalNames(home)}`);
t.assertClean(bridge, "owner");
console.log("ok");
JS
  ) || fail "owner journal: $out"
  [ "$out" = ok ] || fail "owner journal printed unexpected output: $out"
  pass "Pi console journal: the lock owner activates once the lock appears, opens with a snapshot, and journals runs, text deltas, authoritative ends, and tools in order"
}

test_partial_text_reaches_disk_before_the_message_ends() {
  local home="$TMP_ROOT/partial" out
  mkdir -p "$home"
  out=$(run_node "$home" 2>&1 <<'JS'
const t = await import(process.env.DRIVER_URL);
const home = process.env.FM_HOME;
t.prepareHome(home);
const session = t.createSession({ file: "/sessions/conv-s.jsonl", id: "conv-s" });
const bridge = await t.loadBridge();
const ctx = t.contextFor(session, () => false);
await bridge.emit("session_start", { reason: "startup" }, ctx);
const current = await t.waitFor(() => t.readCurrent(home), "activation");
await bridge.emit("agent_start", {}, ctx);
const pending = t.assistantMessage([], { stopReason: "pending" });
await bridge.emit("message_start", { message: pending }, ctx);
// A small delta stays below the size flush, so only the timer can publish it.
await bridge.emit("message_update", {
  message: t.assistantMessage([{ type: "text", text: "STREAMING_" }], { stopReason: "pending" }),
  assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "STREAMING_", partial: pending },
}, ctx);
await t.waitFor(() => t.readJournal(home, current.gen).some((r) => r.type === "delta" && r.text === "STREAMING_"), "the partial text to reach disk while the message streams", 3000);
t.assert(!t.readJournal(home, current.gen).some((r) => r.type === "message" && r.phase === "end"), "the message ended before its partial text was checked");
t.assertClean(bridge, "partial");
console.log("ok");
JS
  ) || fail "partial text: $out"
  [ "$out" = ok ] || fail "partial text printed unexpected output: $out"
  pass "Pi console journal: buffered streamed text is flushed on its timer while the message is still streaming"
}

test_private_content_never_reaches_disk() {
  local home="$TMP_ROOT/privacy" out
  mkdir -p "$home"
  out=$(run_node "$home" 2>&1 <<'JS'
const t = await import(process.env.DRIVER_URL);
const { encodeFirstmateOperationalInput } = await import(new URL("../../.pi/extensions/lib/fm-operational-input.ts", `file://${process.env.BRIDGE}`).href);
const home = process.env.FM_HOME;
t.prepareHome(home);
const legacyWatcher = "FIRSTMATE WATCHER WAKE: LEGACY_WATCHER_SECRET\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.";
const operational = [
  ["watcher", encodeFirstmateOperationalInput("watcher", "CURRENT_WATCHER_SECRET")],
  ["launch-brief", encodeFirstmateOperationalInput("launch-brief", "LAUNCH_BRIEF_SECRET")],
  ["from-firstmate", "[fm-from-firstmate]\u2063FROM_FIRSTMATE_SECRET"],
  ["watcher", legacyWatcher],
];
const session = t.createSession({ file: "/SESSION_DIR_SECRET/2026-10-31_conv-p.jsonl", id: "conv-p" });
const toolResult = (name) => ({ content: [{ type: "text", text: `${name}_RESULT_SECRET` }], details: { raw: `${name}_DETAILS_SECRET` } });
session.appendMessage({ role: "system", content: "SYSTEM_PROMPT_SECRET", sections: { preamble: "SYSTEM_SECTION_SECRET" }, timestamp: Date.now() });
for (const [, text] of operational) session.appendMessage(t.userMessage(text));
session.appendMessage(t.userMessage([{ type: "text", text: "captain shares a picture" }, { type: "image", data: "SNAPSHOT_IMAGE_SECRET", mimeType: "image/png" }]));
session.appendMessage(t.assistantMessage([
  { type: "thinking", thinking: "SNAPSHOT_THINKING_SECRET", thinkingSignature: "SNAPSHOT_SIGNATURE_SECRET" },
  { type: "toolCall", id: "call_old", name: "bash", arguments: { command: "SNAPSHOT_TOOL_ARG_SECRET" } },
], { stopReason: "toolUse", responseId: "SNAPSHOT_RESPONSE_ID_SECRET" }));
session.appendMessage({ role: "toolResult", toolCallId: "call_old", toolName: "bash", content: [{ type: "text", text: "SNAPSHOT_TOOL_RESULT_SECRET" }], isError: false, timestamp: Date.now() });
session.appendMessage({ role: "bashExecution", command: "BANG_COMMAND_SECRET", output: "BANG_OUTPUT_SECRET", exitCode: 0, cancelled: false, truncated: false, timestamp: Date.now() });
session.appendEntry({ type: "custom_message", customType: "probe", content: "CUSTOM_MESSAGE_SECRET", display: true });
session.appendEntry({ type: "branch_summary", fromId: "00000001", summary: "BRANCH_SUMMARY_SECRET" });
session.appendEntry({ type: "compaction", summary: "COMPACTION_SECRET", firstKeptEntryId: "00000001", tokensBefore: 10 });
session.appendEntry({ type: "custom", customType: "probe", data: { secret: "CUSTOM_ENTRY_SECRET" } });
session.appendMessage(t.assistantMessage([], { stopReason: "error", errorMessage: "PROVIDER_ERROR_SECRET" }));
session.appendMessage(t.assistantMessage([{ type: "text", text: "visible answer" }]));

const bridge = await t.loadBridge();
const ctx = t.contextFor(session);
await bridge.emit("session_start", { reason: "startup" }, ctx);
await t.waitFor(() => t.readCurrent(home).state === "live", "activation");
await bridge.emit("agent_start", {}, ctx);
for (const [, text] of operational) await t.userTurn(bridge, session, ctx, text);
await t.userTurn(bridge, session, ctx, [{ type: "text", text: "live picture" }, { type: "image", data: "LIVE_IMAGE_SECRET", mimeType: "image/png" }]);
await t.assistantTurn(bridge, session, ctx, [
  { type: "thinking", thinking: "LIVE_THINKING_SECRET" },
  { type: "toolCall", id: "call_live", name: "bash", arguments: { command: "LIVE_TOOL_ARG_SECRET" } },
], { extra: { stopReason: "toolUse" } });
await t.toolRun(bridge, session, ctx, { id: "call_live", name: "bash", args: { command: "LIVE_TOOL_ARG_SECRET" }, result: toolResult("LIVE_TOOL") });
for (const message of [
  { role: "custom", customType: "probe", content: "LIVE_CUSTOM_SECRET", display: true, details: { d: "LIVE_CUSTOM_DETAILS_SECRET" }, timestamp: Date.now() },
  { role: "bashExecution", command: "LIVE_BANG_SECRET", output: "LIVE_BANG_OUTPUT_SECRET", exitCode: 0, cancelled: false, truncated: false, timestamp: Date.now() },
]) {
  await bridge.emit("message_start", { message }, ctx);
  await bridge.emit("message_end", { message }, ctx);
}
await t.assistantTurn(bridge, session, ctx, [], { extra: { stopReason: "error", errorMessage: "LIVE_PROVIDER_ERROR_SECRET" } });
await bridge.emit("agent_settled", { aborted: false }, ctx);
const current = await t.waitFor(() => {
  const value = t.readCurrent(home);
  const records = t.readJournal(home, value.gen);
  return records[records.length - 1].type === "run" && records[records.length - 1].state === "settled" ? value : null;
}, "the privacy run to settle");

const bytes = t.allBytes(home);
const leaked = bytes.match(/[A-Z_]+_SECRET/g);
t.assert(!leaked, `private content reached the journal: ${[...new Set(leaked ?? [])].join(", ")}`);
const records = t.readJournal(home, current.gen);
const snapshot = records[0];
const users = snapshot.items.filter((item) => item.role !== "assistant");
t.assert(JSON.stringify(users.map((item) => [item.role, item.opKind ?? null, item.text ?? null])) === JSON.stringify([
  ["operational", "watcher", null],
  ["operational", "launch-brief", null],
  ["operational", "from-firstmate", null],
  ["operational", "watcher", null],
  ["captain", null, "captain shares a picture\n[image]"],
]), `snapshot user items were ${JSON.stringify(users)}`);
const assistants = snapshot.items.filter((item) => item.role === "assistant");
t.assert(JSON.stringify(assistants.map((item) => [item.stopReason, item.text ?? null])) === JSON.stringify([["error", ""], ["stop", "visible answer"]]), `snapshot assistant items were ${JSON.stringify(assistants)}`);
const liveUsers = records.filter((r) => r.type === "message" && r.phase === "end" && r.role !== "assistant");
t.assert(JSON.stringify(liveUsers.map((r) => [r.role, r.opKind ?? null, r.text ?? null])) === JSON.stringify([
  ["operational", "watcher", null],
  ["operational", "launch-brief", null],
  ["operational", "from-firstmate", null],
  ["operational", "watcher", null],
  ["captain", null, "live picture\n[image]"],
]), `live user records were ${JSON.stringify(liveUsers)}`);
for (const record of records.filter((r) => r.type === "tool")) {
  const extra = Object.keys(record).filter((key) => !["seq", "gen", "at", "type", "phase", "tool", "name", "isError", "durationMs"].includes(key));
  t.assert(extra.length === 0, `tool record carried ${extra.join(", ")}`);
}
t.assert(!records.some((r) => r.role === "custom" || r.role === "bashExecution" || r.role === "toolResult"), "a non-dialog message was journalled");
t.assert(current.conversation === "2026-10-31_conv-p.jsonl", "the session file was not reduced to its base name");
t.assertClean(bridge, "privacy");
console.log("ok");
JS
  ) || fail "privacy: $out"
  [ "$out" = ok ] || fail "privacy printed unexpected output: $out"
  pass "Pi console journal: thinking, tool arguments and results, images, system/custom/shell messages, provider errors, and operational bodies never reach disk"
}

test_classifier_failure_withholds_user_text() {
  local home="$TMP_ROOT/classifier-failure" broken="$TMP_ROOT/broken-classifier.sh" out
  mkdir -p "$home"
  printf '#!/usr/bin/env bash\nexit 2\n' >"$broken"
  chmod +x "$broken"
  out=$(run_node "$home" FM_OPERATIONAL_INPUT_SCRIPT="$broken" 2>&1 <<'JS'
const t = await import(process.env.DRIVER_URL);
const home = process.env.FM_HOME;
t.prepareHome(home);
const session = t.createSession({ file: "/sessions/conv-c.jsonl", id: "conv-c" });
session.appendMessage(t.userMessage("\u2063FIRSTMATE_OP: v1 watcher: SNAPSHOT_WITHHELD_SECRET"));
const bridge = await t.loadBridge();
const ctx = t.contextFor(session);
await bridge.emit("session_start", { reason: "startup" }, ctx);
await t.waitFor(() => t.readCurrent(home).state === "live", "activation");
await bridge.emit("agent_start", {}, ctx);
await t.userTurn(bridge, session, ctx, "\u2063FIRSTMATE_OP: v1 watcher: LIVE_WITHHELD_SECRET");
await bridge.emit("agent_settled", { aborted: false }, ctx);
const current = await t.waitFor(() => {
  const value = t.readCurrent(home);
  const records = t.readJournal(home, value.gen);
  return records[records.length - 1].type === "run" && records[records.length - 1].state === "settled" ? value : null;
}, "the run to settle");
const records = t.readJournal(home, current.gen);
t.assert(!t.allBytes(home).includes("WITHHELD_SECRET"), "user text was published although it could not be classified");
t.assert(records[0].items[0].role === "withheld" && !("text" in records[0].items[0]), `snapshot item was ${JSON.stringify(records[0].items[0])}`);
const end = records.find((r) => r.type === "message" && r.phase === "end");
t.assert(end.role === "withheld" && !("text" in end), `live record was ${JSON.stringify(end)}`);
t.assertClean(bridge, "classifier failure");
console.log("ok");
JS
  ) || fail "classifier failure: $out"
  [ "$out" = ok ] || fail "classifier failure printed unexpected output: $out"
  pass "Pi console journal: user text is withheld, not published, when the operational classifier cannot answer"
}

test_snapshot_and_records_stay_within_bounds() {
  local home="$TMP_ROOT/bounds" out
  mkdir -p "$home"
  out=$(run_node "$home" 2>&1 <<'JS'
const t = await import(process.env.DRIVER_URL);
const home = process.env.FM_HOME;
t.prepareHome(home);
// Text that JSON escaping inflates: quotes, backslashes, control characters,
// and multi-byte code points, so byte budgets must count the escaped form.
const heavy = (seed, size) => {
  const unit = `${seed}"\\\u0001\u0007\t\u00e9\u4e2d\ud83d\ude80`;
  return unit.repeat(Math.ceil(size / unit.length)).slice(0, size);
};
const session = t.createSession({ file: "/sessions/conv-b.jsonl", id: "conv-b" });
const originals = [];
for (let index = 0; index < 30; index += 1) {
  const captain = `C${String(index).padStart(2, "0")}:${heavy("c", 100000)}`;
  const answer = `A${String(index).padStart(2, "0")}:${heavy("a", 100000)}`;
  originals.push(captain, answer);
  session.appendMessage(t.userMessage(captain));
  session.appendMessage(t.assistantMessage([{ type: "text", text: answer }]));
}
const bridge = await t.loadBridge();
const ctx = t.contextFor(session);
await bridge.emit("session_start", { reason: "startup" }, ctx);
const current = await t.waitFor(() => t.readCurrent(home), "the snapshot");
const snapshot = t.readJournal(home, current.gen)[0];
t.assert(snapshot.items.length === 50 && snapshot.omittedBefore === 10, `snapshot kept ${snapshot.items.length} items, omitted ${snapshot.omittedBefore}`);
const kept = originals.slice(10);
snapshot.items.forEach((item, index) => {
  const text = item.text ?? "";
  t.assert(kept[index].startsWith(text), `snapshot item ${index} is not a prefix of its message`);
  t.assert(item.truncated === true, `snapshot item ${index} hid its truncation`);
});
const newest = snapshot.items[snapshot.items.length - 1].text ?? "";
t.assert(newest.length > 0 && JSON.stringify(newest).length - 2 <= 4096 * 2, "the newest snapshot item lost its text budget");
t.assert(snapshot.items[0].text === undefined || snapshot.items[0].text === "", "the oldest item kept text past the total budget");
t.assert(snapshot.truncatedItems === 50, `truncatedItems was ${snapshot.truncatedItems}`);

await bridge.emit("agent_start", {}, ctx);
const longCaptain = heavy("L", 200000);
await t.userTurn(bridge, session, ctx, longCaptain);
const longAnswer = heavy("R", 300000);
await t.assistantTurn(bridge, session, ctx, [{ type: "text", text: longAnswer }], { chunk: 300000 });
const escapes = "\u0001".repeat(120000);
await t.assistantTurn(bridge, session, ctx, [{ type: "text", text: escapes }], { chunk: 7000 });
await bridge.emit("agent_settled", { aborted: false }, ctx);
const records = await t.waitFor(() => {
  const all = t.readJournal(home, current.gen);
  return all[all.length - 1].type === "run" && all[all.length - 1].state === "settled" ? all : null;
}, "the long run to settle");
const ends = records.filter((r) => r.type === "message" && r.phase === "end");
t.assert(longCaptain.startsWith(ends[0].text) && ends[0].truncated === true && ends[0].text.length > 1000, "long captain text was not a truncated prefix");
t.assert(longAnswer.startsWith(ends[1].text) && ends[1].truncated === true, "long assistant end was not a truncated prefix");
t.assert(Buffer.byteLength(JSON.stringify(ends[1].text)) - 2 <= 32768, "assistant end text exceeded its escaped budget");
const streamed = (msg) => records.filter((r) => r.type === "delta" && r.msg === msg).map((r) => r.text).join("");
t.assert(longAnswer.startsWith(streamed(ends[1].msg)) && streamed(ends[1].msg).length >= ends[1].text.length, "streamed text was not the same bounded prefix");
t.assert(records.filter((r) => r.type === "delta" && r.msg === ends[1].msg).length >= 2, "a large delta was not split");
t.assert(escapes.startsWith(ends[2].text) && ends[2].truncated === true && ends[2].text.length > 0, "escape-heavy end lost its prefix");
t.assertClean(bridge, "bounds");
console.log("ok");
JS
  ) || fail "bounds: $out"
  [ "$out" = ok ] || fail "bounds printed unexpected output: $out"
  pass "Pi console journal: snapshots keep the newest 50 messages within one 64 KiB record and every message, delta, and escape-heavy text stays a marked prefix"
}

test_generations_replace_without_stale_writes_or_overpruning() {
  local home="$TMP_ROOT/generations" out
  mkdir -p "$home"
  out=$(run_node "$home" 2>&1 <<'JS'
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
const t = await import(process.env.DRIVER_URL);
const home = process.env.FM_HOME;
t.prepareHome(home);
const sessionX = t.createSession({ file: "/sessions/conv-x.jsonl", id: "conv-x" });
sessionX.appendMessage(t.userMessage("X_FIRST"));
const ctxX = t.contextFor(sessionX);

const runtimeA = await t.loadBridge();
await runtimeA.emit("session_start", { reason: "startup" }, ctxX);
const a1 = (await t.waitFor(() => t.readCurrent(home), "runtime A")).gen;
await runtimeA.emit("agent_start", {}, ctxX);
await runtimeA.emit("message_start", { message: t.assistantMessage([], { stopReason: "pending" }) }, ctxX);
await runtimeA.emit("message_update", { message: t.assistantMessage([{ type: "text", text: "PENDING" }], { stopReason: "pending" }), assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "PENDING", partial: {} } }, ctxX);
await runtimeA.emit("session_shutdown", { reason: "reload" }, ctxX);
const stoppedA = await t.waitFor(() => {
  const current = t.readCurrent(home);
  return current.gen === a1 && current.state === "stopped" ? current : null;
}, "runtime A to stop");
t.assert(stoppedA.stoppedReason === "reload", `stop reason was ${stoppedA.stoppedReason}`);
const a1Records = t.readJournal(home, a1);
t.assert(a1Records[a1Records.length - 1].type === "stopped" && a1Records[a1Records.length - 1].reason === "reload", "runtime A did not end its journal with a stop record");

const runtimeB = await t.loadBridge();
await runtimeB.emit("session_start", { reason: "reload" }, ctxX);
const b1 = await t.waitFor(() => {
  const current = t.readCurrent(home);
  return current.gen !== a1 && current.state === "live" ? current : null;
}, "runtime B after reload");
t.assert(b1.startedReason === "reload" && b1.previousGen === a1 && b1.conversation === "conv-x.jsonl", `reload record was ${JSON.stringify(b1)}`);

// Runtime A's handlers stay registered in tests, as stale callbacks can in Pi.
await runtimeA.emit("agent_start", {}, ctxX);
await runtimeA.emit("message_update", { message: t.assistantMessage([], { stopReason: "pending" }), assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "STALE_AFTER", partial: {} } }, ctxX);
await runtimeA.emit("message_end", { message: t.assistantMessage([{ type: "text", text: "STALE_END" }]) }, ctxX);
await runtimeA.emit("session_tree", { newLeafId: null, oldLeafId: sessionX.manager.getLeafId() }, ctxX);
await runtimeA.emit("agent_settled", { aborted: false }, ctxX);
await t.sleep(400);
t.assert(!t.allBytes(home).includes("STALE_"), "a stale runtime wrote after its replacement started");
t.assert(t.readJournal(home, a1).length === a1Records.length, "the stopped journal grew");
const afterStale = t.readCurrent(home);
t.assert(afterStale.gen === b1.gen && afterStale.state === "live", "a stale runtime rewrote current.json");

// Foreign files beside the journals are never the bridge's to remove.
const foreign = ["notes.txt", `${"a".repeat(32)}.jsonl`, `${a1}.jsonl.bak`];
for (const name of foreign) writeFileSync(`${t.journalDir(home)}/${name}`, "foreign\n");
mkdirSync(`${t.journalDir(home)}/requests`);

const sessionY = t.createSession({ file: "/sessions/conv-y.jsonl", id: "conv-y" });
const e1 = sessionY.appendMessage(t.userMessage("Y_ONE"));
const e2 = sessionY.appendMessage(t.assistantMessage([{ type: "text", text: "Y_TWO" }]));
const e3 = sessionY.appendMessage(t.userMessage("Y_THREE"));
const e4 = sessionY.appendMessage(t.assistantMessage([{ type: "text", text: "Y_FOUR" }]));
const ctxY = t.contextFor(sessionY);
await runtimeB.emit("session_shutdown", { reason: "new" }, ctxX);
await runtimeB.emit("session_start", { reason: "new", previousSessionFile: "/sessions/conv-x.jsonl" }, ctxY);
const b2 = await t.waitFor(() => {
  const current = t.readCurrent(home);
  return current.conversation === "conv-y.jsonl" && current.state === "live" ? current : null;
}, "the new conversation");
t.assert(b2.startedReason === "new" && b2.previousGen === b1.gen, `new-session record was ${JSON.stringify(b2)}`);
t.assert(!existsSync(`${t.journalDir(home)}/${a1}.jsonl`), "the generation before the previous one was kept");
t.assert(existsSync(`${t.journalDir(home)}/${b1.gen}.jsonl`), "the previous generation was removed");

// Leaving the journalled branch through /tree opens a new generation.
sessionY.moveTo(e2.id);
await runtimeB.emit("session_tree", { newLeafId: e2.id, oldLeafId: e4.id }, ctxY);
const b3 = await t.waitFor(() => {
  const current = t.readCurrent(home);
  return current.gen !== b2.gen && current.state === "live" ? current : null;
}, "the tree move generation");
t.assert(b3.startedReason === "tree", `tree move reason was ${b3.startedReason}`);
t.assert(JSON.stringify(t.readJournal(home, b3.gen)[0].items.map((item) => item.text)) === JSON.stringify(["Y_ONE", "Y_TWO"]), "the tree snapshot did not follow the new branch");
// Returning to a later entry adds history the generation never streamed.
sessionY.moveTo(e4.id);
await runtimeB.emit("session_tree", { newLeafId: e4.id, oldLeafId: e2.id }, ctxY);
const b4 = await t.waitFor(() => {
  const current = t.readCurrent(home);
  return current.gen !== b3.gen && current.state === "live" ? current : null;
}, "the forward tree move generation");
t.assert(JSON.stringify(t.readJournal(home, b4.gen)[0].items.map((item) => item.text)) === JSON.stringify(["Y_ONE", "Y_TWO", "Y_THREE", "Y_FOUR"]), "the forward snapshot was incomplete");
// A non-dialog entry moving the leaf is not a branch change.
sessionY.appendEntry({ type: "custom", customType: "probe", data: {} });
await runtimeB.emit("agent_start", {}, ctxY);
await runtimeB.emit("agent_settled", { aborted: false }, ctxY);
await t.sleep(300);
t.assert(t.readCurrent(home).gen === b4.gen, "a custom entry opened a new generation");
for (const name of foreign) t.assert(existsSync(`${t.journalDir(home)}/${name}`), `foreign file ${name} was removed`);
t.assert(existsSync(`${t.journalDir(home)}/requests`), "a foreign directory was removed");
const journals = t.journalNames(home).filter((name) => /^[0-9a-f]{32}\.jsonl$/.test(name) && name !== `${"a".repeat(32)}.jsonl`);
t.assert(JSON.stringify(journals) === JSON.stringify([`${b3.gen}.jsonl`, `${b4.gen}.jsonl`].sort()), `kept journals were ${journals}`);
t.assertClean(runtimeA, "runtime A");
t.assertClean(runtimeB, "runtime B");
console.log("ok");
JS
  ) || fail "generations: $out"
  [ "$out" = ok ] || fail "generations printed unexpected output: $out"
  pass "Pi console journal: reload, new session, and tree moves open new generations, stale runtimes never write, and retention removes only its own older journals"
}

test_backpressure_loses_honestly_and_size_cap_rotates() {
  local home="$TMP_ROOT/backpressure" out
  mkdir -p "$home"
  out=$(run_node "$home" 2>&1 <<'JS'
import { statSync } from "node:fs";
const t = await import(process.env.DRIVER_URL);
const home = process.env.FM_HOME;
t.prepareHome(home);
const session = t.createSession({ file: "/sessions/conv-q.jsonl", id: "conv-q" });
const bridge = await t.loadBridge();
let busy = false;
const ctx = t.contextFor(session, () => !busy);
await bridge.emit("session_start", { reason: "startup" }, ctx);
const g1 = (await t.waitFor(() => t.readCurrent(home), "the first generation")).gen;
busy = true;
await bridge.emit("agent_start", {}, ctx);

// A burst the writer cannot touch: no await, so the event loop never runs it.
const block = "x".repeat(32 * 1024);
for (let index = 0; index < 48; index += 1) {
  bridge.emitSync("message_start", { message: t.assistantMessage([], { stopReason: "pending" }) }, ctx);
  bridge.emitSync("message_update", { message: t.assistantMessage([], { stopReason: "pending" }), assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: block, partial: {} } }, ctx);
  const final = t.assistantMessage([{ type: "text", text: `BURST_${index}_${block}` }]);
  bridge.emitSync("message_end", { message: final }, ctx);
  session.appendMessage(final);
}
t.assert(bridge.maxSyncMs < 250, `a handler blocked for ${bridge.maxSyncMs.toFixed(1)} ms`);
busy = false;
await bridge.emit("agent_settled", { aborted: false }, ctx);
const resync = await t.waitFor(() => {
  const current = t.readCurrent(home);
  return current.gen !== g1 && current.state === "live" ? current : null;
}, "a resynchronised generation");
t.assert(resync.startedReason === "resync" && resync.previousGen === g1, `resync record was ${JSON.stringify(resync)}`);
const lost = t.readJournal(home, g1);
const gap = lost[lost.length - 1];
t.assert(gap.type === "gap" && gap.reason === "backpressure" && gap.droppedRecords > 0, `lost generation ended with ${JSON.stringify(gap)}`);
t.assert(statSync(`${t.journalDir(home)}/${g1}.jsonl`).size < 1200 * 1024, "the lost generation wrote more than its queue bound");
const snapshot = t.readJournal(home, resync.gen)[0];
t.assert(snapshot.type === "snapshot" && snapshot.items.length === 48 && snapshot.items[47].text.startsWith("BURST_47_"), "the resync snapshot did not recover the finished messages");

// Steady streaming the writer keeps up with rotates at the size cap.
busy = true;
await bridge.emit("agent_start", {}, ctx);
let rotated = null;
for (let index = 0; index < 150 && !rotated; index += 1) {
  await bridge.emit("message_start", { message: t.assistantMessage([], { stopReason: "pending" }) }, ctx);
  await bridge.emit("message_update", { message: t.assistantMessage([], { stopReason: "pending" }), assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: block, partial: {} } }, ctx);
  const final = t.assistantMessage([{ type: "text", text: `CAP_${index}_${block}` }]);
  await bridge.emit("message_end", { message: final }, ctx);
  session.appendMessage(final);
  await t.waitFor(() => {
    const current = t.readCurrent(home);
    if (current.gen !== resync.gen) {
      rotated = current;
      return true;
    }
    const records = t.readJournal(home, current.gen);
    return records[records.length - 1].type === "message" && records[records.length - 1].phase === "end";
  }, `message ${index} to be written`);
}
t.assert(rotated && rotated.startedReason === "rotate" && rotated.previousGen === resync.gen, `no size-cap rotation: ${JSON.stringify(rotated)}`);
t.assert(statSync(`${t.journalDir(home)}/${resync.gen}.jsonl`).size <= 8 * 1024 * 1024, "a generation outgrew 8 MiB");
const opened = await t.waitFor(() => {
  const records = t.readJournal(home, rotated.gen);
  return records.length >= 2 ? records : null;
}, "the rotated generation's first records");
t.assert(opened[0].type === "snapshot" && opened[0].busy === true, "the rotated generation did not open with a busy snapshot");
busy = false;
await bridge.emit("agent_settled", { aborted: false }, ctx);
const journals = t.journalNames(home).filter((name) => name.endsWith(".jsonl"));
t.assert(JSON.stringify(journals) === JSON.stringify([`${resync.gen}.jsonl`, `${rotated.gen}.jsonl`].sort()), `kept journals were ${journals}`);
t.assertClean(bridge, "backpressure");
console.log("ok");
JS
  ) || fail "backpressure: $out"
  [ "$out" = ok ] || fail "backpressure printed unexpected output: $out"
  pass "Pi console journal: a writer that cannot keep up loses records with a gap and resynchronises, and steady streaming rotates at 8 MiB keeping two journals"
}

test_io_failures_never_throw_and_recover_at_settle() {
  local home="$TMP_ROOT/io-failure" out
  mkdir -p "$home"
  out=$(run_node "$home" 2>&1 <<'JS'
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
const t = await import(process.env.DRIVER_URL);
const home = process.env.FM_HOME;
t.prepareHome(home);
const dir = t.journalDir(home);
mkdirSync(`${home}/state/extensions`, { recursive: true });
writeFileSync(dir, "occupied\n");
const session = t.createSession({ file: "/sessions/conv-f.jsonl", id: "conv-f" });
session.appendMessage(t.userMessage("F_ONE"));
const bridge = await t.loadBridge();
const ctx = t.contextFor(session);
await bridge.emit("session_start", { reason: "startup" }, ctx);
await bridge.emit("agent_start", {}, ctx);
await t.userTurn(bridge, session, ctx, "F_TWO");
await t.assistantTurn(bridge, session, ctx, [{ type: "text", text: "F_THREE" }]);
await bridge.emit("agent_settled", { aborted: false }, ctx);
await t.sleep(300);
t.assert(readFileSync(dir, "utf8") === "occupied\n", "a blocked journal path was overwritten");

// Recovery is attempted at the next settled run once the path is usable.
rmSync(dir);
await bridge.emit("agent_start", {}, ctx);
await bridge.emit("agent_settled", { aborted: false }, ctx);
const g1 = await t.waitFor(() => {
  const current = t.readCurrent(home);
  return current.state === "live" ? current : null;
}, "recovery after the path cleared");
t.assert(g1.startedReason === "recover", `first publication reason was ${g1.startedReason}`);

// The directory disappears under a live generation: the next generation
// cannot open, nothing throws, and the following settle recovers.
renameSync(dir, `${dir}.moved`);
writeFileSync(dir, "occupied again\n");
const leaf = session.manager.getLeafId();
const first = session.manager.getBranch()[0].id;
session.moveTo(first);
await bridge.emit("session_tree", { newLeafId: first, oldLeafId: leaf }, ctx);
await bridge.emit("agent_start", {}, ctx);
await t.userTurn(bridge, session, ctx, "F_AFTER_FAILURE");
await bridge.emit("agent_settled", { aborted: false }, ctx);
await t.sleep(300);
t.assert(readFileSync(dir, "utf8") === "occupied again\n", "the failed generation overwrote the blocking file");
rmSync(dir);
await bridge.emit("agent_start", {}, ctx);
await bridge.emit("agent_settled", { aborted: false }, ctx);
const g2 = await t.waitFor(() => {
  const current = existsSync(`${dir}/current.json`) ? t.readCurrent(home) : null;
  return current && current.state === "live" ? current : null;
}, "recovery after the directory returned");
t.assert(g2.startedReason === "recover" && g2.gen !== g1.gen, `second recovery record was ${JSON.stringify(g2)}`);
t.assert(JSON.stringify(t.readJournal(home, g2.gen)[0].items.map((item) => item.text)) === JSON.stringify(["F_ONE", "F_AFTER_FAILURE"]), "the recovery snapshot did not show the current branch");
t.assert(bridge.maxSyncMs < 250, `a handler blocked for ${bridge.maxSyncMs.toFixed(1)} ms`);
t.assertClean(bridge, "io failure");
console.log("ok");
JS
  ) || fail "io failure: $out"
  [ "$out" = ok ] || fail "io failure printed unexpected output: $out"
  pass "Pi console journal: an unusable journal path never throws into Pi or overwrites what occupies it, and the next settled run recovers"
}

test_sessions_that_do_not_own_the_lock_write_nothing
test_lock_owner_publishes_snapshot_then_ordered_live_events
test_partial_text_reaches_disk_before_the_message_ends
test_private_content_never_reaches_disk
test_classifier_failure_withholds_user_text
test_snapshot_and_records_stay_within_bounds
test_generations_replace_without_stale_writes_or_overpruning
test_backpressure_loses_honestly_and_size_cap_rotates
test_io_failures_never_throw_and_recover_at_settle
