#!/usr/bin/env python3
"""The engine behind bin/fm-console-signals.sh: assemble one
fm-console-signals.v1 document from structured state and print it or publish
it atomically into <home>/state/console-signals.json.

bin/fm-console-signals.sh owns the command contract (sources, lock binding,
exit codes, cadence); call it, not this file. The consumer's
docs/firstmate-console-signals.md (herdr-console/Astro repository) owns the
format; the bounds below restate its numbers so nothing written can exceed
them: a value is cut on a rune boundary (marked with an ellipsis) and cleaned
of escape sequences and control characters before it is bounded, so the file
is never refused for a bound.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import unicodedata

SCHEMA = "fm-console-signals.v1"
FILE_NAME = "console-signals.json"
FILE_MAX = 64 << 10
ID_MAX = 64
REASON_MAX = 256
TOPIC_MAX = 80
TEXT_MAX = 2048
QUESTIONS_MAX = 4
BOTS_MAX = 32
NAME_MAX = 64
SCHEDULE_MAX = 80
SCOPE_MAX = 160
PROJECT_MAX = 64
DIAG_MAX = 160
ELLIPSIS = "\u2026"

# CSI (7- and 8-bit), OSC, DCS/SOS/PM/APC strings, and two-byte ESC sequences.
ESCAPES = re.compile(
    r"\x1b\[[0-?]*[ -/]*[@-~]"
    r"|\x9b[0-?]*[ -/]*[@-~]"
    r"|\x1b\][^\x07\x1b\x9c]*(?:\x07|\x1b\\|\x9c)?"
    r"|\x1b[PX^_][^\x1b\x9c]*(?:\x1b\\|\x9c)?"
    r"|\x1b[ -/]*[0-~]"
)
# Bidirectional embedding, override, and isolate controls reorder what the
# terminal draws; they are format characters, so Cc filtering misses them.
BIDI = set("\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069")
FULL_TIME = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z")
LOCAL_NEXT = re.compile(r"([0-9]{4}-[0-9]{2}-[0-9]{2}) ([0-9]{2}):([0-9]{2}) ([A-Za-z+0-9-]+)\Z")


def diag(message: str) -> None:
    print("fm-console-signals: " + cut(clean(message, False), DIAG_MAX), file=sys.stderr)


def clean(value: object, multiline: bool) -> str:
    """Untrusted text without escape sequences or control characters; CR LF
    and CR become line breaks, which one-line fields turn into spaces."""
    if not isinstance(value, str):
        return ""
    s = ESCAPES.sub("", value.replace("\r\n", "\n").replace("\r", "\n"))
    out = []
    for ch in s:
        if ch == "\n" and multiline:
            out.append(ch)
        elif ch in "\n\t":
            out.append(" ")
        elif unicodedata.category(ch) in ("Cc", "Cs") or ch in BIDI:
            continue
        else:
            out.append(ch)
    return "".join(out).strip()


def cut(s: str, limit: int) -> str:
    """At most `limit` UTF-8 bytes, never ending inside a rune."""
    if len(s.encode("utf-8")) <= limit:
        return s
    room = limit - len(ELLIPSIS.encode("utf-8"))
    head = s.encode("utf-8")[:room].decode("utf-8", "ignore").rstrip()
    return head + ELLIPSIS


def text(value: object, limit: int, multiline: bool = False) -> str:
    return cut(clean(value, multiline), limit)


def make_id(raw: object, taken: set) -> str:
    """The contract's id: 1-64 of A-Za-z0-9._-, no leading dot, no "..",
    unique within `taken` (which this adds to); "" when nothing remains."""
    s = re.sub(r"[^A-Za-z0-9._-]", "-", raw if isinstance(raw, str) else "")
    while ".." in s:
        s = s.replace("..", ".")
    s = s.lstrip(".")[:ID_MAX]
    if not s:
        return ""
    base, n = s, 1
    while s in taken:
        n += 1
        suffix = "-%d" % n
        s = base[:ID_MAX - len(suffix)] + suffix
    taken.add(s)
    return s


def run(argv: list, env: dict, timeout: float) -> tuple:
    """(returncode or None on timeout/failure, stdout, stderr), killing the
    command's whole process group at the bound."""
    if timeout <= 0:
        return None, "", "no time left"
    try:
        proc = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, start_new_session=True)
    except OSError as exc:
        return None, "", str(exc)
    try:
        out, err = proc.communicate(timeout=timeout)
        return proc.returncode, out, err
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.communicate()
        return None, "", "timed out after %d s" % timeout


