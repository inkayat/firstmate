// Firstmate console submit channel for omp (Oh My Pi).
//
// docs/console-submit.md owns the contract (fm-console-submit.v1);
// bin/fm-console-submit.sh is the only writer of new messages. This header
// owns how the omp primary delivers them, read from omp 18.12.6's own source:
//   - pi.sendUserMessage returns nothing: the API wrapper drops the session's
//     promise and reports a rejection only on omp's own error channel, so
//     delivery is observed through events, never awaited.
//   - With no deliverAs it runs omp's prompt path, the one Enter uses: on an
//     idle session it starts a turn at once. deliverAs "followUp" appends to
//     the follow-up queue, which omp reads after the current run. Both store
//     the message with attribution "user" and expand no slash command or
//     prompt template; the prompt path may rewrite a ^model mention.
//   - ctx.isIdle() is !session.isStreaming, and ctx.hasPendingMessages()
//     counts queued steering, follow-up, and deferred messages.
//   - Either path reaches extensions as a user message_start carrying the
//     stored text, then the run settles with agent_end whose willContinue is
//     not true.
//   - An interrupt returns queued user messages to the editor and no event
//     tells an extension, so a follow-up that is neither read nor still
//     queued once the session is idle was taken back at the terminal.
//
// Ownership. Only a session with a UI (an omp task subagent binds this
// factory afresh with none) whose process owns the home's session lock reads
// the channel, and only while config/console-submit exists. The lock answer is
// bin/fm-session-lock-lib.sh's fm_session_lock_owned_by_self, asked again only
// when the lock content changes, exactly as the console journal asks it.
//
// Delivery. Every 500 ms the owner lists queue/, refuses expired or invalid
// messages, and hands the rest over in seq order. A message is claimed by
// renaming it to inflight/<id>@<pid>.json; the pid in the name is what lets
// the script's status sweep tell a live handoff from one whose process died.
// The idle-or-busy choice is made synchronously right before the send: idle
// with nothing outstanding uses the prompt path and then holds every later
// message until that one is read; busy uses a follow-up and keeps going. A
// message that cannot be sent in order goes back to queue/ unsent.
//
// Read. A handoff is delivered at the user message_start with its exact text
// (first handoff first, so equal texts keep their order), or, for a prompt
// whose text omp rewrote, when the run it started settles. A follow-up that is
// not read while the session is idle with nothing queued, for two polls, was
// withdrawn.
//
// Session end. omp gives session_shutdown no reason, so handoffs are left in
// inflight/ under this pid. The next owning session in this process adopts
// them, and one from a dead process is renamed to this pid first. The handoff
// stamp is written into the record before the send, so a record without one
// was never sent and goes back to queue/. A stamped one is delivered when the
// session branch already holds its text at or after its handoff, or when omp
// reads it later because omp kept it across the change, and is otherwise
// refused as session-ended once the session is idle with nothing queued; a
// dead process's handoff is never waited for.
//
// Never blocking. All file work is asynchronous behind a single-flight tick,
// every handler and the timer catch everything, and nothing reaches omp but
// sendUserMessage.
import { createHash, randomBytes } from "node:crypto";
import { constants } from "node:fs";
import { chmod, lstat, mkdir, open, readdir, readFile, rename, stat, unlink, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { runCommandAsync } from "../../.pi/extensions/lib/fm-async-exec.ts";

type Handler = (event: unknown, ctx: unknown) => unknown;

// The omp extension API surface this file uses, declared locally: omp ships no
// separately installable type package.
type ExtensionAPI = {
  on?: (event: string, handler: Handler) => void;
  sendUserMessage?: (content: string, options?: { deliverAs?: "followUp" }) => unknown;
};

type Via = "prompt" | "followUp";
type Fields = Record<string, unknown>;

type Message = {
  id: string;
  path: string;
  seq: number;
  createdAt: number;
  text: string;
  record: Fields;
};

type Handoff = {
  id: string;
  path: string;
  text: string;
  via: Via;
  handedAt: number;
  started: boolean;
  inherited: boolean;
};

type Generation = {
  token: string;
  ctx: Fields;
  stopped: boolean;
  timer: NodeJS.Timeout | undefined;
  ticking: boolean;
  recovered: boolean;
  published: boolean;
  handoffs: Handoff[];
};

const MESSAGE_SCHEMA = "fm-console-submit.v1";
const RECEIPT_SCHEMA = "fm-console-submit-receipt.v1";
const CONSUMER_SCHEMA = "fm-console-submit-consumer.v1";
const MESSAGE_MAX_BYTES = 16 * 1024;
const RECORD_READ_MAX = 64 * 1024;
const TTL_MS = 15 * 60_000;
const QUEUE_READ_MAX = 64;
const BRANCH_SCAN_MAX = 200;
const HANDOFF_CLOCK_SLACK_MS = 1000;
const QUEUE_NAME = /^([A-Za-z0-9][A-Za-z0-9._-]{0,63})\.json$/;
const INFLIGHT_NAME = /^([A-Za-z0-9][A-Za-z0-9._-]{0,63})@([0-9]{1,10})\.json$/;
const SHA256 = /^[0-9a-f]{64}$/;

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const lockLibrary = `${fmRoot}/bin/fm-session-lock-lib.sh`;
const lockPath = `${state}/.lock`;
const flagPath = `${config}/console-submit`;
const channelDir = `${state}/console-submit`;
const queueDir = `${channelDir}/queue`;
const inflightDir = `${channelDir}/inflight`;
const receiptsDir = `${channelDir}/receipts`;
const tmpDir = `${channelDir}/.tmp`;
const consumerPath = `${channelDir}/consumer.json`;
// Test seam, honored only inside the test suite: a shorter poll.
const seamPoll = process.env.FM_TEST_SEAM === "1" ? Number(process.env.FM_TEST_CONSOLE_SUBMIT_POLL_MS) : NaN;
const POLL_MS = Number.isInteger(seamPoll) && seamPoll > 0 ? seamPoll : 500;
const WITHDRAW_GRACE_MS = 2 * POLL_MS;
const myPid = String(process.pid);
const myUid = typeof process.getuid === "function" ? process.getuid() : null;

function isRecord(value: unknown): value is Fields {
  return typeof value === "object" && value !== null;
}

function errorCode(error: unknown): string {
  return isRecord(error) && typeof error.code === "string" ? error.code : "";
}

function iso(ms: number): string {
  return new Date(ms).toISOString();
}

// The text omp carries in a user message: a string, or its text parts joined.
function messageText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const part of content) {
    if (isRecord(part) && part.type === "text" && typeof part.text === "string") parts.push(part.text);
  }
  return parts.join("\n");
}

