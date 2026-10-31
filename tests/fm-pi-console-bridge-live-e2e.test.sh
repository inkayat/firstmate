#!/usr/bin/env bash
# Default-on live guard for the read-only Pi console journal
# (.pi/extensions/fm-console-bridge.ts) against the installed Pi: the payload
# shapes it reads (message_update text deltas, message_end, tool execution,
# agent_start/agent_settled, session_start/shutdown reasons) are vendor-emitted,
# so only a running Pi can prove them. docs/pi-console-journal.md owns the
# contract.
#
# No model turn reaches any provider: a local faux provider answers every
# request. The interactive Pi runs on a private tmux server, socketed under
# the case's temp root and started with no configuration file, under a
# scrubbed environment with scratch HOME, XDG
# directories, Pi agent directory, session directory, project, and FM_HOME, so
# no personal settings, credentials, sessions, or rc files are read. The
# probe writes this Pi engine's own pid as the session lock during the first
# nested round, as bin/fm-lock.sh records it, making this Pi the lock-owning
# primary of the scratch home; it publishes on its next session start.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_PI_CONSOLE_BRIDGE_LIVE pi tmux node

PI_BIN=$(command -v pi)
PI_VERSION=$("$PI_BIN" --version 2>/dev/null || printf 'unknown')
TMP_ROOT=$(fm_test_tmproot fm-pi-console-bridge-live)
SOCKET="fm-console-journal-$$"
SESSION=console-journal
PROJECT="$TMP_ROOT/project"
FMHOME="$TMP_ROOT/fmhome"
JOURNAL_DIR="$FMHOME/state/extensions/pi-console-bridge"
CHECK="$TMP_ROOT/check.mjs"
NESTED_DIR="$TMP_ROOT/nested"
export NODE_NO_WARNINGS=1
# The private tmux server's socket lives under this case's own temp root, so
# removing the root removes it too.
export TMUX_TMPDIR="$TMP_ROOT/tmux"

mkdir -p "$PROJECT/.pi/extensions/lib" "$PROJECT/bin" "$FMHOME/state" "$TMP_ROOT/agent" \
  "$TMP_ROOT/sessions" "$TMP_ROOT/home" "$TMP_ROOT/xdg/config" "$TMP_ROOT/xdg/data" \
  "$TMP_ROOT/xdg/state" "$TMP_ROOT/xdg/cache" "$TMUX_TMPDIR/tmux-$(id -u)" "$NESTED_DIR"
chmod 700 "$TMUX_TMPDIR/tmux-$(id -u)"

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

pane() {
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION" -S -200 2>/dev/null || true
}

live_fail() {
  fail "Pi $PI_VERSION: $1"$'\n'"--- pane ---"$'\n'"$(pane)"
}

fm_git_init_commit "$PROJECT"
cp "$ROOT/.pi/extensions/fm-console-bridge.ts" "$PROJECT/.pi/extensions/"
cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$PROJECT/.pi/extensions/lib/"
cp "$ROOT/bin/fm-operational-input.sh" "$ROOT/bin/fm-session-lock-lib.sh" "$ROOT/bin/fm-cursor-lib.sh" "$PROJECT/bin/"
chmod +x "$PROJECT/bin/fm-operational-input.sh"

cat >"$PROJECT/journal-probe.ts" <<'TS'
import { execFileSync, spawn } from "node:child_process";
import { existsSync, writeFileSync } from "node:fs";
import { createFauxCore, fauxAssistantMessage, fauxText, fauxThinking, fauxToolCall } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { encodeFirstmateOperationalInput } from "./.pi/extensions/lib/fm-operational-input.ts";

// A nested Pi records that its session started and its own ancestry, so the
// guard can prove it ran with the journal extension loaded.
function recordNestedStart(mark: string): void {
  const chain: string[] = [];
  let pid = String(process.pid);
  for (let i = 0; i < 4 && pid && pid !== "1"; i += 1) {
    chain.push(execFileSync("ps", ["-o", "pid=,ppid=,comm=", "-p", pid], { encoding: "utf8" }).trim().replace(/\s+/g, " "));
    pid = execFileSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" }).trim();
  }
  writeFileSync(mark, `${JSON.stringify({ pid: process.pid, chain })}\n`);
}

