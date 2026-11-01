#!/usr/bin/env python3
"""The engine behind bin/fm-console-submit.sh: validate and queue one console
message, and read or settle a receipt, in <state>/console-submit/.

bin/fm-console-submit.sh owns the command line, output, and exit codes; call
it, not this file. docs/console-submit.md owns the contract (fm-console-submit.v1);
the bounds below restate its numbers. The delivering side is
.omp/extensions/fm-console-submit.ts, which shares only the files: every
transition of a message is claimed with one atomic rename, so this script and
that extension never both act on the same message.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import time

try:
    import fcntl
except ImportError:  # pragma: no cover - native Windows Python
    fcntl = None

SCHEMA = "fm-console-submit.v1"
RECEIPT_SCHEMA = "fm-console-submit-receipt.v1"
RESULT_SCHEMA = "fm-console-submit-result.v1"
STATUS_SCHEMA = "fm-console-submit-status.v1"
MESSAGE_MAX_BYTES = 16 << 10
RECORD_READ_MAX = 64 << 10
QUEUE_MAX = 20
RATE_MAX = 10
RATE_WINDOW_MS = 60_000
TTL_MS = 15 * 60_000
RECEIPT_RETAIN_MS = 24 * 3_600_000
TMP_RETAIN_MS = 3_600_000
CLASSIFY_TIMEOUT = 10

ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
REPLY_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}\Z")
FROM_RE = re.compile(r"[a-z][a-z0-9-]{0,31}\Z")
QUEUE_NAME = re.compile(r"([A-Za-z0-9][A-Za-z0-9._-]{0,63})\.json\Z")
INFLIGHT_NAME = re.compile(r"([A-Za-z0-9][A-Za-z0-9._-]{0,63})@([0-9]{1,10})\.json\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")

EXIT_OK = 0
EXIT_FAIL = 1
EXIT_INVALID = 2
EXIT_DISABLED = 3
EXIT_UNKNOWN = 3
EXIT_RETRY = 4


class Failure(Exception):
    """An operational failure; the wrapper prints it and exits 1."""


def now_ms() -> int:
    # Test seam: a fixed clock, honored only inside the test suite.
    if os.environ.get("FM_TEST_SEAM") == "1":
        value = os.environ.get("FM_TEST_CONSOLE_SUBMIT_NOW_MS", "")
        if value.isdigit():
            return int(value)
    return int(time.time() * 1000)


def iso(ms: int) -> str:
    moment = datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc)
    return moment.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def parse_iso(value: object) -> int | None:
    if not isinstance(value, str):
        return None
    try:
        moment = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if moment.tzinfo is None:
        return None
    return int(moment.timestamp() * 1000)


def dumps(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def pid_alive(pid: int) -> bool:
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class Channel:
    def __init__(self, state: str, config: str, code_root: str) -> None:
        self.state = state
        self.config = config
        self.code_root = code_root
        self.root = os.path.join(state, "console-submit")
        self.queue = os.path.join(self.root, "queue")
        self.inflight = os.path.join(self.root, "inflight")
        self.receipts = os.path.join(self.root, "receipts")
        self.tmp = os.path.join(self.root, ".tmp")
        self.uid = os.getuid()

    # ---- filesystem primitives -------------------------------------------

    def enabled(self) -> bool:
        return os.path.exists(os.path.join(self.config, "console-submit"))

    def private_dir(self, path: str, create: bool) -> bool:
        if create:
            try:
                os.mkdir(path, 0o700)
            except FileExistsError:
                pass
        try:
            info = os.lstat(path)
        except FileNotFoundError:
            return False
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != self.uid:
            raise Failure(f"{path} is not a directory owned by this user")
        if info.st_mode & 0o077:
            os.chmod(path, 0o700)
        return True

    def layout(self, create: bool) -> bool:
        if not self.private_dir(self.root, create):
            return False
        for path in (self.queue, self.inflight, self.receipts, self.tmp):
            self.private_dir(path, True)
        return True

    def read_bytes(self, path: str, limit: int) -> bytes | None:
        """A regular file owned by this user, never through a symlink."""
        try:
            info = os.lstat(path)
        except FileNotFoundError:
            return None
        if not stat.S_ISREG(info.st_mode) or info.st_uid != self.uid or info.st_size > limit:
            return None
        try:
            fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        except OSError:
            return None
        with os.fdopen(fd, "rb") as handle:
            data = handle.read(limit + 1)
        return data if len(data) <= limit else None

    def read_json(self, path: str, limit: int = RECORD_READ_MAX) -> dict | None:
        data = self.read_bytes(path, limit)
        if data is None:
            return None
        try:
            value = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            return None
        return value if isinstance(value, dict) else None

    def write_tmp(self, data: bytes) -> str:
        path = os.path.join(self.tmp, f"w-{os.getpid()}-{secrets.token_hex(8)}")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        return path

    def replace(self, path: str, value: dict) -> None:
        tmp = self.write_tmp(dumps(value).encode("utf-8") + b"\n")
        try:
            os.replace(tmp, path)
        except OSError:
            self.unlink(tmp)
            raise

    @staticmethod
    def unlink(path: str) -> None:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass

    def claim(self, path: str) -> str | None:
        """Take a queued or in-flight file out of reach of every other actor."""
        claimed = os.path.join(self.tmp, f"c-{os.getpid()}-{secrets.token_hex(8)}")
        try:
            os.rename(path, claimed)
        except FileNotFoundError:
            return None
        return claimed

    def lock(self):
        if fcntl is None:
            raise Failure("file locking is unavailable on this platform")
        fd = os.open(os.path.join(self.root, ".lock"), os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        return fd

    # ---- records -----------------------------------------------------------

    def receipt_path(self, ident: str) -> str:
        return os.path.join(self.receipts, f"{ident}.json")

    def receipt(self, ident: str) -> dict | None:
        value = self.read_json(self.receipt_path(ident))
        if value is None or value.get("schema") != RECEIPT_SCHEMA or value.get("id") != ident:
            return None
        return value

    def finish(self, ident: str, claimed: str, reason: str) -> None:
        """Refuse a claimed message: settle its receipt, then drop the file."""
        current = self.receipt(ident)
        if current is not None and current.get("state") == "queued":
            current.update(state="refused", reason=reason, updated_at=iso(now_ms()))
            self.replace(self.receipt_path(ident), current)
        self.unlink(claimed)

    def inflight_entries(self) -> list[tuple[str, int, str]]:
        entries = []
        try:
            names = os.listdir(self.inflight)
        except FileNotFoundError:
            return entries
        for name in names:
            match = INFLIGHT_NAME.match(name)
            if match:
                entries.append((match.group(1), int(match.group(2)), os.path.join(self.inflight, name)))
        return entries

    def queued_ids(self) -> list[str]:
        try:
            names = os.listdir(self.queue)
        except FileNotFoundError:
            return []
        return [m.group(1) for m in (QUEUE_NAME.match(name) for name in names) if m]

    # ---- sweeps ------------------------------------------------------------

    def settle(self, ident: str, now: int) -> None:
        """Apply the dead-consumer rule and the TTL to one message."""
        current = self.receipt(ident)
        if current is None:
            return
        handed = [entry for entry in self.inflight_entries() if entry[0] == ident]
        live = False
        for _, pid, path in handed:
            if pid_alive(pid):
                live = True
                continue
            claimed = self.claim(path)
            if claimed:
                self.finish(ident, claimed, "session-ended")
        current = self.receipt(ident)
        if current is None or current.get("state") != "queued" or live:
            return
        created = parse_iso(current.get("created_at"))
        if created is not None and now - created < TTL_MS:
            return
        queued = os.path.join(self.queue, f"{ident}.json")
        if os.path.lexists(queued):
            claimed = self.claim(queued)
            if claimed:
                self.finish(ident, claimed, "expired")
        elif not handed:
            # Neither queued nor handed: an enqueue that stopped between its
            # receipt and its message. The lock excludes a running enqueue.
            current.update(state="refused", reason="expired", updated_at=iso(now))
            self.replace(self.receipt_path(ident), current)

    def sweep(self, now: int) -> None:
        for ident in self.queued_ids():
            self.settle(ident, now)
        for ident, pid, _ in self.inflight_entries():
            if not pid_alive(pid):
                self.settle(ident, now)
        pending = set(self.queued_ids()) | {entry[0] for entry in self.inflight_entries()}
        with os.scandir(self.receipts) as entries:
            for entry in entries:
                match = QUEUE_NAME.match(entry.name)
                if not match or match.group(1) in pending:
                    continue
                try:
                    info = entry.stat(follow_symlinks=False)
                except FileNotFoundError:
                    continue
                if now - int(info.st_mtime * 1000) >= RECEIPT_RETAIN_MS:
                    self.unlink(entry.path)
        with os.scandir(self.tmp) as entries:
            for entry in entries:
                try:
                    info = entry.stat(follow_symlinks=False)
                except FileNotFoundError:
                    continue
                if now - int(info.st_mtime * 1000) >= TMP_RETAIN_MS:
                    self.unlink(entry.path)

    # ---- validation --------------------------------------------------------

    def operational(self, raw: bytes) -> bool:
        script = os.path.join(self.code_root, "bin", "fm-operational-input.sh")
        for mode in ("classify", "doorbell-kind"):
            try:
                result = subprocess.run(
                    ["bash", script, mode],
                    input=raw,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=CLASSIFY_TIMEOUT,
                    check=False,
                )
            except (OSError, subprocess.TimeoutExpired) as error:
                raise Failure(f"could not classify the text: {error}") from error
            if result.returncode == 0:
                return True
            if result.returncode != 1:
                raise Failure(f"could not classify the text: {mode} exited {result.returncode}")
        return False


def forbidden_character(text: str) -> str | None:
    for char in text:
        code = ord(char)
        if char in "\n\t":
            continue
        if code < 0x20 or code == 0x7F or 0x80 <= code <= 0x9F:
            return f"U+{code:04X}"
    return None


def emit(value: dict) -> None:
    sys.stdout.write(dumps(value) + "\n")


def result(outcome: str, ident: str, reason: str | None, detail: str | None, receipt: dict | None) -> dict:
    return {
        "schema": RESULT_SCHEMA,
        "outcome": outcome,
        "id": ident,
        "reason": reason,
        "detail": detail,
        "receipt": receipt,
    }


def refuse(ident: str, reason: str, detail: str, code: int) -> int:
    emit(result("refused", ident, reason, detail, None))
    return code


def cmd_enqueue(channel: Channel, args: argparse.Namespace) -> int:
    ident = args.id or ""
    if not ID_RE.match(ident):
        return refuse(ident, "invalid", "id must be 1-64 characters of [A-Za-z0-9._-] starting with a letter or digit", EXIT_INVALID)
    if not FROM_RE.match(args.sender):
        return refuse(ident, "invalid", "from must be 1-32 characters of [a-z0-9-] starting with a letter", EXIT_INVALID)
    if args.reply_to is not None and not REPLY_RE.match(args.reply_to):
        return refuse(ident, "invalid", "reply-to must be 1-128 characters of [A-Za-z0-9._:/-] starting with a letter or digit", EXIT_INVALID)
    if not channel.enabled():
        return refuse(ident, "disabled", f"the console submit channel is off: create {os.path.join(channel.config, 'console-submit')} to enable it", EXIT_DISABLED)
    raw = sys.stdin.buffer.read(MESSAGE_MAX_BYTES + 1)
    if len(raw) > MESSAGE_MAX_BYTES:
        return refuse(ident, "too-large", f"the message must fit in {MESSAGE_MAX_BYTES} bytes", EXIT_INVALID)
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return refuse(ident, "invalid", "text is not valid UTF-8", EXIT_INVALID)
    if not text.strip():
        return refuse(ident, "invalid", "text is blank", EXIT_INVALID)
    bad = forbidden_character(text)
    if bad:
        return refuse(ident, "invalid", f"text contains the control character {bad}", EXIT_INVALID)
    if channel.operational(raw):
        return refuse(ident, "operational-format", "text is in Firstmate's operational-input form", EXIT_INVALID)
    digest = hashlib.sha256(raw).hexdigest()
    channel.layout(create=True)
    lock = channel.lock()
    try:
        now = now_ms()
        channel.sweep(now)
        existing = channel.receipt(ident)
        if existing is not None:
            if existing.get("sha256") == digest:
                emit(result("replay", ident, None, None, existing))
                return EXIT_OK
            return refuse(ident, "id-conflict", "this id was already used for a different text", EXIT_INVALID)
        if len(channel.queued_ids()) + len(channel.inflight_entries()) >= QUEUE_MAX:
            return refuse(ident, "queue-full", f"{QUEUE_MAX} messages are already waiting", EXIT_RETRY)
        rate_path = os.path.join(channel.root, ".rate")
        stamps = channel.read_json(rate_path) or {}
        recent = [t for t in stamps.get("accepted", []) if isinstance(t, int) and 0 <= now - t < RATE_WINDOW_MS]
        if len(recent) >= RATE_MAX:
            return refuse(ident, "rate-limited", f"at most {RATE_MAX} messages per {RATE_WINDOW_MS // 1000} seconds", EXIT_RETRY)
        seq_path = os.path.join(channel.root, ".seq")
        seq = int((channel.read_json(seq_path) or {}).get("last", 0) or 0) + 1
        message = {
            "schema": SCHEMA,
            "id": ident,
            "seq": seq,
            "created_at": iso(now),
            "from": args.sender,
            "reply_to": args.reply_to,
            "text": text,
            "sha256": digest,
            "bytes": len(raw),
        }
        data = dumps(message).encode("utf-8") + b"\n"
        if len(data) > MESSAGE_MAX_BYTES:
            return refuse(ident, "too-large", f"the message file must fit in {MESSAGE_MAX_BYTES} bytes", EXIT_INVALID)
        receipt = {
            "schema": RECEIPT_SCHEMA,
            "id": ident,
            "state": "queued",
            "reason": None,
            "created_at": message["created_at"],
            "updated_at": message["created_at"],
            "seq": seq,
            "from": args.sender,
            "reply_to": args.reply_to,
            "sha256": digest,
            "bytes": len(raw),
            "delivered_at": None,
            "session_id": None,
            "via": None,
        }
        channel.replace(seq_path, {"last": seq})
        staged = channel.write_tmp(dumps(receipt).encode("utf-8") + b"\n")
        try:
            os.link(staged, channel.receipt_path(ident))
        except FileExistsError:
            return refuse(ident, "id-conflict", "this id was claimed concurrently", EXIT_INVALID)
        finally:
            channel.unlink(staged)
        staged = channel.write_tmp(data)
        os.replace(staged, os.path.join(channel.queue, f"{ident}.json"))
        channel.replace(rate_path, {"accepted": recent + [now]})
    finally:
        os.close(lock)
    emit(result("queued", ident, None, None, receipt))
    return EXIT_OK


def consumer_view(channel: Channel) -> dict:
    record = channel.read_json(os.path.join(channel.root, "consumer.json"))
    pid = record.get("pid") if record else None
    if not isinstance(pid, int) or isinstance(pid, bool):
        return {"live": False, "pid": None, "session_id": None}
    lock = channel.read_bytes(os.path.join(channel.state, ".lock"), 64)
    holder = lock.decode("ascii", "replace").strip() if lock else ""
    live = pid_alive(pid) and holder == str(pid)
    session = record.get("session_id") if live and isinstance(record.get("session_id"), str) else None
    return {"live": live, "pid": pid if live else None, "session_id": session}


def cmd_status(channel: Channel, args: argparse.Namespace) -> int:
    present = channel.layout(create=False)
    if args.id is None:
        emit({
            "schema": STATUS_SCHEMA,
            "enabled": channel.enabled(),
            "consumer": consumer_view(channel) if present else {"live": False, "pid": None, "session_id": None},
            "queued": len(channel.queued_ids()),
            "inflight": len(channel.inflight_entries()),
            "bounds": {
                "message_max_bytes": MESSAGE_MAX_BYTES,
                "queue_max": QUEUE_MAX,
                "rate_max": RATE_MAX,
                "rate_window_seconds": RATE_WINDOW_MS // 1000,
                "ttl_seconds": TTL_MS // 1000,
                "receipt_retention_seconds": RECEIPT_RETAIN_MS // 1000,
            },
        })
        return EXIT_OK
    if not ID_RE.match(args.id):
        sys.stderr.write("fm-console-submit: invalid id\n")
        return EXIT_INVALID
    if not present or channel.receipt(args.id) is None:
        sys.stderr.write(f"fm-console-submit: no receipt for {args.id}\n")
        return EXIT_UNKNOWN
    lock = channel.lock()
    try:
        channel.settle(args.id, now_ms())
    finally:
        os.close(lock)
    receipt = channel.receipt(args.id)
    if receipt is None:
        sys.stderr.write(f"fm-console-submit: no receipt for {args.id}\n")
        return EXIT_UNKNOWN
    emit(receipt)
    return EXIT_OK


def main() -> int:
    parser = argparse.ArgumentParser(prog="fm-console-submit.py", add_help=False)
    parser.add_argument("--state", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--code-root", required=True)
    parser.add_argument("command", choices=["enqueue", "status"])
    parser.add_argument("--id")
    parser.add_argument("--from", dest="sender", default="astro")
    parser.add_argument("--reply-to", dest="reply_to")
    parser.add_argument("status_id", nargs="?")
    args = parser.parse_args()
    if args.command == "status" and args.status_id is not None:
        if args.id is not None:
            parser.error("give the id once")
        args.id = args.status_id
    elif args.status_id is not None:
        parser.error("enqueue takes --id, not a positional id")
    channel = Channel(args.state, args.config, args.code_root)
    try:
        if args.command == "enqueue":
            return cmd_enqueue(channel, args)
        return cmd_status(channel, args)
    except (Failure, OSError) as error:
        sys.stderr.write(f"fm-console-submit: {error}\n")
        return EXIT_FAIL


if __name__ == "__main__":
    sys.exit(main())
