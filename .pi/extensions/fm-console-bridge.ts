// Firstmate console journal for Pi.
//
// A read-only, bounded projection of the lock-owning Pi primary's main
// conversation, written for a same-user reader such as a console UI.
// docs/pi-console-journal.md owns the published contract: location, file
// schemas, projection and privacy rules, bounds, generations, and reader rules.
// This header owns how the extension keeps that contract (stated once here).
//
// Ownership. Only the Pi process whose own session owns this home's session
// lock journals. bin/fm-session-lock-lib.sh's fm_session_lock_owned_by_self is
// the single owner of that answer, the same one bin/fm-lock.sh records against:
// the lock's pid must be in this process's contiguous verified-harness
// ancestry, and that walk stops at the first harness it meets. A Pi started
// inside the primary therefore meets itself and never the primary above it,
// whether or not the primary has published anything, and an ancestry the
// library cannot resolve is not ownership. A fresh primary takes the lock
// during its first run, so ownership is checked at session start and at every
// run boundary until it holds, and rechecked whenever a run settles. A
// non-owner only reads state/.lock (asking the library again only when the
// lock content changed) and never creates, writes, or deletes anything. The
// factory registers event handlers and nothing else.
//
// Read-only toward Pi. It reads event payloads and SessionManager getters and
// never sends messages, appends entries, or registers tools, commands, or bus
// events. Sending stays with fm-inbox; current.json publishes submit:false.
//
// Never blocking. Handlers do bounded in-memory work and return. All disk work
// and every operational-input classification run on one serial writer per
// state directory per process, with at most one filesystem operation or
// classifier child in flight; every error is caught and never reaches Pi.
//
// Generations. A generation opens only inside an event handler, or from the
// writer while no run is active. Pi appends a finished message to the session
// only after its message_end handlers return, so a snapshot taken at either
// point neither repeats nor misses the message whose record follows it. A
// stopped runtime's late callbacks reach only its own journal file, and every
// current.json update after publication is conditional on that file still
// naming the same generation.
import { randomBytes } from "node:crypto";
import { chmod, lstat, mkdir, open, readFile, realpath, rename, unlink, writeFile } from "node:fs/promises";
import type { FileHandle } from "node:fs/promises";
import { basename, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { runCommandAsync } from "./lib/fm-async-exec.ts";
import { classifyFirstmateOperationalTextWith } from "./lib/fm-operational-input.ts";

const SCHEMA = "fm-console-journal.v1";
const RECORD_MAX_BYTES = 64 * 1024;
const MESSAGE_TEXT_MAX_BYTES = 32 * 1024;
const DELTA_RECORD_TEXT_MAX_BYTES = 16 * 1024;
const DELTA_FLUSH_BYTES = 4 * 1024;
const DELTA_FLUSH_MS = 200;
const SNAPSHOT_MAX_ITEMS = 50;
const SNAPSHOT_ITEM_TEXT_MAX_BYTES = 4 * 1024;
const SNAPSHOT_TEXT_BUDGET_BYTES = 48 * 1024;
const GENERATION_MAX_BYTES = 8 * 1024 * 1024;
// Kept free below the cap for the one closing record (stopped or gap) a
// generation may still need after ordinary records stop fitting.
const GENERATION_TAIL_BYTES = 1024;
const QUEUE_MAX_BYTES = 1024 * 1024;
const WRITER_OPS_MAX = 64;
const RUNNING_TOOLS_MAX = 64;
const CURRENT_READ_MAX_BYTES = 64 * 1024;
const SHUTDOWN_WAIT_MS = 250;
const GENERATION_NAME = /^[0-9a-f]{32}$/;
const SESSION_REASONS = ["startup", "reload", "new", "resume", "fork"] as const;

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const lockLibrary = `${fmRoot}/bin/fm-session-lock-lib.sh`;
const lockPath = `${state}/.lock`;
const journalDir = `${state}/extensions/pi-console-bridge`;
const currentPath = `${journalDir}/current.json`;

type StartReason = (typeof SESSION_REASONS)[number] | "activate" | "tree" | "rotate" | "resync" | "recover";
type PublishMode = "takeover" | "continue";
type GenerationState = "pending" | "open" | "lost" | "failed" | "closed";
type UserRole = { role: "captain" } | { role: "operational"; opKind: string } | { role: "withheld" };
type Fitted = { text: string; bytes: number; truncated: boolean };
type QueueItem =
  | { seq: number; bytes: number; line: string }
  | { seq: number; bytes: number; build: () => Promise<string> };
type Body = Record<string, unknown>;

type CurrentRecord = {
  schema: typeof SCHEMA;
  capabilities: { journal: true; submit: false };
  harness: "pi";
  home: string;
  lockPid: string;
  piPid: number;
  sessionId: string | null;
  conversation: string | null;
  gen: string;
  previousGen: string | null;
  startedReason: StartReason;
  journal: string;
  state: "live" | "stopped" | "failed" | "lost";
  stoppedReason: string | null;
  updatedAt: string;
};

type SessionView = {
  sessionId: string | null;
  conversation: string | null;
  leafId: string | null;
  branch: readonly unknown[];
};

type Candidate = { entry: string | null; role: "user" | "assistant"; content: unknown; stopReason?: string };
type DialogEntry = { id?: unknown; type: "message"; message: { role: "user" | "assistant"; [field: string]: unknown } };

type Generation = {
  id: string;
  reason: StartReason;
  mode: PublishMode;
  owner: Epoch;
  lockPid: string;
  session: SessionView;
  state: GenerationState;
  handle: FileHandle | null;
  seq: number;
  bytes: number;
  queue: QueueItem[];
  queueBytes: number;
  draining: boolean;
  dropped: number;
  messages: number;
  tools: number;
  published: CurrentRecord | null;
};

type Assistant = { gen: string | null; msg: string; streamed: number };
type RunningTool = { gen: string | null; tool: string; name: string };

type Epoch = {
  stopped: boolean;
  ctx: unknown;
  sessionReason: StartReason;
  checking: boolean;
  runActive: boolean;
  generation: Generation | null;
  publishedGen: string | null;
  lockPid: string;
  needsRecovery: boolean;
  pendingOpen: { reason: StartReason; mode: PublishMode } | null;
  knownLeaf: string | null;
  assistant: Assistant | null;
  delta: { block: number; text: string; bytes: number } | null;
  deltaTimer: ReturnType<typeof setTimeout> | undefined;
  tools: Map<string, RunningTool>;
};

type Writer = { tail: Promise<void>; ops: number };
type WriterGlobal = typeof globalThis & { __firstmateConsoleJournalWriters?: Map<string, Writer> };

let homeIdentity: string | null = null;
let temporaryId = 0;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function nowIso(): string {
  return new Date().toISOString();
}

function errorCode(error: unknown): string {
  const code = isRecord(error) && typeof error.code === "string" ? error.code : "";
  return /^[A-Z0-9_]{1,24}$/.test(code) ? code : "UNKNOWN";
}

// One serial writer per journal directory per process, shared by every
// runtime a reload or session replacement creates, so at most one filesystem
// operation is ever in flight and operations land in the order they were
// scheduled. Created at the first scheduled operation, never at import.
function writer(): Writer {
  const registry = ((globalThis as WriterGlobal).__firstmateConsoleJournalWriters ??= new Map<string, Writer>());
  let found = registry.get(journalDir);
  if (!found) {
    found = { tail: Promise.resolve(), ops: 0 };
    registry.set(journalDir, found);
  }
  return found;
}

function schedule(op: () => Promise<void>): boolean {
  const lane = writer();
  if (lane.ops >= WRITER_OPS_MAX) return false;
  lane.ops += 1;
  lane.tail = lane.tail
    .then(op)
    .catch(() => undefined)
    .then(() => {
      lane.ops -= 1;
    });
  return true;
}

// ---- Bounded text --------------------------------------------------------
// Budgets count the UTF-8 bytes of the JSON-escaped form, so a record's size
// is bounded however much escaping its text needs.

function escapedCost(ch: string): number {
  if (ch.length === 2) return 4;
  const code = ch.charCodeAt(0);
  if (code >= 0xd800 && code <= 0xdfff) return 6;
  if (code === 0x22 || code === 0x5c) return 2;
  if (code < 0x20) return code === 8 || code === 9 || code === 10 || code === 12 || code === 13 ? 2 : 6;
  if (code < 0x80) return 1;
  return code < 0x800 ? 2 : 3;
}

function fitText(text: string, budget: number): Fitted {
  if (budget <= 0) return { text: "", bytes: 0, truncated: text.length > 0 };
  if (text.length * 6 <= budget) {
    return { text, bytes: Buffer.byteLength(JSON.stringify(text), "utf8") - 2, truncated: false };
  }
  let used = 0;
  let end = 0;
  for (const ch of text) {
    const cost = escapedCost(ch);
    if (used + cost > budget) return { text: text.slice(0, end), bytes: used, truncated: true };
    used += cost;
    end += ch.length;
  }
  return { text, bytes: used, truncated: false };
}

// Visible text of a message: text parts joined by newlines, with an [image]
// marker for each user image and nothing from any other part.
function projectContent(content: unknown, budget: number, images: boolean): Fitted {
  const pieces: string[] = [];
  let used = 0;
  let first = true;
  const push = (piece: string): boolean => {
    const fitted = fitText(first ? piece : `\n${piece}`, budget - used);
    first = false;
    pieces.push(fitted.text);
    used += fitted.bytes;
    return !fitted.truncated;
  };
  let complete = true;
  if (typeof content === "string") {
    complete = push(content);
  } else if (Array.isArray(content)) {
    for (const part of content) {
      if (!isRecord(part)) continue;
      if (part.type === "text" && typeof part.text === "string") complete = push(part.text);
      else if (images && part.type === "image") complete = push("[image]");
      if (!complete) break;
    }
  }
  return { text: pieces.join(""), bytes: used, truncated: !complete };
}

// The text the operational classifier judges, joined exactly as the watcher
// joins a user message's text parts.
function userText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const part of content) {
    if (isRecord(part) && part.type === "text" && typeof part.text === "string") parts.push(part.text);
  }
  return parts.join("\n");
}

