# Pi console journal

`.pi/extensions/fm-console-bridge.ts` publishes a read-only, bounded projection of the lock-owning Pi primary's main conversation for a same-user reader such as a console UI.
It is not a way to send anything to Firstmate: input keeps going through `bin/fm-inbox.sh`, and the journal's own metadata says so.
This page owns the published contract (`fm-console-journal.v1`); the extension's header comment owns how the extension keeps it.

## Scope

- Only Pi and Pi-signed primaries publish it, because both load the tracked `.pi/extensions/`; every other primary harness publishes nothing.
- Only the main conversation is projected: the away-posture supervision branch runs without extensions and never appears.
- `current.json` always carries `"capabilities": {"journal": true, "submit": false}`, so a reader must not infer any sending path from the journal's presence.
- There are no request, claim, or result files and no delivery acknowledgement of any kind.
- Text records are the prose the captain and the assistant already see in the terminal; the projection excludes the classes listed under [Projection and privacy](#projection-and-privacy) but is not a secrets filter.

## Who writes

- Only the Pi process whose ancestry holds the home's session lock writes, by the same ancestry rule as the watcher extension.
- A Pi session started inside that primary, recognised by the live primary recorded in `current.json` appearing in its ancestry, writes nothing; before the primary has published once, such a session cannot be told apart from it.
- A fresh primary takes the session lock during its first run, so its journal can open at the first run boundary instead of at session start.
- Every other process that loads the extension, such as a Pi worker or an ad hoc Pi in the home, reads `state/.lock` (and, when the lock's content changed, `current.json` and its own process ancestry) and never creates, writes, or deletes anything.
- The extension registers only event handlers: no tool, command, event-bus channel, sent message, or session entry.

## Location and access

- The directory is `<state>/extensions/pi-console-bridge/`, where `<state>` is `FM_STATE_OVERRIDE` or `$FM_HOME/state`, created with mode 0700.
- It holds `current.json`, journals named `<gen>.jsonl` with `<gen>` 32 lowercase hex digits, and short-lived `current.json.tmp-<pid>-<n>` files, all mode 0600.
- A reader accepts the directory only as `<configured home>/state/extensions/pi-console-bridge`, refuses a symlink at the directory or at any file it opens, and accepts only journal names matching `^[0-9a-f]{32}\.jsonl$`.

## `current.json`

One JSON object, replaced atomically by writing a temporary file and renaming it, always well under 64 KiB:

```json
{"schema":"fm-console-journal.v1","capabilities":{"journal":true,"submit":false},"harness":"pi","home":"/abs/home","lockPid":"1262363","piPid":1262375,"sessionId":"01a18f31-f3ed-713b-a4f3-5090e8bf05d8","conversation":"2026-10-30T23-42-58-029Z_01a18f31-f3ed-713b-a4f3-5090e8bf05d8.jsonl","gen":"cac50f54afceb84419a19633857a1d0a","previousGen":"7d3445b1961e8bbccbdc34ab78802080","startedReason":"reload","journal":"cac50f54afceb84419a19633857a1d0a.jsonl","state":"live","stoppedReason":null,"updatedAt":"2026-10-30T23:42:59.382Z"}
```

| Field | Meaning |
|---|---|
| `schema` | Always `fm-console-journal.v1`. |
| `capabilities` | Always journal true, submit false. |
| `harness` | Always `pi`, for Pi-signed too. |
| `home` | Real path of the Firstmate home. |
| `lockPid` | The session lock's content when ownership was established, as a string. |
| `piPid` | The writing Pi process. |
| `sessionId`, `conversation` | Pi's session id and the base name of its session file, or null for an unsaved session; identity only, never a path to open. |
| `gen`, `journal` | The current generation and its journal file name. |
| `previousGen` | The generation this record replaced, or null. |
| `startedReason` | Pi's session start reason (`startup`, `reload`, `new`, `resume`, `fork`), or `activate` (ownership established after session start), `tree` (branch change), `rotate` (size cap), `resync` (after a backpressure loss), or `recover` (after a write failure). |
| `state` | `live`, `stopped`, `failed`, or `lost`. |
| `stoppedReason` | Null while live; otherwise Pi's shutdown reason (`quit`, `reload`, `new`, `resume`, `fork`), `lock-lost`, `backpressure`, or `write-error:<CODE>`. |

`live` is meaningful only while `piPid` is alive and `lockPid` equals the session lock's pid: a Pi killed without a shutdown leaves `live` behind, and every later status update is best effort.

## Journal records

A journal is append-only, one JSON object per LF-terminated line, each line at most 65536 bytes including its LF.
Every record has `seq` (1, then exactly one more each record), `gen`, `at` (ISO time the projected event happened), and `type`.

| `type` | Fields | Meaning |
|---|---|---|
| `snapshot` | `reason`, `sessionId`, `conversation`, `leafId`, `busy`, `items`, `omittedBefore`, `truncatedItems` | Always the first record: the newest projected messages on the active branch. |
| `run` | `state` (`started`, `settled`), `aborted` on settled | A run began after idle, or Pi has no automatic work left. |
| `message` | `phase` (`start`, `end`), `msg`, `role`, plus `text`, `truncated`, `opKind`, `stopReason` as below | Message boundaries. |
| `delta` | `msg`, `block`, `text` | Coalesced streamed assistant text for one content block. |
| `tool` | `phase` (`start`, `end`), `tool`, `name`, plus `isError` and `durationMs` on end | A tool call's name, state, and timing only. |
| `gap` | `reason` (`backpressure`, `build-error`), `droppedRecords` | Records were lost; for backpressure it is the journal's last record and the count is a lower bound. |
| `stopped` | `reason` | The generation's runtime stopped; the journal's last record. |

- `msg` (`m<n>`) and `tool` (`t<n>`) are ordinals within the generation, never Pi's own ids.
- An assistant message has `start`, then any `delta` records, then `end` with `text` and `stopReason`.
- A user message has only `end`, with `role` `captain` and `text`, `operational` and `opKind`, or `withheld` and no text.
- `end` is authoritative: a reader replaces the text it rebuilt from deltas with it.
- A snapshot item is `{entry, role, text?, opKind?, truncated?, stopReason?}`, where `entry` is Pi's session entry id; assistant items appear only when they have visible text or stopped with `error` or `aborted`.
- `omittedBefore` counts older projected messages on the branch that the snapshot leaves out; history before the snapshot is not exposed.

## Projection and privacy

- User input is classified by `bin/fm-operational-input.sh classify`, the same current-plus-legacy rule the supervision branch uses for main's dialog: a classified message keeps only its kind, anything else is captain text, and input the classifier cannot answer for is withheld.
- Assistant text is its text blocks joined with newlines; a user image becomes `[image]`.
- Nothing else reaches disk: no thinking, tool arguments, partial or final tool results, tool call ids, system, custom, shell, compaction, or branch-summary messages, provider error messages, usage, or session file paths.
- Tool calls a tool makes through another tool (`parentToolCallId`) are not journalled.

## Bounds

The earlier proposal's 50 snapshot messages at 32 KiB each cannot fit one 64 KiB record, so the snapshot is budgeted as a whole:

| Bound | Value |
|---|---|
| Record, including LF | 64 KiB |
| Snapshot | the newest 50 projected messages; at most 4 KiB of text each and 48 KiB in total, given to the newest first; items left without budget keep their role and metadata with `truncated: true`; oldest items are dropped into `omittedBefore` if the record would still be too large |
| Message text | 32 KiB per message across its deltas and in its `end`, which then has `truncated: true` |
| Delta record text | 16 KiB; deltas flush every 200 ms or at 4 KiB |
| Generation journal | 8 MiB, then a new generation (`rotate`) |
| Kept journals | the current one and the previous one |
| Unwritten records in memory | 1 MiB per generation |

Every text budget counts the UTF-8 bytes of the JSON-escaped form, so escaping cannot push a record past its bound.

## Generations

A new generation, with a new snapshot, opens at every owned session start, when ownership is established later, when the active leaf leaves the journalled branch or brings dialog the generation never streamed (a `/tree` move), at the size cap, after a backpressure loss, and when recovering from a write failure.
A generation opened during a run has `busy: true` and announces the streaming message and running tools again with fresh ordinals.
Records are never replayed across generations.
Publishing a generation deletes only the journal that the replaced `current.json` named as its own `previousGen`, after checking it is a regular file owned by the same user; any other file in the directory is left alone, including journals a crashed process never replaced.

## Failure behavior

- If unwritten records pass 1 MiB, the generation drops them, ends its journal with a backpressure `gap`, marks `current.json` `lost`, and opens a `resync` generation once the writer has drained.
- A write failure marks the generation `failed` (`write-error:<CODE>` when `current.json` can still be written), and the next settled run attempts a `recover` generation.
- A disk that stops answering stalls only the journal: the extension keeps at most one filesystem operation in flight, its memory stays bounded, and Pi's turns continue.
- Shutdown waits at most 250 ms for the stop record and the `stopped` state.

## Reader rules

1. Read `current.json` (lstat, at most 64 KiB) and accept it only when `schema`, `harness`, `home`, and `lockPid` match what the reader expects for that home.
2. Open its `journal`; the first record must be a `snapshot` with `seq` 1 and the same `gen`.
3. Read only complete lines and check that each has the current `gen` and the next `seq`.
4. Start again from the current generation's snapshot on a generation change, a `seq` gap, an unparsable complete line, a journal that shrank or vanished, or a `gap` record.
5. When `state` is not `live`, show the conversation as stopped with `stoppedReason`.

## Verification

- [`tests/fm-pi-console-bridge.test.sh`](../tests/fm-pi-console-bridge.test.sh) covers ownership, ordering, privacy, bounds, generations, retention, backpressure, and write failures through the extension's factory.
- [`tests/fm-pi-console-bridge-live-e2e.test.sh`](../tests/fm-pi-console-bridge-live-e2e.test.sh) is the token-free live guard that proves the Pi event payloads against the installed Pi.
- [`tests/fm-pi-primary-types.test.sh`](../tests/fm-pi-primary-types.test.sh) includes the extension in the strict typecheck.