// Run one Pi from a shell inside this one, loading the journal extension
// against the same home, for as long as its stdin stays open.
async function runNestedPi(step: string): Promise<void> {
  const dir = process.env.NESTED_DIR as string;
  const child = spawn("bash", ["-c", "sleep 3 | pi --mode rpc --offline --approve --no-context-files --no-skills --no-prompt-templates --no-themes --no-extensions -e ./.pi/extensions/fm-console-bridge.ts -e ./journal-probe.ts --no-session >/dev/null 2>&1"], {
    cwd: process.cwd(),
    env: { ...process.env, NESTED_MARK: `${dir}/mark-${step}.json` },
    stdio: "ignore",
    detached: true,
  });
  const timer = setTimeout(() => {
    if (child.pid) process.kill(-child.pid, "SIGTERM");
  }, 15000);
  const code = await new Promise<number | null>((resolve) => child.on("close", resolve));
  clearTimeout(timer);
  writeFileSync(`${dir}/result-${step}`, `${code}\n`);
}

export default function (pi: ExtensionAPI): void {
  pi.on("session_start", () => {
    if (process.env.NESTED_MARK) recordNestedStart(process.env.NESTED_MARK);
  });

  const faux = createFauxCore({
    api: "console-journal-e2e-api",
    provider: "console-journal-e2e",
    models: [{
      id: "deterministic",
      name: "Console journal live guard",
      reasoning: true,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 8192,
      maxTokens: 256,
    }],
    tokenSize: { min: 3, max: 3 },
  });
  pi.registerProvider("console-journal-e2e", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: faux.api,
    models: faux.models,
    streamSimple: faux.streamSimple,
  });
  pi.registerTool({
    name: "journal_probe",
    label: "journal_probe",
    description: "Return a fixed result.",
    parameters: Type.Object({ secret: Type.String() }),
    async execute() {
      return { content: [{ type: "text", text: "TOOL_RESULT_SECRET" }], details: {} };
    },
  });
  pi.registerCommand("journal-e2e", {
    description: "Drive one deterministic console journal run.",
    handler: async (args, ctx) => {
      const [step, round = ""] = args.trim().split(/\s+/);
      if (step === "nested") {
        // The lock names this Pi engine, as bin/fm-lock.sh records the
        // innermost Pi harness of the session that ran fm-session-start.
        const lock = `${process.env.FM_HOME}/state/.lock`;
        if (!existsSync(lock)) writeFileSync(lock, `${process.pid}\n`);
        await runNestedPi(round);
        return;
      }
      const model = ctx.modelRegistry.find("console-journal-e2e", "deterministic");
      if (!model || !(await pi.setModel(model))) throw new Error("console journal model unavailable");
      if (step === "first") {
        faux.setResponses([
          fauxAssistantMessage([
            fauxThinking("THINKING_SECRET"),
            fauxText("JOURNAL_ALPHA arrives in several streamed pieces"),
            fauxToolCall("journal_probe", { secret: "TOOL_ARG_SECRET" }, { id: "journal_probe_1" }),
          ], { stopReason: "toolUse" }),
          fauxAssistantMessage([fauxText("JOURNAL_DONE")]),
        ]);
        pi.sendUserMessage("CAPTAIN_PROMPT_ONE");
      } else if (step === "operational") {
        faux.setResponses([fauxAssistantMessage([fauxText("OPERATIONAL_REPLY")])]);
        pi.sendUserMessage(encodeFirstmateOperationalInput("watcher", "OPERATIONAL_BODY_SECRET"));
      } else if (step === "second") {
        faux.setResponses([fauxAssistantMessage([fauxText("AFTER_RELOAD_REPLY")])]);
        pi.sendUserMessage("CAPTAIN_PROMPT_TWO");
      }
    },
  });
}
TS