def clean_env(home: str, code_root: str) -> dict:
    env = {k: v for k, v in os.environ.items()
           if k not in ("FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE",
                        "FM_PROJECTS_OVERRIDE", "FM_ROOT_OVERRIDE", "FM_BOT_TEST_CLOCK")}
    env["FM_HOME"] = home
    env["FIRSTMATE_ROOT"] = code_root
    return env


def backlog_records(home: str, code_root: str, timeout: float) -> list | None:
    """Backlog rows with the fleet snapshot's own hold classification."""
    rc, out, err = run([os.path.join(code_root, "bin", "fm-fleet-snapshot.sh"), "--contribution-input"],
                       clean_env(home, code_root), timeout)
    if rc != 0:
        diag("backlog unreadable, no questions published: " + (err.strip().splitlines() or ["exit %s" % rc])[-1])
        return None
    try:
        records = json.loads(out)["backlog"]["records"]
        return [r for r in records if isinstance(r, dict)]
    except (ValueError, KeyError, TypeError):
        diag("backlog snapshot was not the expected JSON; no questions published")
        return None


def questions_from(records: list) -> list:
    live = [r for r in records if r.get("hold_bucket") == "live" and r.get("state") != "done"]
    # Newest hold first (the fleet snapshot's newest-first order for live
    # holds); undated holds last, ties by id so the order is stable.
    live.sort(key=lambda r: (str(r.get("id") or "")))
    live.sort(key=lambda r: str(r.get("hold_set") or r.get("since") or ""), reverse=True)
    taken: set = set()
    questions = []
    for r in live:
        if len(questions) == QUESTIONS_MAX:
            break
        qid = make_id(r.get("id"), taken)
        if not qid:
            diag("skipped a live hold with no usable id")
            continue
        topic = text(r.get("title"), TOPIC_MAX)
        body = text(r.get("hold_reason"), TEXT_MAX, multiline=True) or topic
        if not body:
            diag("skipped live hold %s: no reason or title" % qid)
            continue
        q = {"id": qid, "text": body}
        if topic:
            q["topic"] = topic
        hold_set = r.get("hold_set")
        if isinstance(hold_set, str) and FULL_TIME.match(hold_set):
            q["since"] = hold_set
        questions.append(q)
    return questions


def waiting_from(questions: list) -> dict:
    if not questions:
        return {"state": "none"}
    first = questions[0]
    w = {"state": "waiting", "reason": cut(first.get("topic") or clean(first["text"], False), REASON_MAX),
         "question_id": first["id"]}
    if "since" in first:
        w["since"] = first["since"]
    return w


def next_due(row: dict, listed: dict) -> str | None:
    """The bot code's next window or candidate as UTC RFC 3339, or None."""
    value = row.get("next")
    if not isinstance(value, str):
        return None
    if FULL_TIME.match(value):
        return value
    m = LOCAL_NEXT.match(value)
    zone = str(listed.get("schedule") or "").rsplit(" ", 1)[-1]
    if not m or "/" not in zone:
        return None
    try:
        import zoneinfo
        tz = zoneinfo.ZoneInfo(zone)
        naive = datetime.datetime.strptime("%s %s:%s" % m.group(1, 2, 3), "%Y-%m-%d %H:%M")
    except (ImportError, ValueError, KeyError, OSError):
        return None
    for fold in (0, 1):
        local = naive.replace(tzinfo=tz, fold=fold)
        if local.tzname() == m.group(4):
            return local.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return None


def schedule_of(row: dict, listed: dict) -> str:
    trigger = row.get("trigger") or "daily"
    if trigger == "daily" and row.get("days") and row.get("at") and row.get("until"):
        return "%s %s-%s" % (row["days"], row["at"], row["until"])
    if trigger == "interval" and row.get("every_hours"):
        return "every %s h" % row["every_hours"]
    if trigger == "remote" and row.get("on_remote") and row.get("on_branch"):
        return "on %s/%s" % (row["on_remote"], row["on_branch"])
    return str(listed.get("schedule") or "")