function hasVisibleText(content: unknown): boolean {
  if (typeof content === "string") return /\S/.test(content);
  if (!Array.isArray(content)) return false;
  return content.some((part) => isRecord(part) && part.type === "text" && typeof part.text === "string" && /\S/.test(part.text));
}

function stopReasonOf(value: unknown): string | undefined {
  return typeof value === "string" && /^[A-Za-z]{1,16}$/.test(value) ? value : undefined;
}

function toolNameOf(value: unknown): string {
  if (typeof value !== "string") return "unknown";
  const cleaned = value.replace(/[\u0000-\u001f\u007f]/g, "").slice(0, 128);
  return cleaned || "unknown";
}

async function classifyUser(content: unknown): Promise<UserRole> {
  try {
    const kind = await classifyFirstmateOperationalTextWith(runCommandAsync, userText(content));
    if (kind === undefined) return { role: "captain" };
    return { role: "operational", opKind: /^[a-z0-9-]{1,32}$/.test(kind) ? kind : "unknown" };
  } catch {
    return { role: "withheld" };
  }
}

// ---- Session reads ------------------------------------------------------

function readSession(ctx: unknown): SessionView | null {
  try {
    const manager = isRecord(ctx) && isRecord(ctx.sessionManager) ? ctx.sessionManager : null;
    if (!manager) return null;
    // Pi's ReadonlySessionManager getters, each called only if present and
    // each result checked, so a changed manager reads as unknown, never wrong.
    const read = (name: string): unknown => {
      const getter = manager[name];
      return typeof getter === "function" ? getter.call(manager) : undefined;
    };
    const file = read("getSessionFile");
    const id = read("getSessionId");
    const leaf = read("getLeafId");
    const branch = read("getBranch");
    return {
      sessionId: typeof id === "string" && id ? id.slice(0, 128) : null,
      conversation: typeof file === "string" && file ? basename(file).slice(0, 255) : null,
      leafId: typeof leaf === "string" ? leaf : null,
      branch: Array.isArray(branch) ? branch : [],
    };
  } catch {
    return null;
  }
}