function captainMessage(message: unknown): message is Fields {
  return isRecord(message) && message.role === "user" && message.attribution !== "agent" && message.synthetic !== true;
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch (error) {
    return errorCode(error) === "EPERM";
  }
}

// The session lock names a local pid or, on Windows, a tagged `win:<pid>`
// (fm_session_pid_valid in bin/fm-session-lock-lib.sh owns that shape).
function lockHolderPid(lockPid: string): string {
  const tagged = process.platform === "win32" ? /^win:([0-9]+)$/.exec(lockPid) : null;
  const pid = tagged ? tagged[1] : lockPid;
  return /^[0-9]+$/.test(pid) && pid !== "1" ? pid : "";
}

// A ctx method's boolean answer, or undefined when omp does not offer it or
// the session behind the context is gone.
function ask(ctx: Fields, name: "isIdle" | "hasPendingMessages"): boolean | undefined {
  try {
    const method = ctx[name];
    const answer: unknown = typeof method === "function" ? method.call(ctx) : undefined;
    return typeof answer === "boolean" ? answer : undefined;
  } catch {
    return undefined;
  }
}

function sessionId(ctx: Fields): string | null {
  try {
    const manager = ctx.sessionManager;
    const id: unknown = isRecord(manager) && typeof manager.getSessionId === "function" ? manager.getSessionId.call(manager) : null;
    return typeof id === "string" ? id : null;
  } catch {
    return null;
  }
}