# One checkpoint per invocation: exit 0 when the named phase holds, 2 while it
# has not arrived yet, and 1 with a message when it arrived wrong.
cat >"$CHECK" <<'JS'
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
const [dir, phase, previousGen] = process.argv.slice(2);
const notYet = () => process.exit(2);
const wrong = (message) => {
  console.error(message);
  process.exit(1);
};
const assert = (condition, message) => condition || wrong(message);
if (!existsSync(`${dir}/current.json`)) notYet();
const current = JSON.parse(readFileSync(`${dir}/current.json`, "utf8"));
const journal = (gen) => {
  const bytes = readFileSync(`${dir}/${gen}.jsonl`);
  const records = [];
  let start = 0;
  while (start < bytes.length) {
    const end = bytes.indexOf(0x0a, start);
    if (end < 0) notYet();
    assert(end + 1 - start <= 65536, `record over 64 KiB in ${gen}`);
    records.push(JSON.parse(bytes.subarray(start, end).toString("utf8")));
    start = end + 1;
  }
  records.forEach((record, index) => assert(record.seq === index + 1 && record.gen === gen, `seq/gen broke at ${index + 1} in ${gen}`));
  return records;
};
const everything = () => readdirSync(dir).map((name) => readFileSync(`${dir}/${name}`, "latin1")).join("\n");
const settledRuns = (records) => records.filter((r) => r.type === "run" && r.state === "settled").length;
const leaked = () => everything().match(/[A-Z_]+_SECRET/g);

if (phase === "published") {
  if (current.state !== "live") notYet();
  assert(current.schema === "fm-console-journal.v1" && current.capabilities?.submit === false && current.capabilities?.journal === true, `wrong contract header ${JSON.stringify(current)}`);
  // The lock appeared after this session started, so the first publication is
  // the runtime the reload created.
  assert(current.startedReason === "reload" && current.previousGen === null, `first publication ${JSON.stringify(current)}`);
  assert(typeof current.conversation === "string" && current.conversation.endsWith(".jsonl") && !current.conversation.includes("/"), "conversation is not a base name");
  assert(current.lockPid === String(current.piPid), `the journal's writer ${current.piPid} is not the lock holder ${current.lockPid}`);
  const records = journal(current.gen);
  assert(records[0].type === "snapshot" && records[0].busy === false && records[0].items.length === 0, "a new session did not open with an empty idle snapshot");
  assert((statSync(dir).mode & 0o777) === 0o700, "journal directory is not 0700");
  for (const name of readdirSync(dir)) assert((statSync(`${dir}/${name}`).mode & 0o777) === 0o600, `${name} is not 0600`);
  console.log(`${current.gen} ${current.conversation} ${current.sessionId}`);
  process.exit(0);
}

if (phase === "first") {
  const records = journal(current.gen);
  if (settledRuns(records) < 1) notYet();
  const live = records.slice(1);
  const shape = live.filter((r) => r.type !== "delta").map((r) =>
    r.type === "run" ? `run:${r.state}` : r.type === "tool" ? `tool:${r.phase}:${r.name}` : `message:${r.phase}:${r.role}`);
  const expected = ["run:started", "message:end:captain", "message:start:assistant", "message:end:assistant", "tool:start:journal_probe", "tool:end:journal_probe", "message:start:assistant", "message:end:assistant", "run:settled"];
  assert(JSON.stringify(shape) === JSON.stringify(expected), `first run shape ${JSON.stringify(shape)}`);
  const ends = live.filter((r) => r.type === "message" && r.phase === "end");
  assert(ends[0].text === "CAPTAIN_PROMPT_ONE", `captain text ${ends[0].text}`);
  assert(ends[1].text === "JOURNAL_ALPHA arrives in several streamed pieces" && ends[1].stopReason === "toolUse", `assistant end ${JSON.stringify(ends[1])}`);
  const streamed = live.filter((r) => r.type === "delta" && r.msg === ends[1].msg).map((r) => r.text).join("");
  assert(streamed === ends[1].text, `streamed text ${JSON.stringify(streamed)} differs from the authoritative end`);
  assert(ends[2].text === "JOURNAL_DONE", "final reply missing");
  const toolEnd = live.find((r) => r.type === "tool" && r.phase === "end");
  assert(toolEnd.isError === false && Number.isInteger(toolEnd.durationMs) && toolEnd.durationMs >= 0, `tool end ${JSON.stringify(toolEnd)}`);
  assert(!leaked(), `private content reached disk: ${leaked()}`);
  process.exit(0);
}

