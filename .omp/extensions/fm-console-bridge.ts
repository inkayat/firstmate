// Firstmate console journal for omp (Oh My Pi).
//
// omp is a Pi fork, so the omp primary journals through the same extension as
// Pi: .pi/extensions/fm-console-bridge.ts owns how the journal is kept and
// docs/pi-console-journal.md owns the published contract. This file only feeds
// that extension omp's events in the shape it reads from Pi, and is the single
// owner of the differences, read from omp 18.12.6's own source:
//   - omp has no agent_settled. agent_end whose willContinue is not true is
//     the settled run, and it settled aborted when its last assistant message
//     stopped as aborted.
//   - session_start and session_shutdown carry no reason, so the journal's own
//     fallbacks apply.
//   - An omp task subagent runs in this same process and binds this extension
//     afresh, with no UI. Only a session with a UI (ctx.hasUI) is the
//     conversation the captain sees, so a session without one forwards
//     nothing and never asks for the lock.
//   - message_update reaches extensions on a later microtask than the
//     surrounding events, so it can trail its message_end. A text delta is
//     forwarded only while its own assistant message is open, matched by the
//     message timestamp.
//   - A user-role message omp marks synthetic or attributes to the agent (its
//     own notes and summaries) is not captain input: it is not forwarded, and
//     the session view keeps it only as a non-dialog entry, so leaf tracking
//     still finds its id.
//   - omp may persist a finished message before this extension's message_end
//     handler runs. While a message_end is forwarded, the session view hides
//     that message, which keeps Pi's rule that a snapshot taken there excludes
//     the message whose record follows it.
//   - tool_execution_end carries no durationMs, so it is measured here between
//     the tool's start and end events.
// Everything else is forwarded unchanged, and the journal reaches omp only
// through these handlers: no message, entry, tool, command, or bus event.
import piConsoleJournal from "../../.pi/extensions/fm-console-bridge.ts";

type Handler = (event: unknown, ctx: unknown) => unknown;

// The omp extension API surface this file uses, declared locally: omp ships no
// separately installable type package.
type ExtensionAPI = {
  on?: (event: string, handler: (event: unknown, ctx: unknown) => unknown) => void;
};

const RUNNING_TOOLS_MAX = 64;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function messageOf(event: unknown): Record<string, unknown> | null {
  return isRecord(event) && isRecord(event.message) ? event.message : null;
}

function isMessageEntry(entry: unknown): entry is { id?: unknown; parentId?: unknown; message: Record<string, unknown> } {
  return isRecord(entry) && entry.type === "message" && isRecord(entry.message);
}

function agentAuthored(message: Record<string, unknown>): boolean {
  return message.role === "user" && (message.synthetic === true || message.attribution === "agent");
}

function lastAssistantAborted(event: unknown): boolean {
  const messages = isRecord(event) && Array.isArray(event.messages) ? event.messages : [];
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (isRecord(message) && message.role === "assistant") return message.stopReason === "aborted";
  }
  return false;
}