// The omp message time of the newest user message on the active branch that
// carries `text` and was stored at or after the handoff, if any.
function branchDelivery(ctx: Fields, text: string, handedAt: number): number | null {
  let branch: unknown;
  try {
    const manager = ctx.sessionManager;
    branch = isRecord(manager) && typeof manager.getBranch === "function" ? manager.getBranch.call(manager) : null;
  } catch {
    return null;
  }
  if (!Array.isArray(branch)) return null;
  for (let index = branch.length - 1, seen = 0; index >= 0 && seen < BRANCH_SCAN_MAX; index -= 1, seen += 1) {
    const entry: unknown = branch[index];
    if (!isRecord(entry) || entry.type !== "message" || !captainMessage(entry.message)) continue;
    const at = typeof entry.message.timestamp === "number" ? entry.message.timestamp : NaN;
    if (Number.isFinite(at) && at >= handedAt - HANDOFF_CLOCK_SLACK_MS && messageText(entry.message.content) === text) return at;
  }
  return null;
}

// ---- Files --------------------------------------------------------------

async function readPrivate(path: string, limit: number): Promise<string | null> {
  try {
    const info = await lstat(path);
    if (!info.isFile() || info.size > limit || (myUid !== null && info.uid !== myUid)) return null;
    const handle = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
    try {
      return await handle.readFile("utf8");
    } finally {
      await handle.close();
    }
  } catch {
    return null;
  }
}