if (phase === "operational") {
  const records = journal(current.gen);
  if (settledRuns(records) < 2) notYet();
  const ends = records.filter((r) => r.type === "message" && r.phase === "end" && r.role !== "assistant");
  const last = ends[ends.length - 1];
  assert(last.role === "operational" && last.opKind === "watcher" && !("text" in last), `operational record ${JSON.stringify(last)}`);
  assert(!leaked(), `private content reached disk: ${leaked()}`);
  process.exit(0);
}

if (phase === "reload") {
  if (current.gen === previousGen || current.state !== "live") notYet();
  assert(current.startedReason === "reload" && current.previousGen === previousGen, `reload record ${JSON.stringify(current)}`);
  const old = journal(previousGen);
  const tail = old[old.length - 1];
  assert(tail.type === "stopped" && tail.reason === "reload", `replaced journal ended with ${JSON.stringify(tail)}`);
  const snapshot = journal(current.gen)[0];
  const view = snapshot.items.map((item) => item.role === "operational" ? `operational:${item.opKind}` : `${item.role}:${item.text}`);
  const expected = [
    "captain:CAPTAIN_PROMPT_ONE",
    "assistant:JOURNAL_ALPHA arrives in several streamed pieces",
    "assistant:JOURNAL_DONE",
    "operational:watcher",
    "assistant:OPERATIONAL_REPLY",
  ];
  assert(JSON.stringify(view) === JSON.stringify(expected), `post-reload snapshot ${JSON.stringify(view)}`);
  console.log(`${current.gen} ${current.conversation} ${current.sessionId}`);
  process.exit(0);
}

if (phase === "second") {
  const records = journal(current.gen);
  if (settledRuns(records) < 1) notYet();
  const ends = records.filter((r) => r.type === "message" && r.phase === "end");
  assert(ends.map((r) => r.text).join("|") === "CAPTAIN_PROMPT_TWO|AFTER_RELOAD_REPLY", `post-reload run ${JSON.stringify(ends)}`);
  process.exit(0);
}

if (phase === "quit") {
  if (current.state !== "stopped") notYet();
  assert(current.stoppedReason === "quit", `stop reason ${current.stoppedReason}`);
  const records = journal(current.gen);
  assert(records[records.length - 1].type === "stopped" && records[records.length - 1].reason === "quit", "journal did not end with the quit record");
  const files = readdirSync(dir).sort();
  assert(files.every((name) => name === "current.json" || /^[0-9a-f]{32}\.jsonl$/.test(name)), `unexpected files ${files}`);
  assert(!leaked(), `private content reached disk: ${leaked()}`);
  process.exit(0);
}
wrong(`unknown phase ${phase}`);
JS

wait_phase() {  # <phase> [previous-gen] -> prints the checkpoint's output
  local phase=$1 previous=${2:-} i=0 out status
  while [ "$i" -lt 300 ]; do
    out=$(node "$CHECK" "$JOURNAL_DIR" "$phase" "$previous" 2>&1)
    status=$?
    case "$status" in
      0) printf '%s\n' "$out"; return 0 ;;
      1) live_fail "phase $phase: $out" ;;
    esac
    i=$((i + 1))
    sleep 0.1
  done
  live_fail "phase $phase did not arrive within 30s"
}

type_line() {
  tmux -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
  sleep 0.3
  tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
}

# One Pi run from a shell inside the primary (see runNestedPi in the probe):
# waits for it to exit and proves it reached session_start with the journal
# extension loaded, so a quiet journal is evidence rather than a no-op.
nested_round() {  # <round>
  local round=$1 i=0
  type_line "/journal-e2e nested $round"
  until [ -s "$NESTED_DIR/result-$round" ]; do
    i=$((i + 1))
    [ "$i" -lt 300 ] || live_fail "nested Pi round $round did not finish"
    sleep 0.1
  done
  [ -s "$NESTED_DIR/mark-$round.json" ] || live_fail "nested Pi round $round never reached session_start"
}