function isDialogEntry(entry: unknown): entry is DialogEntry {
  return isRecord(entry) && entry.type === "message" && isRecord(entry.message) &&
    (entry.message.role === "user" || entry.message.role === "assistant");
}

function candidateOf(entry: unknown): Candidate | null {
  if (!isDialogEntry(entry)) return null;
  const id = typeof entry.id === "string" && /^[A-Za-z0-9-]{1,64}$/.test(entry.id) ? entry.id : null;
  if (entry.message.role === "user") return { entry: id, role: "user", content: entry.message.content };
  const stopReason = stopReasonOf(entry.message.stopReason);
  if (!hasVisibleText(entry.message.content) && stopReason !== "error" && stopReason !== "aborted") return null;
  return { entry: id, role: "assistant", content: entry.message.content, stopReason };
}

// ---- Lock ownership -----------------------------------------------------

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

// The session lock names a local pid or, on Windows, a tagged `win:<pid>`
// (fm_session_pid_valid in bin/fm-session-lock-lib.sh owns that shape).
function lockHolderPid(lockPid: string): string {
  const tagged = process.platform === "win32" ? /^win:([0-9]+)$/.exec(lockPid) : null;
  const pid = tagged ? tagged[1] : lockPid;
  return /^[0-9]+$/.test(pid) && pid !== "1" ? pid : "";
}

async function readCurrentRecord(): Promise<CurrentRecord | null> {
  try {
    const info = await lstat(currentPath);
    if (!info.isFile() || info.size > CURRENT_READ_MAX_BYTES) return null;
    const value: unknown = JSON.parse(await readFile(currentPath, "utf8"));
    if (!isRecord(value) || value.schema !== SCHEMA || typeof value.gen !== "string" || !GENERATION_NAME.test(value.gen)) {
      return null;
    }
    return value as CurrentRecord;
  } catch {
    return null;
  }
}

// ---- Factory ------------------------------------------------------------