async function readJson(path: string, limit = RECORD_READ_MAX): Promise<Fields | null> {
  const text = await readPrivate(path, limit);
  if (text === null) return null;
  try {
    const value: unknown = JSON.parse(text);
    return isRecord(value) && !Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
}

async function writePrivate(path: string, value: Fields): Promise<void> {
  const tmp = `${tmpDir}/w-${myPid}-${randomBytes(8).toString("hex")}`;
  await writeFile(tmp, `${JSON.stringify(value)}\n`, { mode: 0o600, flag: "wx" });
  try {
    await rename(tmp, path);
  } catch (error) {
    await unlinkQuiet(tmp);
    throw error;
  }
}

async function unlinkQuiet(path: string): Promise<void> {
  try {
    await unlink(path);
  } catch {
    // Already gone, or not ours to remove.
  }
}

async function privateDir(path: string): Promise<void> {
  try {
    await mkdir(path, { mode: 0o700 });
  } catch (error) {
    if (errorCode(error) !== "EEXIST") throw error;
  }
  const info = await lstat(path);
  if (!info.isDirectory() || (myUid !== null && info.uid !== myUid)) throw new Error(`${path} is not this user's directory`);
  if ((info.mode & 0o077) !== 0) await chmod(path, 0o700);
}

async function ensureLayout(): Promise<void> {
  for (const path of [channelDir, queueDir, inflightDir, receiptsDir, tmpDir]) await privateDir(path);
}

// The flag is present when its path exists, as for bin/fm-console-submit.py.
async function flagPresent(): Promise<boolean> {
  try {
    await stat(flagPath);
    return true;
  } catch {
    return false;
  }
}

async function listNames(dir: string, pattern: RegExp): Promise<RegExpExecArray[]> {
  let names: string[];
  try {
    names = await readdir(dir);
  } catch {
    return [];
  }
  return names
    .sort()
    .map((name) => pattern.exec(name))
    .filter((match): match is RegExpExecArray => match !== null);
}

async function readReceipt(id: string): Promise<Fields | null> {
  const value = await readJson(`${receiptsDir}/${id}.json`);
  return value && value.schema === RECEIPT_SCHEMA && value.id === id ? value : null;
}

// Settle a still-queued receipt; a final one is never rewritten.
async function settleReceipt(id: string, fields: Fields): Promise<void> {
  const current = await readReceipt(id);
  if (!current || current.state !== "queued") return;
  await writePrivate(`${receiptsDir}/${id}.json`, { ...current, ...fields, updated_at: iso(Date.now()) });
}

// ---- Factory ------------------------------------------------------------

export default function (pi: ExtensionAPI): void {
  let current: Generation | null = null;
  // Ownership answers keyed by the exact lock content they were computed for.
  let ownedLock = "";
  let negativeLock = "";

  const live = (g: Generation): boolean => current === g && !g.stopped;

  async function owns(): Promise<boolean> {
    let lockPid = "";
    try {
      lockPid = (await readFile(lockPath, "utf8")).trim();
    } catch {
      return false;
    }
    const holder = lockHolderPid(lockPid);
    if (!holder) return false;
    if (ownedLock === lockPid && pidAlive(holder)) return true;
    if (negativeLock === lockPid) return false;
    const answer = await runCommandAsync("bash", [
      "-c",
      '. "$1" && fm_session_lock_owned_by_self "$2"',
      "fm-console-submit",
      lockLibrary,
      state,
    ]);
    if (answer.status === 0) {
      ownedLock = lockPid;
      negativeLock = "";
      return true;
    }
    ownedLock = "";
    if (holder !== myPid) negativeLock = lockPid;
    return false;
  }

  async function finish(g: Generation, handoff: Handoff, fields: Fields): Promise<void> {
    const index = g.handoffs.indexOf(handoff);
    if (index < 0) return;
    g.handoffs.splice(index, 1);
    await settleReceipt(handoff.id, fields);
    await unlinkQuiet(handoff.path);
  }

  function delivered(g: Generation, handoff: Handoff, at: number): Promise<void> {
    return finish(g, handoff, {
      state: "delivered",
      reason: null,
      delivered_at: iso(at),
      session_id: sessionId(g.ctx),
      via: handoff.via,
    });
  }

  function refused(g: Generation, handoff: Handoff, reason: string): Promise<void> {
    return finish(g, handoff, { state: "refused", reason });
  }

  // Refuse a message still in queue/ after claiming it, so nothing else acts.
  async function refuseQueued(id: string, path: string, reason: string): Promise<void> {
    const claimed = `${tmpDir}/c-${myPid}-${randomBytes(8).toString("hex")}`;
    try {
      await rename(path, claimed);
    } catch {
      return;
    }
    await settleReceipt(id, { state: "refused", reason });
    await unlinkQuiet(claimed);
  }

  async function loadMessage(id: string, path: string): Promise<Message | null> {
    const record = await readJson(path, MESSAGE_MAX_BYTES);
    if (!record || record.schema !== MESSAGE_SCHEMA || record.id !== id) return null;
    const { seq, text } = record;
    const createdAt = typeof record.created_at === "string" ? Date.parse(record.created_at) : NaN;
    if (typeof seq !== "number" || !Number.isSafeInteger(seq) || seq < 1 || !Number.isFinite(createdAt)) return null;
    if (typeof text !== "string" || text.trim() === "" || typeof record.sha256 !== "string" || !SHA256.test(record.sha256)) return null;
    if (createHash("sha256").update(text, "utf8").digest("hex") !== record.sha256) return null;
    const receipt = await readReceipt(id);
    if (!receipt || receipt.state !== "queued" || receipt.sha256 !== record.sha256) return null;
    return { id, path, seq, createdAt, text, record };
  }

  // Adopt handoffs an earlier session left behind (see the header).
  async function recover(g: Generation): Promise<void> {
    for (const match of await listNames(inflightDir, INFLIGHT_NAME)) {
      if (!live(g)) return;
      const [name, id, pid] = match;
      if (pid !== myPid && pidAlive(pid)) continue;
      let path = `${inflightDir}/${name}`;
      if (g.handoffs.some((handoff) => handoff.path === path)) continue;
      if (pid !== myPid) {
        const adopted = `${inflightDir}/${id}@${myPid}.json`;
        try {
          await rename(path, adopted);
        } catch {
          continue;
        }
        path = adopted;
      }
      const record = await readJson(path, RECORD_READ_MAX);
      const meta = record && isRecord(record.handoff) ? record.handoff : null;
      // The handoff record is written before the send, so one without it was
      // never sent and goes back to the queue.
      if (record && !meta) {
        await rename(path, `${queueDir}/${id}.json`).catch(() => undefined);
        continue;
      }
      const handedAt = meta && typeof meta.handed_at === "string" ? Date.parse(meta.handed_at) : NaN;
      const handoff: Handoff = {
        id,
        path,
        text: record && typeof record.text === "string" ? record.text : "",
        via: meta && meta.via === "prompt" ? "prompt" : "followUp",
        handedAt: Number.isFinite(handedAt) ? handedAt : 0,
        started: false,
        inherited: true,
      };
      g.handoffs.push(handoff);
      const at = handoff.text && Number.isFinite(handedAt) ? branchDelivery(g.ctx, handoff.text, handedAt) : null;
      if (at !== null) await delivered(g, handoff, at);
      else if (pid !== myPid || !handoff.text) await refused(g, handoff, "session-ended");
    }
  }

  // A follow-up neither read nor queued while the session is idle was taken
  // back; an adopted handoff in that position will never be read.
  async function resolveUnread(g: Generation): Promise<void> {
    if (ask(g.ctx, "isIdle") !== true || ask(g.ctx, "hasPendingMessages") !== false) return;
    const now = Date.now();
    for (const handoff of [...g.handoffs]) {
      if (handoff.via === "prompt" && !handoff.inherited) continue;
      if (now - handoff.handedAt < WITHDRAW_GRACE_MS) continue;
      await refused(g, handoff, handoff.inherited ? "session-ended" : "withdrawn");
    }
  }

  async function publishConsumer(g: Generation): Promise<void> {
    await writePrivate(consumerPath, {
      schema: CONSUMER_SCHEMA,
      pid: process.pid,
      token: g.token,
      session_id: sessionId(g.ctx),
      since: iso(Date.now()),
    });
    g.published = true;
  }

  // How a message may be handed over right now, or null when it must wait:
  // an idle session takes a prompt only with nothing outstanding, a busy one
  // takes follow-ups unless a prompt is still starting.
  function choose(g: Generation): Via | null {
    const idle = ask(g.ctx, "isIdle");
    if (!live(g) || idle === undefined || g.handoffs.some((handoff) => handoff.via === "prompt")) return null;
    if (!idle) return "followUp";
    return g.handoffs.length === 0 ? "prompt" : null;
  }

  // Claim one message and hand it to omp. Returns false when nothing further
  // may be handed over during this pass.
  async function hand(g: Generation, message: Message): Promise<boolean> {
    const via = choose(g);
    if (!via) return false;
    const path = `${inflightDir}/${message.id}@${myPid}.json`;
    try {
      await rename(message.path, path);
    } catch {
      return true;
    }
    const handedAt = Date.now();
    const handoff: Handoff = { id: message.id, path, text: message.text, via, handedAt, started: false, inherited: false };
    try {
      await writePrivate(path, {
        ...message.record,
        handoff: { pid: process.pid, token: g.token, via, handed_at: iso(handedAt), session_id: sessionId(g.ctx) },
      });
    } catch {
      await rename(path, message.path).catch(() => undefined);
      return false;
    }
    // Decided again synchronously right before the send: nothing awaits
    // between this check and sendUserMessage.
    if (choose(g) !== via) {
      await rename(path, message.path).catch(() => undefined);
      return false;
    }
    g.handoffs.push(handoff);
    try {
      if (typeof pi.sendUserMessage !== "function") throw new Error("sendUserMessage is unavailable");
      if (via === "followUp") pi.sendUserMessage(message.text, { deliverAs: "followUp" });
      else pi.sendUserMessage(message.text);
    } catch {
      await refused(g, handoff, "harness-error");
      return true;
    }
    return via === "followUp";
  }

  async function deliverQueued(g: Generation): Promise<void> {
    const messages: Message[] = [];
    for (const match of (await listNames(queueDir, QUEUE_NAME)).slice(0, QUEUE_READ_MAX)) {
      const [name, id] = match;
      const path = `${queueDir}/${name}`;
      const message = await loadMessage(id, path);
      if (message) messages.push(message);
      else await refuseQueued(id, path, "invalid");
    }
    messages.sort((a, b) => a.seq - b.seq || a.createdAt - b.createdAt || (a.id < b.id ? -1 : 1));
    let open = true;
    for (const message of messages) {
      if (!live(g)) return;
      if (Date.now() - message.createdAt >= TTL_MS) await refuseQueued(message.id, message.path, "expired");
      else if (open) open = await hand(g, message);
    }
  }

  async function tick(g: Generation): Promise<void> {
    if (g.ticking || !live(g)) return;
    g.ticking = true;
    try {
      await resolveUnread(g);
      if (!(await flagPresent()) || !live(g) || !(await owns()) || !live(g)) return;
      await ensureLayout();
      if (!g.recovered) {
        await recover(g);
        g.recovered = true;
      }
      if (!g.published && live(g)) await publishConsumer(g);
      if (live(g)) await deliverQueued(g);
    } catch {
      // Never reaches omp; the next poll tries again.
    } finally {
      g.ticking = false;
    }
  }

  function poke(g: Generation | null): void {
    if (g) void tick(g).catch(() => undefined);
  }

  async function stop(g: Generation): Promise<void> {
    g.stopped = true;
    clearInterval(g.timer);
    g.timer = undefined;
    if (!g.published) return;
    const record = await readJson(consumerPath);
    if (record && record.pid === process.pid && record.token === g.token) await unlinkQuiet(consumerPath);
  }

  // Each omp event, guarded so nothing here can throw into omp.
  function on(name: string, handle: (event: unknown, ctx: unknown) => unknown): void {
    pi.on?.(name, (event: unknown, ctx: unknown) => {
      try {
        const result = handle(event, ctx);
        if (result instanceof Promise) return result.catch(() => undefined);
        return result;
      } catch {
        return undefined;
      }
    });
  }

  on("session_start", (_event, ctx) => {
    const previous = current;
    current = null;
    if (previous) void stop(previous).catch(() => undefined);
    if (!isRecord(ctx) || ctx.hasUI !== true) return undefined;
    const g: Generation = {
      token: randomBytes(8).toString("hex"),
      ctx,
      stopped: false,
      timer: undefined,
      ticking: false,
      recovered: false,
      published: false,
      handoffs: [],
    };
    current = g;
    g.timer = setInterval(() => poke(g), POLL_MS);
    g.timer.unref?.();
    poke(g);
    return undefined;
  });

  on("session_shutdown", async () => {
    const g = current;
    current = null;
    if (g) await stop(g);
  });

  on("message_start", (event) => {
    const g = current;
    const message = isRecord(event) ? event.message : null;
    if (!g || !live(g) || !captainMessage(message)) return undefined;
    const text = messageText(message.content);
    const handoff = g.handoffs.find((candidate) => candidate.text === text);
    if (!handoff) return undefined;
    const at = typeof message.timestamp === "number" && Number.isFinite(message.timestamp) ? message.timestamp : Date.now();
    void delivered(g, handoff, at).then(() => poke(g), () => undefined);
    return undefined;
  });

  on("agent_start", () => {
    const g = current;
    if (!g || !live(g)) return undefined;
    for (const handoff of g.handoffs) if (handoff.via === "prompt") handoff.started = true;
    return undefined;
  });

  on("agent_end", (event) => {
    const g = current;
    if (!g || !live(g) || (isRecord(event) && event.willContinue === true)) return undefined;
    const settled = g.handoffs.filter((handoff) => handoff.via === "prompt" && handoff.started);
    void Promise.all(settled.map((handoff) => delivered(g, handoff, handoff.handedAt))).then(() => poke(g), () => undefined);
    return undefined;
  });
}
