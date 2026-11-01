# Console submit channel

`fm-console-submit.v1` is the opt-in channel a same-user console, such as Astro's FirstMate page, uses to put the captain's own message into the omp primary's conversation as an ordinary user turn.
The answer needs no second channel: the read-only [console journal](pi-console-journal.md) streams it back like any other reply.
This page owns the contract; [`bin/fm-console-submit.sh`](../bin/fm-console-submit.sh)'s header owns the command line and exit codes, and [`.omp/extensions/fm-console-submit.ts`](../.omp/extensions/fm-console-submit.ts)'s header owns how the omp primary keeps the contract.

## Scope and opt-in

- The local, gitignored `config/console-submit` presence flag enables the channel for one home on one machine; it is off by default and a secondmate home does not inherit it.
- A console sets the flag the same way it sends: when the captain links a home to it and turns sending on, the console runs `FM_HOME=<home> bin/fm-console-submit.sh enable`, and turning sending off runs `disable`; both are idempotent, answer with the `status` document, and refuse a flag path that is not a plain file rather than write through it.
- Linking a home to a console is not itself consent to send: nothing enables the channel unless that explicit step runs for that home.
- Without the flag `enqueue` refuses with `disabled` and the primary reads and delivers nothing.
- Removing the flag, by `disable` or by hand, is the kill switch: the primary stops reading within one 500 ms poll, a message already handed to omp is still reported, and queued messages wait under the TTL below until the flag returns.
- A running omp primary that has the extension loaded starts reading within one poll of the flag appearing, with no reload.
- Only an omp primary delivers: the extension loads in every omp session started in the home, and only the session with a UI whose process owns the home's session lock (`fm_session_lock_owned_by_self` in [`bin/fm-session-lock-lib.sh`](../bin/fm-session-lock-lib.sh), the journal's rule) reads the channel.
- Pi, Pi-signed, and every other primary harness read nothing, so a message sent while one of them is the primary waits and then expires.
- There is no network surface: the channel is files in the home's own state directory, written and read by the same OS user.

## Location and writers

The directory is `<home>/state/console-submit/`, mode 0700; every file in it is a regular file of mode 0600, and readers refuse symlinks and files another user owns.

| Path | Holds |
|---|---|
| `queue/<id>.json` | A message waiting to be handed to omp. |
| `inflight/<id>@<pid>.json` | A message handed to omp and not yet in the conversation; `<pid>` is the omp process that handed it. |
| `receipts/<id>.json` | The message's receipt. |
| `consumer.json` | The delivering omp process's pid and session id, while it owns the lock. |
| `.tmp/`, `.lock`, `.seq`, `.rate` | Private working files. |

- A console writes only by running `FM_HOME=<home> bin/fm-console-submit.sh enqueue` with the text on stdin, or `enable` and `disable` for the opt-in flag, never by creating files itself.
- After that only the delivering omp process and the script's `status` sweep change a message, and each first claims it with an atomic rename, so exactly one of them acts on it.

## Message

A queued file is one JSON object of at most 16 KiB: `schema` (`fm-console-submit.v1`), `id`, `seq`, `created_at`, `from`, `reply_to`, `text`, `sha256` and `bytes` of the text.

- `id` is 1 to 64 characters of `[A-Za-z0-9._-]` starting with a letter or digit, chosen by the console (a UUID fits), and is the idempotency key.
- `text` is valid UTF-8, not blank, free of control characters other than tab and line feed (no CR, DEL, or C1 characters), and not in Firstmate's operational-input form (`bin/fm-operational-input.sh` `classify` or `doorbell-kind`), so a console can never send what the primary would take for a watcher wake or other Firstmate input.
- `from` names the console, `astro` by default.
- `reply_to` is an optional console reference of up to 128 characters of `[A-Za-z0-9._:/-]`, such as the journal message being answered; it is copied to the receipt and never shown to the model.
- `seq` is the delivery order the script assigns; `created_at` starts the TTL.

## Delivery