PANE_CMD=$(printf 'env -i PATH=%q TERM=xterm-256color LANG=C.UTF-8 HOME=%q XDG_CONFIG_HOME=%q XDG_DATA_HOME=%q XDG_STATE_HOME=%q XDG_CACHE_HOME=%q PI_CODING_AGENT_DIR=%q FM_HOME=%q NESTED_DIR=%q PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0 bash --noprofile --norc -c %q' \
  "$PATH" "$TMP_ROOT/home" "$TMP_ROOT/xdg/config" "$TMP_ROOT/xdg/data" "$TMP_ROOT/xdg/state" "$TMP_ROOT/xdg/cache" \
  "$TMP_ROOT/agent" "$FMHOME" "$NESTED_DIR" \
  "$(printf '%q' "$PI_BIN") --approve --offline --no-context-files --no-skills --no-prompt-templates --no-themes --no-extensions -e ./.pi/extensions/fm-console-bridge.ts -e ./journal-probe.ts --session-dir $(printf '%q' "$TMP_ROOT/sessions"); printf '\nPI_EXIT=%s\n' \"\$?\"; sleep 30")

tmux -L "$SOCKET" -f /dev/null new-session -d -s "$SESSION" -x 160 -y 40 -c "$PROJECT" "$PANE_CMD" \
  || fail "Pi $PI_VERSION: could not start the private tmux server"

i=0
until pane | grep -Fq 'journal-probe.ts'; do
  i=$((i + 1))
  [ "$i" -lt 200 ] || live_fail "did not reach its composer"
  sleep 0.05
done
sleep 1
[ ! -e "$FMHOME/state/extensions" ] || live_fail "the journal started before any session held the lock"

# Nested first: the primary now holds the lock but has published nothing.
nested_round 1
[ ! -e "$FMHOME/state/extensions" ] \
  || live_fail "a Pi started inside the primary created the journal before the primary published (nested ancestry $(cat "$NESTED_DIR/mark-1.json"))"

# The genuine owner activates on its next session start.
type_line '/reload'
read -r first_gen first_conversation first_session <<<"$(wait_phase published)"
[ -n "$first_gen" ] || live_fail "first publication checkpoint printed nothing"

type_line '/journal-e2e first'
wait_phase first >/dev/null
type_line '/journal-e2e operational'
wait_phase operational >/dev/null

# Primary first: a nested Pi started now changes nothing either.
before_current=$(cat "$JOURNAL_DIR/current.json")
before_files=$(ls "$JOURNAL_DIR")
nested_round 2
[ "$(cat "$JOURNAL_DIR/current.json")" = "$before_current" ] \
  || live_fail "a Pi started inside the published primary rewrote current.json (nested ancestry $(cat "$NESTED_DIR/mark-2.json"))"
[ "$(ls "$JOURNAL_DIR")" = "$before_files" ] || live_fail "a Pi started inside the published primary added journal files"

type_line '/reload'
read -r reload_gen reload_conversation reload_session <<<"$(wait_phase reload "$first_gen")"
[ -n "$reload_gen" ] || live_fail "reload checkpoint printed nothing"
[ "$first_conversation $first_session" = "$reload_conversation $reload_session" ] \
  || live_fail "reload changed the conversation identity ($first_conversation $first_session -> $reload_conversation $reload_session)"
[ -f "$JOURNAL_DIR/$first_gen.jsonl" ] || live_fail "the previous generation's journal was not kept"

type_line '/journal-e2e second'
wait_phase second >/dev/null

type_line '/quit'
i=0
until pane | grep -Fq 'PI_EXIT=0'; do
  i=$((i + 1))
  [ "$i" -lt 200 ] || live_fail "did not exit cleanly after /quit"
  sleep 0.1
done
wait_phase quit >/dev/null

pass "Pi $PI_VERSION: only the lock-owning primary journals - a Pi started inside it writes nothing before or after its publication - and the journal carries a snapshot, captain and operational input, streamed text with authoritative ends, and tool states without private content; /reload keeps the conversation in a new generation and /quit records the stop"