def bot_state(row: dict, by_id: dict) -> str:
    if row.get("state") == "paused":
        return "paused"
    run_row = by_id.get(row.get("last_run"))
    if run_row is not None and run_row.get("state") == "in_flight":
        return "running"
    if run_row is not None and run_row.get("state") == "queued":
        return "due"
    if row.get("next") == "in window now":
        return "due"
    return "idle" if (row.get("trigger") or "daily") == "daily" else "unknown"


def bots_from(bot_bin: str, home: str, code_root: str, records: list | None, timeout: float) -> list:
    if not bot_bin:
        if os.path.isdir(os.path.join(home, "data", "bots")):
            diag("data/bots exists but no fm-bot lister was found ($FM_CONFIG_ROOT/bin/fm-bot or PATH); no bots published")
        return []
    deadline = time.monotonic() + timeout
    env = clean_env(home, code_root)
    rc, out, err = run([bot_bin, "list", "--json"], env, timeout)
    try:
        listed = json.loads(out) if rc == 0 else None
    except ValueError:
        listed = None
    if not isinstance(listed, list):
        diag("fm-bot list failed, no bots published: " + (err.strip().splitlines() or ["exit %s" % rc])[-1])
        return []
    by_id = {r.get("id"): r for r in (records or [])}
    taken: set = set()
    bots = []
    for entry in listed:
        if not isinstance(entry, dict):
            continue
        name = entry.get("name") if isinstance(entry.get("name"), str) else ""
        if entry.get("state") not in ("active", "paused"):
            diag("skipped bot %r: %s" % (name, entry.get("detail") or "invalid spec"))
            continue
        if len(bots) == BOTS_MAX:
            diag("more than %d bots; the rest are not published" % BOTS_MAX)
            break
        rc, out, err = run([bot_bin, "show", name, "--json"], env, deadline - time.monotonic())
        try:
            row = json.loads(out) if rc == 0 else None
        except ValueError:
            row = None
        if not isinstance(row, dict):
            diag("skipped bot %r: %s" % (name, (err.strip().splitlines() or ["show failed"])[-1]))
            continue
        bid = make_id(name, taken)
        if not bid:
            diag("skipped a bot with no usable name")
            continue
        bot = {"id": bid, "name": text(name, NAME_MAX) or bid, "enabled": row.get("state") != "paused",
               "state": bot_state(row, by_id)}
        for key, value, limit in (("schedule", schedule_of(row, entry), SCHEDULE_MAX),
                                  ("scope", row.get("scope"), SCOPE_MAX),
                                  ("project", row.get("project"), PROJECT_MAX)):
            value = text(value, limit)
            if value:
                bot[key] = value
        due = next_due(row, entry)
        if due:
            bot["next_due"] = due
        bots.append(bot)
    return bots


def assemble(args: argparse.Namespace) -> bytes:
    records = backlog_records(args.home, args.code_root, args.timeout)
    questions = questions_from(records or [])
    doc = {
        "schema": SCHEMA,
        "home": args.home,
        "lock_pid": int(args.lock_pid),
        "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "waiting": waiting_from(questions),
        "questions": questions,
        "bots": bots_from(args.bot_bin, args.home, args.code_root, records, args.timeout),
    }
    data = (json.dumps(doc, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    if len(data) > FILE_MAX:
        raise ValueError("document is %d bytes, over the %d-byte cap" % (len(data), FILE_MAX))
    return data


def publish(state: str, data: bytes) -> None:
    fd, tmp = tempfile.mkstemp(prefix="." + FILE_NAME + ".", dir=state)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, os.path.join(state, FILE_NAME))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser(prog="fm-console-signals.py")
    parser.add_argument("mode", choices=("write", "print"))
    parser.add_argument("--home", required=True)
    parser.add_argument("--lock-pid", required=True)
    parser.add_argument("--code-root", required=True)
    parser.add_argument("--bot-bin", default="")
    parser.add_argument("--timeout", type=float, default=20)
    args = parser.parse_args()
    if not args.lock_pid.isdigit() or int(args.lock_pid) <= 0:
        diag("the session lock pid %r is not a local pid; nothing published" % args.lock_pid)
        return 1
    if not 0 < args.timeout <= 300:
        args.timeout = 20
    try:
        data = assemble(args)
        if args.mode == "print":
            sys.stdout.buffer.write(data)
        else:
            publish(os.path.join(args.home, "state"), data)
    except (OSError, ValueError) as exc:
        diag("not published: %s" % exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