export default function (omp: ExtensionAPI): void {
  const journal = new Map<string, Handler>();
  // The Pi extension registers event handlers and nothing else (its header owns
  // that rule), so a surface with only `on` is all it can reach.
  const host = {
    on(name: string, handler: Handler) {
      journal.set(name, handler);
    },
  };
  piConsoleJournal(host as unknown as Parameters<typeof piConsoleJournal>[0]);

  let attached = false;
  let open: { timestamp: unknown } | null = null;
  let ending: Record<string, unknown> | null = null;
  const toolStarts = new Map<string, number>();

  // The session as the journal reads it from Pi: the same getters, with omp's
  // own user-role messages and the message being ended out of the dialog.
  function branchView(branch: unknown): unknown {
    if (!Array.isArray(branch)) return branch;
    let newest = -1;
    if (ending) {
      for (let index = branch.length - 1; index >= 0; index -= 1) {
        if (isMessageEntry(branch[index])) {
          newest = index;
          break;
        }
      }
    }
    return branch.map((entry, index) => {
      if (!isMessageEntry(entry)) return entry;
      const message = entry.message;
      const inFlight = index === newest && ending !== null && message.role === ending.role &&
        message.timestamp !== undefined && message.timestamp === ending.timestamp;
      return agentAuthored(message) || inFlight ? { id: entry.id, parentId: entry.parentId, type: "omp-hidden-message" } : entry;
    });
  }

  function view(ctx: unknown): unknown {
    const manager = isRecord(ctx) && isRecord(ctx.sessionManager) ? ctx.sessionManager : null;
    if (!manager) return null;
    const read = (name: string): unknown => {
      const getter = manager[name];
      return typeof getter === "function" ? getter.call(manager) : undefined;
    };
    return {
      sessionManager: {
        getSessionFile: () => read("getSessionFile"),
        getSessionId: () => read("getSessionId"),
        getLeafId: () => read("getLeafId"),
        getBranch: () => branchView(read("getBranch")),
      },
    };
  }

  function forward(name: string, event: unknown, ctx: unknown): unknown {
    const handler = journal.get(name);
    return handler ? handler(event, view(ctx)) : undefined;
  }

  // Each omp event, guarded so nothing here can throw into omp.
  function on(name: string, handle: (event: unknown, ctx: unknown) => unknown): void {
    omp.on?.(name, (event: unknown, ctx: unknown) => {
      try {
        return handle(event, ctx);
      } catch {
        return undefined;
      }
    });
  }

  function reset(): void {
    open = null;
    ending = null;
    toolStarts.clear();
  }

  on("session_start", (event, ctx) => {
    attached = isRecord(ctx) && ctx.hasUI === true;
    reset();
    return attached ? forward("session_start", event, ctx) : undefined;
  });

  on("session_shutdown", (event, ctx) => (attached ? forward("session_shutdown", event, ctx) : undefined));
  on("session_tree", (event, ctx) => (attached ? forward("session_tree", event, ctx) : undefined));
  on("agent_start", (event, ctx) => (attached ? forward("agent_start", event, ctx) : undefined));

  on("agent_end", (event, ctx) => {
    if (!attached || (isRecord(event) && event.willContinue === true)) return undefined;
    reset();
    return forward("agent_settled", { type: "agent_settled", aborted: lastAssistantAborted(event) }, ctx);
  });

  on("message_start", (event, ctx) => {
    if (!attached) return undefined;
    const message = messageOf(event);
    if (message?.role === "assistant") open = { timestamp: message.timestamp };
    return forward("message_start", event, ctx);
  });

  on("message_update", (event, ctx) => {
    if (!attached || !open) return undefined;
    const timestamp = messageOf(event)?.timestamp;
    if (open.timestamp !== undefined && timestamp !== undefined && timestamp !== open.timestamp) return undefined;
    return forward("message_update", event, ctx);
  });

  on("message_end", (event, ctx) => {
    if (!attached) return undefined;
    const message = messageOf(event);
    if (!message || agentAuthored(message)) return undefined;
    if (message.role === "assistant") open = null;
    ending = message;
    try {
      return forward("message_end", event, ctx);
    } finally {
      ending = null;
    }
  });

  on("tool_execution_start", (event, ctx) => {
    if (!attached) return undefined;
    const id = isRecord(event) ? event.toolCallId : undefined;
    if (typeof id === "string" && (toolStarts.size < RUNNING_TOOLS_MAX || toolStarts.has(id))) toolStarts.set(id, performance.now());
    return forward("tool_execution_start", event, ctx);
  });

  on("tool_execution_end", (event, ctx) => {
    if (!attached) return undefined;
    const id = isRecord(event) ? event.toolCallId : undefined;
    const started = typeof id === "string" ? toolStarts.get(id) : undefined;
    if (typeof id === "string") toolStarts.delete(id);
    const timed = started !== undefined && isRecord(event) && event.durationMs === undefined
      ? { ...event, durationMs: performance.now() - started }
      : event;
    return forward("tool_execution_end", timed, ctx);
  });
}