- The model sees exactly `text` as a user message attributed to the user, with no prefix, label, or wrapper, and omp expands no slash command or prompt template in it, so `/new` arrives as the words `/new`.
- There is deliberately no origin prefix: the primary needs no origin to answer, because its reply reaches the console through the journal either way; a prefix would show as part of the captain's words in the terminal and in the journal; and the receipt already proves the origin.
- On an idle session the message is delivered at once as a new turn through omp's ordinary prompt path, as if the captain pressed Enter, which like typed input may rewrite a `^model` mention.
- On a busy session it is handed to omp as a follow-up (`deliverAs: "followUp"`), which omp shows as queued and puts into the conversation after the current turn, as if the captain queued it there; it never steers or interrupts the running turn.
- Messages go in `seq` order: while one is starting on an idle session nothing else is handed over, and follow-ups keep their order in omp's queue.
- Exactly once: a message moves from `queue/` to `inflight/` by one rename, is handed to omp once, and is never replayed.
- It counts as delivered when omp puts it into the conversation: the user message with its exact text starts, or, for an idle delivery whose text omp rewrote, the run it started settles.
- A message handed to omp is never handed again: when the session ends or is replaced before omp reads it, it still counts as delivered if omp reads it afterwards or the next session's branch already holds it, and is otherwise refused as `session-ended`, because omp may still hold it and a replay could deliver it twice.

## Receipts

`receipts/<id>.json` is one JSON object: `schema` (`fm-console-submit-receipt.v1`), `id`, `state`, `reason`, `created_at`, `updated_at`, `seq`, `from`, `reply_to`, `sha256`, `bytes`, and, once delivered, `delivered_at` (omp's message time, or the handoff time when omp rewrote the text), `session_id` (omp's session id), and `via` (`prompt` or `followUp`).

| `state` | `reason` | Meaning |
|---|---|---|
| `queued` | null | Accepted; waiting, or handed to omp and not yet in the conversation. |
| `delivered` | null | In the conversation. |
| `refused` | `expired` | Waited 15 minutes without being handed to a live primary. |
| `refused` | `withdrawn` | Handed as a follow-up, then taken back out of omp's queue at the terminal before omp read it (an interrupt returns queued messages to the editor). |
| `refused` | `session-ended` | Handed, then the omp session ended or was replaced, or its process exited, before omp read it. |
| `refused` | `invalid` | The queued file failed the primary's checks. |
| `refused` | `harness-error` | omp threw when the message was handed over. |

- `delivered` and `refused` are final; a final receipt is kept for 24 hours and its id stays reserved for that long.
- A refusal at `enqueue` (`disabled`, `invalid`, `too-large`, `operational-format`, `queue-full`, `rate-limited`, `id-conflict`) writes nothing: the script's JSON answer is the whole outcome, and except after `id-conflict` the same id may be sent again.
- The same id with the same text is a replay: the script returns the existing receipt and never queues a second message; the same id with different text is `id-conflict`.

## Bounds and no live session

| Bound | Value |
|---|---|
| Message file | 16 KiB |
| Messages queued or in flight | 20 |
| Accepted messages | 10 per rolling 60 seconds |
| Wait before `expired` | 15 minutes from `created_at` |
| Final receipts kept | 24 hours |

- With no live primary, messages stay queued; an omp primary that later takes the lock with the flag present delivers those still inside the TTL in order and refuses the older ones as `expired`.
- `status <id>` applies the TTL itself and refuses a handed message whose omp process is gone as `session-ended`, so a console sees a final state even when no session runs.
- `status` without an id reports whether the flag is present, whether a consumer is live (`consumer.json` names a live process that holds the session lock), the queued and in-flight counts, and these bounds.

## Journal correlation

- A delivered message is a plain user message, so the journal records it as `captain` text exactly as if it were typed, and the journal's `capabilities.submit` stays false because the journal itself is not a sending path.
- A console matches a receipt to its journal record by exact text at or after `delivered_at`; the journal carries no submit ids.

## Trust

- The channel gives a console exactly the authority of the captain typing into the primary's terminal and no more: anyone who can write the home's state as the same user can already do that.
- A console sends only text the captain typed into it and never forwards third-party text such as web pages, notifications, or another agent's output, because the primary treats every delivered message as the captain's own instruction.

## Verification

- [`tests/fm-console-submit.test.sh`](../tests/fm-console-submit.test.sh) covers the script's opt-in setup, validation, caps, idempotency, and sweeps, and the omp extension's ownership, idle and busy delivery, ordering, withdrawal, session end, and recovery through its factory with a fake omp host and synthetic omp 18.12.6 payloads.
- No live guard proves delivery against a real omp yet.