export default function (pi: ExtensionAPI): void {
  let current: Epoch | null = null;
  // Ownership answers keyed by the exact lock content they were computed for.
  let ownedLock = "";
  let negativeLock = "";

  const isLive = (ep: Epoch): boolean => current === ep && !ep.stopped;

  // The header's ownership rule. A positive answer is reused while the lock
  // content stays the same and its holder is alive; a negative one is reused
  // for the same lock content unless the lock names this process, whose answer
  // is asked again at the next boundary.
  async function checkOwnership(): Promise<{ owned: boolean; lockPid: string }> {
    let lockPid = "";
    try {
      lockPid = (await readFile(lockPath, "utf8")).trim();
    } catch {
      return { owned: false, lockPid: "" };
    }
    const holder = lockHolderPid(lockPid);
    if (!holder) return { owned: false, lockPid };
    if (ownedLock === lockPid && pidAlive(holder)) return { owned: true, lockPid };
    if (negativeLock === lockPid) return { owned: false, lockPid };
    const answer = await runCommandAsync("bash", [
      "-c",
      '. "$1" && fm_session_lock_owned_by_self "$2"',
      "fm-console-bridge",
      lockLibrary,
      state,
    ]);
    if (answer.status === 0) {
      ownedLock = lockPid;
      negativeLock = "";
      return { owned: true, lockPid };
    }
    if (holder !== String(process.pid)) negativeLock = lockPid;
    return { owned: false, lockPid };
  }

  async function verifyOwnership(ep: Epoch, trigger: "session" | "run"): Promise<void> {
    if (ep.checking) return;
    ep.checking = true;
    let result: { owned: boolean; lockPid: string };
    try {
      result = await checkOwnership();
    } catch {
      result = { owned: false, lockPid: "" };
    } finally {
      ep.checking = false;
    }
    if (!isLive(ep)) return;
    if (result.owned) {
      ep.lockPid = result.lockPid;
      if (!ep.generation) requestOpen(ep, trigger === "session" ? ep.sessionReason : "activate", "takeover");
      else if (ep.needsRecovery) requestOpen(ep, "recover", "takeover");
      return;
    }
    if (ep.generation) stopGeneration(ep, "lock-lost");
  }

  function requestOpen(ep: Epoch, reason: StartReason, mode: PublishMode): void {
    if (!isLive(ep)) return;
    if (ep.runActive) ep.pendingOpen = { reason, mode };
    else openGeneration(ep, reason, mode);
  }

  // ---- Generations ------------------------------------------------------

  function writable(ep: Epoch): Generation | null {
    const g = ep.generation;
    return g && (g.state === "pending" || g.state === "open") ? g : null;
  }

  function openGeneration(ep: Epoch, reason: StartReason, mode: PublishMode): void {
    const session = readSession(ep.ctx);
    if (!session) return;
    const previous = ep.generation;
    clearTimeout(ep.deltaTimer);
    ep.deltaTimer = undefined;
    ep.delta = null;
    if (previous && (previous.state === "pending" || previous.state === "open")) {
      if (!schedule(() => closeGeneration(previous))) previous.state = "closed";
    }
    const g: Generation = {
      id: randomBytes(16).toString("hex"),
      reason,
      mode,
      owner: ep,
      lockPid: ep.lockPid,
      session,
      state: "pending",
      handle: null,
      seq: 0,
      bytes: 0,
      queue: [],
      queueBytes: 0,
      draining: false,
      dropped: 0,
      messages: 0,
      tools: 0,
      published: null,
    };
    ep.generation = g;
    ep.needsRecovery = false;
    ep.pendingOpen = null;
    ep.knownLeaf = session.leafId;
    const capture = collectCandidates(session.branch);
    const busy = ep.runActive;
    const at = nowIso();
    push(ep, g, { seq: ++g.seq, bytes: RECORD_MAX_BYTES, build: () => buildSnapshot(g, 1, at, capture, busy) });
    if (ep.assistant) {
      append(ep, (gen) => ({ type: "message", phase: "start", msg: assistantMsg(ep, gen), role: "assistant" }));
    }
    for (const [id, tool] of ep.tools) {
      append(ep, (gen) => ({ type: "tool", phase: "start", tool: toolOrdinal(ep, gen, id), name: tool.name }));
    }
    if (!schedule(() => openJournal(g))) {
      g.state = "failed";
      ep.needsRecovery = true;
    }
  }

  function collectCandidates(branch: readonly unknown[]): { items: Candidate[]; omitted: number } {
    const items: Candidate[] = [];
    let omitted = 0;
    for (let index = branch.length - 1; index >= 0; index -= 1) {
      const candidate = candidateOf(branch[index]);
      if (!candidate) continue;
      if (items.length < SNAPSHOT_MAX_ITEMS) items.push(candidate);
      else omitted += 1;
    }
    items.reverse();
    return { items, omitted };
  }

  async function buildSnapshot(
    g: Generation,
    seq: number,
    at: string,
    capture: { items: Candidate[]; omitted: number },
    busy: boolean,
  ): Promise<string> {
    const roles: (UserRole | { role: "assistant" })[] = [];
    for (const item of capture.items) {
      roles.push(item.role === "user" ? await classifyUser(item.content) : { role: "assistant" });
    }
    for (let start = 0; ; start += 1) {
      const items: Body[] = [];
      let remaining = SNAPSHOT_TEXT_BUDGET_BYTES;
      let truncatedItems = 0;
      for (let index = capture.items.length - 1; index >= start; index -= 1) {
        const item = capture.items[index];
        const role = roles[index];
        const projected: Body = { entry: item.entry, role: role.role };
        if (role.role === "operational") projected.opKind = role.opKind;
        if (role.role === "captain" || role.role === "assistant") {
          const fitted = projectContent(item.content, Math.min(SNAPSHOT_ITEM_TEXT_MAX_BYTES, remaining), role.role === "captain");
          remaining -= fitted.bytes;
          projected.text = fitted.text;
          if (fitted.truncated) {
            projected.truncated = true;
            truncatedItems += 1;
          }
        }
        if (item.stopReason) projected.stopReason = item.stopReason;
        items.push(projected);
      }
      items.reverse();
      const line = serialize(g, seq, at, {
        type: "snapshot",
        reason: g.reason,
        sessionId: g.session.sessionId,
        conversation: g.session.conversation,
        leafId: g.session.leafId,
        busy,
        items,
        omittedBefore: capture.omitted + start,
        truncatedItems,
      });
      if (Buffer.byteLength(line, "utf8") + 1 <= RECORD_MAX_BYTES || start >= capture.items.length) return line;
    }
  }

  // `at` is when the projected event happened, which for a record finished
  // later on the writer (a classified user message, a snapshot) is earlier
  // than its serialization.
  function serialize(g: Generation, seq: number, at: string, body: Body): string {
    return JSON.stringify({ seq, gen: g.id, at, ...body });
  }

  function push(ep: Epoch, g: Generation, item: QueueItem): void {
    g.queue.push(item);
    g.queueBytes += item.bytes;
    g.bytes += item.bytes;
    if (g.queueBytes > QUEUE_MAX_BYTES) {
      lose(ep, g);
      return;
    }
    scheduleDrain(g);
  }

  function append(ep: Epoch, body: (g: Generation) => Body): void {
    let g = writable(ep);
    if (!g) {
      if (ep.generation?.state === "lost") ep.generation.dropped += 1;
      return;
    }
    const at = nowIso();
    let line = serialize(g, g.seq + 1, at, body(g));
    if (g.bytes + Buffer.byteLength(line, "utf8") + 1 > GENERATION_MAX_BYTES - GENERATION_TAIL_BYTES) {
      openGeneration(ep, "rotate", "continue");
      g = writable(ep);
      if (!g) return;
      line = serialize(g, g.seq + 1, at, body(g));
    }
    g.seq += 1;
    push(ep, g, { seq: g.seq, bytes: Buffer.byteLength(line, "utf8") + 1, line });
  }

  function appendDeferred(ep: Epoch, make: (g: Generation, seq: number) => () => Promise<string>): void {
    let g = writable(ep);
    if (!g) {
      if (ep.generation?.state === "lost") ep.generation.dropped += 1;
      return;
    }
    if (g.bytes + RECORD_MAX_BYTES > GENERATION_MAX_BYTES - GENERATION_TAIL_BYTES) {
      openGeneration(ep, "rotate", "continue");
      g = writable(ep);
      if (!g) return;
    }
    const seq = ++g.seq;
    push(ep, g, { seq, bytes: RECORD_MAX_BYTES, build: make(g, seq) });
  }

  // The writer could not keep up: drop everything still queued, keep counting
  // what would have followed, and let the writer close the journal with a gap
  // record. Sequence numbers restart from the last record already handed to
  // the writer, so the journal stays gap-free up to its closing record.
  function lose(ep: Epoch, g: Generation): void {
    g.state = "lost";
    const first = g.queue[0];
    if (first) g.seq = first.seq - 1;
    g.dropped += g.queue.length;
    for (const item of g.queue) g.bytes -= item.bytes;
    g.queue = [];
    g.queueBytes = 0;
    if (!schedule(() => finishLost(g))) {
      g.state = "failed";
      ep.needsRecovery = true;
    }
  }

  function assistantMsg(ep: Epoch, g: Generation): string {
    const assistant = (ep.assistant ??= { gen: null, msg: "", streamed: 0 });
    if (assistant.gen !== g.id) {
      g.messages += 1;
      assistant.gen = g.id;
      assistant.msg = `m${g.messages}`;
    }
    return assistant.msg;
  }

  function toolOrdinal(ep: Epoch, g: Generation, id: string): string {
    let tool = ep.tools.get(id);
    if (!tool) {
      tool = { gen: null, tool: "", name: "unknown" };
      ep.tools.set(id, tool);
    }
    if (tool.gen !== g.id) {
      g.tools += 1;
      tool.gen = g.id;
      tool.tool = `t${g.tools}`;
    }
    return tool.tool;
  }

  function flushDelta(ep: Epoch): void {
    clearTimeout(ep.deltaTimer);
    ep.deltaTimer = undefined;
    const buffer = ep.delta;
    ep.delta = null;
    if (!buffer || !writable(ep)) return;
    let rest = buffer.text;
    while (rest.length > 0) {
      const piece = fitText(rest, DELTA_RECORD_TEXT_MAX_BYTES);
      if (!piece.text) break;
      append(ep, (g) => ({ type: "delta", msg: assistantMsg(ep, g), block: buffer.block, text: piece.text }));
      rest = rest.slice(piece.text.length);
    }
  }

  // A /tree move, or any leaf change that brings dialog the generation never
  // streamed, makes the journal's branch wrong: open a new generation.
  function branchChanged(ep: Epoch): boolean {
    const session = readSession(ep.ctx);
    if (!session) return false;
    let dialog = false;
    for (let index = session.branch.length - 1; index >= 0; index -= 1) {
      const entry = session.branch[index];
      if (ep.knownLeaf !== null && isRecord(entry) && entry.id === ep.knownLeaf) return dialog;
      if (isDialogEntry(entry)) dialog = true;
    }
    return ep.knownLeaf === null ? dialog : true;
  }

  function stopGeneration(ep: Epoch, reason: string): Promise<void> | null {
    flushDelta(ep);
    const g = ep.generation;
    ep.generation = null;
    if (!g || (g.state !== "pending" && g.state !== "open")) return null;
    g.seq += 1;
    const line = serialize(g, g.seq, nowIso(), { type: "stopped", reason });
    const bytes = Buffer.byteLength(line, "utf8") + 1;
    g.queue.push({ seq: g.seq, bytes, line });
    g.queueBytes += bytes;
    g.bytes += bytes;
    if (!schedule(() => stopJournal(g, reason))) return null;
    return writer().tail;
  }

  // ---- Writer operations (run one at a time, in order) -------------------

  function scheduleDrain(g: Generation): void {
    if (g.draining) return;
    g.draining = true;
    const scheduled = schedule(async () => {
      try {
        if (g.state === "open") await drain(g);
      } finally {
        g.draining = false;
      }
    });
    if (!scheduled) g.draining = false;
  }

  async function writeAll(g: Generation, text: string): Promise<void> {
    const handle = g.handle;
    if (!handle) throw Object.assign(new Error("journal is not open"), { code: "EBADF" });
    const bytes = Buffer.from(text, "utf8");
    let offset = 0;
    while (offset < bytes.length) {
      const { bytesWritten } = await handle.write(bytes, offset, bytes.length - offset);
      if (bytesWritten <= 0) throw Object.assign(new Error("journal write made no progress"), { code: "EIO" });
      offset += bytesWritten;
    }
  }

  // Writes queued records in order, one batch per round; a deferred record is
  // finished alone. `rounds` bounds the batches written by this call.
  async function drain(g: Generation, rounds = Number.POSITIVE_INFINITY): Promise<void> {
    for (let round = 0; round < rounds && (g.state === "open" || g.state === "lost") && g.queue.length > 0; round += 1) {
      const batch: string[] = [];
      while (g.queue.length > 0) {
        const item = g.queue[0];
        if ("line" in item) {
          g.queue.shift();
          g.queueBytes -= item.bytes;
          batch.push(item.line);
          continue;
        }
        if (batch.length > 0) break;
        g.queue.shift();
        g.queueBytes -= item.bytes;
        let line: string;
        try {
          line = await item.build();
        } catch {
          line = serialize(g, item.seq, nowIso(), { type: "gap", reason: "build-error", droppedRecords: 1 });
        }
        if (g.state !== "open" && g.state !== "lost") return;
        g.bytes += Buffer.byteLength(line, "utf8") + 1 - item.bytes;
        batch.push(line);
        break;
      }
      if (batch.length === 0) return;
      try {
        await writeAll(g, `${batch.join("\n")}\n`);
      } catch (error) {
        await failGeneration(g, error);
        return;
      }
    }
  }

  async function closeHandle(g: Generation): Promise<void> {
    const handle = g.handle;
    g.handle = null;
    if (!handle) return;
    try {
      await handle.close();
    } catch {
      // Closing a descriptor that already failed changes nothing on disk.
    }
  }

  async function ensureDirectory(): Promise<void> {
    await mkdir(journalDir, { recursive: true, mode: 0o700 });
    const info = await lstat(journalDir);
    if (!info.isDirectory()) throw Object.assign(new Error("journal path is not a directory"), { code: "ENOTDIR" });
    if (typeof process.getuid === "function" && info.uid !== process.getuid()) {
      throw Object.assign(new Error("journal directory belongs to another user"), { code: "EPERM" });
    }
    if ((info.mode & 0o077) !== 0) await chmod(journalDir, 0o700);
  }

  async function writeCurrent(record: CurrentRecord): Promise<void> {
    temporaryId += 1;
    const temporary = `${currentPath}.tmp-${process.pid}-${temporaryId}`;
    try {
      await writeFile(temporary, `${JSON.stringify(record)}\n`, { flag: "wx", mode: 0o600 });
      await rename(temporary, currentPath);
    } catch (error) {
      try {
        await unlink(temporary);
      } catch {
        // The temporary file was never created or was already renamed.
      }
      throw error;
    }
  }

  async function updateCurrent(g: Generation, next: CurrentRecord["state"], reason: string): Promise<void> {
    if (!g.published) return;
    try {
      if ((await readCurrentRecord())?.gen !== g.id) return;
      const record: CurrentRecord = { ...g.published, state: next, stoppedReason: reason, updatedAt: nowIso() };
      await writeCurrent(record);
      g.published = record;
    } catch {
      // Best effort: the reader also treats a dead piPid as stopped.
    }
  }

  async function failGeneration(g: Generation, error: unknown): Promise<void> {
    if (g.state === "failed" || g.state === "closed") return;
    g.state = "failed";
    g.dropped += g.queue.length;
    g.queue = [];
    g.queueBytes = 0;
    await closeHandle(g);
    await updateCurrent(g, "failed", `write-error:${errorCode(error)}`);
    if (g.owner.generation === g && !g.owner.stopped) g.owner.needsRecovery = true;
  }

  // Remove only the journal the replaced record itself named as its previous
  // generation, after positive checks that it is an ordinary file of ours.
  async function prune(previous: CurrentRecord | null, keep: string): Promise<void> {
    const stale = previous?.previousGen;
    if (typeof stale !== "string" || !GENERATION_NAME.test(stale) || stale === keep || stale === previous?.gen) return;
    const path = `${journalDir}/${stale}.jsonl`;
    try {
      const info = await lstat(path);
      if (!info.isFile() || (typeof process.getuid === "function" && info.uid !== process.getuid())) return;
      await unlink(path);
    } catch {
      // Already gone, or not something this journal owns.
    }
  }

  async function publish(g: Generation): Promise<void> {
    const previous = await readCurrentRecord();
    if (homeIdentity === null) {
      try {
        homeIdentity = await realpath(fmHome);
      } catch {
        homeIdentity = resolve(fmHome);
      }
    }
    const record: CurrentRecord = {
      schema: SCHEMA,
      capabilities: { journal: true, submit: false },
      harness: "pi",
      home: homeIdentity,
      lockPid: g.lockPid,
      piPid: process.pid,
      sessionId: g.session.sessionId,
      conversation: g.session.conversation,
      gen: g.id,
      previousGen: previous && previous.gen !== g.id ? previous.gen : null,
      startedReason: g.reason,
      journal: `${g.id}.jsonl`,
      state: "live",
      stoppedReason: null,
      updatedAt: nowIso(),
    };
    await writeCurrent(record);
    g.published = record;
    g.owner.publishedGen = g.id;
    await prune(previous, g.id);
  }

  async function openJournal(g: Generation): Promise<void> {
    if (g.state !== "pending") {
      if (g.state === "lost") await finishLost(g);
      return;
    }
    const path = `${journalDir}/${g.id}.jsonl`;
    try {
      await ensureDirectory();
      if (g.mode === "continue" && (await readCurrentRecord())?.gen !== g.owner.publishedGen) {
        // Another runtime published since this one did: it is superseded.
        g.state = "closed";
        if (g.owner.generation === g) g.owner.generation = null;
        return;
      }
      g.handle = await open(path, "ax", 0o600);
    } catch (error) {
      await failGeneration(g, error);
      return;
    }
    if (g.state !== "pending") {
      // Lost before its snapshot was written: leave no journal without one.
      await closeHandle(g);
      try {
        await unlink(path);
      } catch {
        // The empty journal this operation created is already gone.
      }
      return;
    }
    g.state = "open";
    // The snapshot is always the first queued record and is finished alone, so
    // one round writes exactly it; publishing then never waits on a stream.
    await drain(g, 1);
    if (g.state !== "open" && g.state !== "lost") return;
    try {
      await publish(g);
    } catch (error) {
      await failGeneration(g, error);
      return;
    }
    if (g.queue.length > 0) scheduleDrain(g);
  }

  async function finishLost(g: Generation): Promise<void> {
    if (g.state !== "lost") return;
    if (g.handle) {
      g.seq += 1;
      try {
        await writeAll(g, `${serialize(g, g.seq, nowIso(), { type: "gap", reason: "backpressure", droppedRecords: g.dropped })}\n`);
      } catch (error) {
        await failGeneration(g, error);
        return;
      }
      await closeHandle(g);
      await updateCurrent(g, "lost", "backpressure");
    }
    g.state = "closed";
    const ep = g.owner;
    if (ep.generation === g) requestOpen(ep, "resync", "continue");
  }

  async function closeGeneration(g: Generation): Promise<void> {
    if (g.state === "pending") {
      g.state = "closed";
      g.queue = [];
      g.queueBytes = 0;
      return;
    }
    if (g.state === "open") await drain(g);
    await closeHandle(g);
    if (g.state === "open") g.state = "closed";
  }

  async function stopJournal(g: Generation, reason: string): Promise<void> {
    if (g.state === "pending") {
      g.state = "closed";
      g.queue = [];
      g.queueBytes = 0;
      return;
    }
    if (g.state === "open") await drain(g);
    await closeHandle(g);
    if (g.state !== "open") return;
    g.state = "closed";
    await updateCurrent(g, "stopped", reason);
  }

  // ---- Event handlers ---------------------------------------------------

  function newEpoch(ctx: unknown, sessionReason: StartReason): Epoch {
    return {
      stopped: false,
      ctx,
      sessionReason,
      checking: false,
      runActive: false,
      generation: null,
      publishedGen: null,
      lockPid: "",
      needsRecovery: false,
      pendingOpen: null,
      knownLeaf: null,
      assistant: null,
      delta: null,
      deltaTimer: undefined,
      tools: new Map(),
    };
  }

  function stopEpoch(ep: Epoch, reason: string): Promise<void> | null {
    const pending = stopGeneration(ep, reason);
    ep.stopped = true;
    clearTimeout(ep.deltaTimer);
    ep.deltaTimer = undefined;
    ep.pendingOpen = null;
    return pending;
  }

  // Every lifecycle handler goes through this: it never throws into Pi, a
  // stopped runtime ignores late events, and a generation requested while a
  // run was active opens before the event is projected.
  function handle(project: (ep: Epoch, event: unknown) => void): (event: unknown, ctx: unknown) => void {
    return (event, ctx) => {
      try {
        const ep = current;
        if (!ep || ep.stopped) return;
        if (ctx) ep.ctx = ctx;
        if (ep.pendingOpen) {
          const pending = ep.pendingOpen;
          ep.pendingOpen = null;
          openGeneration(ep, pending.reason, pending.mode);
        }
        project(ep, event);
      } catch {
        // The journal is best effort; Pi's turn always continues.
      }
    };
  }

  pi.on("session_start", (event: unknown, ctx: unknown) => {
    try {
      if (current && !current.stopped) stopEpoch(current, "replaced");
      const requested = isRecord(event) ? event.reason : undefined;
      const ep = newEpoch(ctx, SESSION_REASONS.find((known) => known === requested) ?? "startup");
      current = ep;
      void verifyOwnership(ep, "session");
    } catch {
      // A journal that cannot start leaves the session untouched.
    }
  });

  pi.on("session_shutdown", async (event: unknown) => {
    let pending: Promise<void> | null = null;
    try {
      const ep = current;
      if (ep && !ep.stopped) {
        const reason = isRecord(event) && typeof event.reason === "string" && /^[a-z][a-z-]{0,23}$/.test(event.reason)
          ? event.reason
          : "unknown";
        pending = stopEpoch(ep, reason);
      }
    } catch {
      pending = null;
    }
    if (!pending) return;
    // A bounded wait lets a healthy disk record the stop before Pi exits or
    // replaces the runtime; a slow one never holds shutdown longer than this.
    let timer: ReturnType<typeof setTimeout> | undefined;
    await Promise.race([
      pending,
      new Promise<void>((done) => {
        timer = setTimeout(done, SHUTDOWN_WAIT_MS);
      }),
    ]);
    clearTimeout(timer);
  });

  pi.on("agent_start", handle((ep) => {
    if (!ep.runActive) {
      if (writable(ep) && branchChanged(ep)) openGeneration(ep, "tree", "continue");
      ep.runActive = true;
      append(ep, () => ({ type: "run", state: "started" }));
    }
    if (!ep.generation) void verifyOwnership(ep, "run");
  }));

  pi.on("agent_settled", handle((ep, event) => {
    flushDelta(ep);
    append(ep, () => ({ type: "run", state: "settled", aborted: isRecord(event) && event.aborted === true }));
    ep.runActive = false;
    ep.assistant = null;
    ep.tools.clear();
    if (writable(ep)) ep.knownLeaf = readSession(ep.ctx)?.leafId ?? ep.knownLeaf;
    void verifyOwnership(ep, "run");
  }));

  pi.on("session_tree", handle((ep) => {
    if (writable(ep) && branchChanged(ep)) openGeneration(ep, "tree", "continue");
  }));

  pi.on("message_start", handle((ep, event) => {
    const message = isRecord(event) && isRecord(event.message) ? event.message : null;
    if (!message || message.role !== "assistant") return;
    flushDelta(ep);
    ep.assistant = { gen: null, msg: "", streamed: 0 };
    append(ep, (g) => ({ type: "message", phase: "start", msg: assistantMsg(ep, g), role: "assistant" }));
  }));

  pi.on("message_update", handle((ep, event) => {
    const update = isRecord(event) && isRecord(event.assistantMessageEvent) ? event.assistantMessageEvent : null;
    if (!update || update.type !== "text_delta" || typeof update.delta !== "string") return;
    const block = typeof update.contentIndex === "number" && Number.isInteger(update.contentIndex) && update.contentIndex >= 0
      ? update.contentIndex
      : 0;
    if (!writable(ep)) {
      ep.assistant ??= { gen: null, msg: "", streamed: 0 };
      return;
    }
    if (!ep.assistant) {
      // A stream whose start this runtime never saw still opens with a start.
      ep.assistant = { gen: null, msg: "", streamed: 0 };
      append(ep, (g) => ({ type: "message", phase: "start", msg: assistantMsg(ep, g), role: "assistant" }));
    }
    const assistant = ep.assistant;
    const piece = fitText(update.delta, MESSAGE_TEXT_MAX_BYTES - assistant.streamed);
    assistant.streamed += piece.bytes;
    if (!piece.text) return;
    if (ep.delta && ep.delta.block !== block) flushDelta(ep);
    const buffer = (ep.delta ??= { block, text: "", bytes: 0 });
    buffer.text += piece.text;
    buffer.bytes += piece.bytes;
    if (buffer.bytes >= DELTA_FLUSH_BYTES) {
      flushDelta(ep);
    } else if (!ep.deltaTimer) {
      const timer = setTimeout(() => {
        if (ep.deltaTimer !== timer) return;
        ep.deltaTimer = undefined;
        try {
          if (isLive(ep)) flushDelta(ep);
        } catch {
          // A failed flush only loses streamed text; message_end is authoritative.
        }
      }, DELTA_FLUSH_MS);
      timer.unref?.();
      ep.deltaTimer = timer;
    }
  }));

  pi.on("message_end", handle((ep, event) => {
    const message = isRecord(event) && isRecord(event.message) ? event.message : null;
    if (!message) return;
    if (message.role === "assistant") {
      flushDelta(ep);
      const fitted = projectContent(message.content, MESSAGE_TEXT_MAX_BYTES, false);
      const stopReason = stopReasonOf(message.stopReason);
      append(ep, (g) => ({
        type: "message",
        phase: "end",
        msg: assistantMsg(ep, g),
        role: "assistant",
        text: fitted.text,
        ...(fitted.truncated ? { truncated: true } : {}),
        ...(stopReason ? { stopReason } : {}),
      }));
      ep.assistant = null;
      return;
    }
    if (message.role !== "user") return;
    const content = message.content;
    appendDeferred(ep, (g, seq) => {
      g.messages += 1;
      const msg = `m${g.messages}`;
      const at = nowIso();
      return async () => {
        const role = await classifyUser(content);
        const body: Body = { type: "message", phase: "end", msg, role: role.role };
        if (role.role === "operational") body.opKind = role.opKind;
        if (role.role === "captain") {
          const fitted = projectContent(content, MESSAGE_TEXT_MAX_BYTES, true);
          body.text = fitted.text;
          if (fitted.truncated) body.truncated = true;
        }
        return serialize(g, seq, at, body);
      };
    });
  }));

  pi.on("tool_execution_start", handle((ep, event) => {
    if (!isRecord(event) || typeof event.toolCallId !== "string" || typeof event.parentToolCallId === "string") return;
    if (ep.tools.size >= RUNNING_TOOLS_MAX && !ep.tools.has(event.toolCallId)) return;
    const id = event.toolCallId;
    const name = toolNameOf(event.toolName);
    ep.tools.set(id, { gen: null, tool: "", name });
    append(ep, (g) => ({ type: "tool", phase: "start", tool: toolOrdinal(ep, g, id), name }));
  }));

  pi.on("tool_execution_end", handle((ep, event) => {
    if (!isRecord(event) || typeof event.toolCallId !== "string" || typeof event.parentToolCallId === "string") return;
    const id = event.toolCallId;
    const name = ep.tools.get(id)?.name ?? toolNameOf(event.toolName);
    if (!ep.tools.has(id)) ep.tools.set(id, { gen: null, tool: "", name });
    const duration = typeof event.durationMs === "number" && Number.isFinite(event.durationMs) && event.durationMs >= 0
      ? Math.round(event.durationMs)
      : undefined;
    append(ep, (g) => ({
      type: "tool",
      phase: "end",
      tool: toolOrdinal(ep, g, id),
      name,
      isError: event.isError === true,
      ...(duration === undefined ? {} : { durationMs: duration }),
    }));
    ep.tools.delete(id);
  }));
}
