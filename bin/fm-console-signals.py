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
import stat
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
PENDING_SCHEMA = "fm-captain-pending-list.v1"
PENDING_SECTIONS = ("waiting_on_captain", "paused_by_captain_order", "paused_other_reason")
PENDING_CACHE = ".console-signals-pending.json"
PENDING_MAX_AGE = 60
REQUESTS_MAX = 64
REQUEST_ID_MAX = 128
MISSING_MAX = 16
GENERATION = re.compile(r"[A-Za-z0-9:#._-]{1,200}\Z")
REQUEST_ID = re.compile(r"[A-Za-z0-9._-]{1,128}\Z")
# Bucket order of the request index: what the captain can act on first.
BUCKETS = ("live", "needs_recheck", "deferred", "blocked", "stale", "parked", "other")
COUNT_KEYS = ("live", "needs_recheck", "deferred", "blocked", "parked", "other", "stale", "total")

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
    """Backlog rows, for the bots' last-run states."""
    rc, out, err = run([os.path.join(code_root, "bin", "fm-fleet-snapshot.sh"), "--contribution-input"],
                       clean_env(home, code_root), timeout)
    if rc != 0:
        diag("backlog unreadable, bot run states unknown: " + (err.strip().splitlines() or ["exit %s" % rc])[-1])
        return None
    try:
        records = json.loads(out)["backlog"]["records"]
        return [r for r in records if isinstance(r, dict)]
    except (ValueError, KeyError, TypeError):
        diag("backlog snapshot was not the expected JSON; bot run states unknown")
        return None


def pending_fingerprint(home: str) -> list:
    """What changes when an ask does: the home's .tasks.toml, every top-level
    file in data/ (backlog, ledger, secondmate registry), and every task's
    status and meta file."""
    found = []
    for sub, keep in (("", lambda n: n == ".tasks.toml"), ("data", lambda n: True),
                      ("state", lambda n: n.endswith((".status", ".meta")))):
        try:
            with os.scandir(os.path.join(home, sub)) as entries:
                for e in entries:
                    if keep(e.name) and e.is_file(follow_symlinks=False):
                        st = e.stat(follow_symlinks=False)
                        found.append([sub + "/" + e.name, st.st_mtime_ns, st.st_size, st.st_ino])
        except OSError:
            found.append([sub, None, None, None])
    return sorted(found)


def cached_view(cache: str, fingerprint: list) -> dict | None:
    try:
        st = os.lstat(cache)
        if not stat.S_ISREG(st.st_mode) or not 0 <= time.time() - st.st_mtime < PENDING_MAX_AGE:
            return None
        with open(cache, encoding="utf-8") as f:
            cached = json.load(f)
        view = cached.get("view")
        # A view cached by an older engine lacks the exact counts or its
        # coverage; read anew.
        if cached.get("fingerprint") == fingerprint and view.get("schema") == PENDING_SCHEMA \
                and all(k in (view.get("counts") or {}) for k in COUNT_KEYS) \
                and (view.get("coverage") or {}).get("complete") is True:
            return view
    except (OSError, ValueError, AttributeError):
        pass
    return None


def pending_view(args: argparse.Namespace, use_cache: bool) -> tuple:
    """(view, complete) from `fm-captain-pending.sh list --json`, or None.
    complete is False when the view did not read every source: its fleet
    snapshot was unavailable (exit 3), when the view then holds the ledger
    alone, or its coverage names a source it could not read. With use_cache,
    a complete view is kept in state/ and reused for up to PENDING_MAX_AGE
    seconds while the fingerprint of what it reads is unchanged."""
    cache = os.path.join(args.home, "state", PENDING_CACHE)
    fingerprint = pending_fingerprint(args.home)
    if use_cache:
        view = cached_view(cache, fingerprint)
        if view is not None:
            return view, True
    rc, out, err = run([os.path.join(args.code_root, "bin", "fm-captain-pending.sh"), "list", "--json"],
                       clean_env(args.home, args.code_root), args.timeout)
    try:
        view = json.loads(out) if rc in (0, 3) else None
    except ValueError:
        view = None
    if not isinstance(view, dict) or view.get("schema") != PENDING_SCHEMA:
        diag("captain-pending view unreadable: " + (err.strip().splitlines() or ["exit %s" % rc])[-1])
        return None
    complete = rc == 0 and (view.get("fleet") or {}).get("available") is True \
        and (view.get("coverage") or {}).get("complete") is True
    if complete and use_cache:
        try:
            publish_file(os.path.dirname(cache), PENDING_CACHE,
                         json.dumps({"fingerprint": fingerprint, "view": view}).encode("utf-8"))
        except OSError as exc:
            diag("captain-pending view not cached: %s" % exc)
    return view, complete


def reply_reference(item: dict) -> tuple:
    """(generation, answer_to) of a view item: its generation when well formed,
    and its inbox-note reference only when the view offers one for exactly
    this source, canonical id, and generation."""
    gen = item.get("generation")
    gen = gen if isinstance(gen, str) and GENERATION.match(gen) else None
    reply = item.get("reply")
    ref = reply.get("answer_to") if isinstance(reply, dict) else None
    rid = item.get("id")
    if not (gen and isinstance(rid, str) and REQUEST_ID.match(rid)
            and ref == "%s:%s@%s" % (item.get("source"), rid, gen)):
        ref = None
    return gen, ref


def questions_from(view: dict) -> tuple:
    """(questions, live items left out) from the view's live items."""
    live = [i for section in PENDING_SECTIONS for i in (view.get(section) or [])
            if isinstance(i, dict) and i.get("live") is True]
    # Overdue ledger entries first, then newest first by creation time
    # (date-only stamps sort as their day, untimed items last); equal times
    # keep the later-listed item first, so the newer ledger entry leads.
    live.reverse()
    live.sort(key=lambda i: i.get("created") if isinstance(i.get("created"), str) else "", reverse=True)
    live.sort(key=lambda i: i.get("label") != "overdue")
    taken: set = set()
    questions = []
    for i in live:
        if len(questions) == QUESTIONS_MAX:
            break
        kind = {"ledger": i.get("kind"), "backlog": "hold", "status": "status"}.get(i.get("source")) or "ask"
        task = i.get("task_id")
        topic = text("%s · %s" % (kind, task) if isinstance(task, str) and task else kind, TOPIC_MAX)
        body = text(i.get("text"), TEXT_MAX, multiline=True) or topic
        qid = make_id(i.get("id"), taken) if body else ""
        if not qid:
            diag("skipped a waiting item with no usable id or text")
            continue
        q = {"id": qid, "text": body}
        if topic:
            q["topic"] = topic
        created = i.get("created")
        if isinstance(created, str) and FULL_TIME.match(created):
            q["since"] = created
        # Additive keys: which request this is, its version, and whether the
        # text above is whole; only a whole text may be answered from here.
        gen, ref = reply_reference(i)
        truncated = len(clean(i.get("text"), True).encode("utf-8")) > TEXT_MAX
        q["request_id"] = text(i.get("id"), REQUEST_ID_MAX)
        q["source"] = i.get("source") if i.get("source") in ("ledger", "backlog", "status") else "unknown"
        if q["source"] == "status" and isinstance(i.get("key"), str):
            q["key"] = text(i["key"], REQUEST_ID_MAX)
        q["generation"] = gen
        q["text_truncated"] = truncated
        if ref and not truncated:
            q["answer_to"] = ref
        questions.append(q)
    return questions, len(live) - len(questions)


def view_items(view: dict) -> list:
    return [i for section in PENDING_SECTIONS for i in (view.get(section) or []) if isinstance(i, dict)]


def requests_from(view: dict) -> list:
    """Every open item of the view, compact, ordered by bucket (live first)
    and otherwise as the view lists them; the caller bounds it."""
    rank = {b: n for n, b in enumerate(BUCKETS)}
    items = sorted(view_items(view), key=lambda i: rank.get(i.get("bucket"), len(BUCKETS)))
    out = []
    for i in items:
        rid = text(i.get("id"), REQUEST_ID_MAX)
        if not rid:
            continue
        gen, _ = reply_reference(i)
        r = {"id": rid,
             "source": i.get("source") if i.get("source") in ("ledger", "backlog", "status") else "unknown",
             "bucket": i.get("bucket") if i.get("bucket") in BUCKETS else "other",
             "generation": gen}
        if r["source"] == "status" and isinstance(i.get("key"), str):
            r["key"] = text(i["key"], REQUEST_ID_MAX)
        first_line = clean(i.get("text"), True).split("\n", 1)[0]
        r["subject"] = cut(first_line, TOPIC_MAX)
        created = i.get("created")
        if isinstance(created, str) and FULL_TIME.match(created):
            r["since"] = created
        out.append(r)
    return out


def counts_from(view: dict) -> dict:
    counts = view.get("counts") or {}
    out = {}
    for key in COUNT_KEYS:
        value = counts.get(key)
        if type(value) is not int or value < 0:
            raise ValueError("the captain-pending view has no exact %s count" % key)
        out[key] = value
    return out


def coverage_from(view: dict, complete: bool) -> dict:
    """The view's coverage, bounded: missing names each source it could not
    read (backlog, status, secondmates, secondmate:<id>), once, and
    missing_reasons says why."""
    entries = [m for m in ((view.get("coverage") or {}).get("missing") or []) if isinstance(m, dict)]
    if not complete and not entries:
        entries = [{"source": "backlog", "reason": "not read"}, {"source": "status", "reason": "not read"}]
    missing, reasons = [], []
    for m in entries:
        source = text(m.get("source"), REQUEST_ID_MAX) or "unknown"
        if source not in missing:
            missing.append(source)
        reasons.append({"source": source, "reason": text(m.get("reason"), REASON_MAX) or "not read"})
    unreadable = (view.get("ledger") or {}).get("unreadable_lines")
    return {"complete": complete,
            "missing": missing[:MISSING_MAX],
            "missing_reasons": reasons[:MISSING_MAX],
            "missing_omitted": max(len(missing) - MISSING_MAX, 0),
            "ledger_unreadable_lines": unreadable if isinstance(unreadable, int) else 0}


def coverage_notes(missing: list) -> list:
    """What the wait reason says is unread, so prose never claims a whole list."""
    notes = []
    if "backlog" in missing and "status" in missing:
        notes.append("holds and status decisions unreadable")
    elif "backlog" in missing:
        notes.append("captain holds unreadable")
    elif "status" in missing:
        notes.append("status decisions unreadable")
    if any(m == "secondmates" or m.startswith("secondmate:") for m in missing):
        notes.append("secondmate calls unreadable")
    if any(m not in ("backlog", "status", "secondmates") and not m.startswith("secondmate:") for m in missing):
        notes.append("some sources unreadable")
    return notes


def waiting_from(questions: list, left_out: int, unread: list) -> dict:
    if not questions:
        return {"state": "none"}
    first = questions[0]
    notes = (["+%d more waiting" % left_out] if left_out else []) + unread
    reason = first.get("topic") or clean(first["text"], False)
    if notes:
        reason += " (%s)" % "; ".join(notes)
    w = {"state": "waiting", "reason": cut(reason, REASON_MAX), "question_id": first["id"]}
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


def bots_from(bot_bin: str, home: str, code_root: str, timeout: float) -> list:
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
    records = backlog_records(home, code_root, deadline - time.monotonic()) if listed else None
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


def assemble(args: argparse.Namespace, use_cache: bool) -> bytes:
    pending = pending_view(args, use_cache)
    if pending is None:
        raise ValueError("the captain-pending view is unreadable")
    view, complete = pending
    unreadable = (view.get("ledger") or {}).get("unreadable_lines")
    if isinstance(unreadable, int) and unreadable > 0:
        diag("%d unreadable captain-pending ledger line(s) skipped" % unreadable)
    questions, left_out = questions_from(view)
    coverage = coverage_from(view, complete)
    unread = [] if complete else coverage_notes(coverage["missing"])
    if not complete and not questions:
        # With no readable item waiting, a document would say nothing waits:
        # publish nothing, so the previous file ages instead.
        raise ValueError("%s unreadable and nothing readable waits; nothing reliable to publish"
                         % ", ".join(coverage["missing"]))
    counts = counts_from(view)
    requests = requests_from(view)
    listed = requests[:REQUESTS_MAX]
    generated = view.get("generated")
    doc = {
        "schema": SCHEMA,
        "home": args.home,
        "lock_pid": int(args.lock_pid),
        "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "waiting": waiting_from(questions, left_out, unread),
        "questions": questions,
        "bots": bots_from(args.bot_bin, args.home, args.code_root, args.timeout),
        # Additive keys: exact counts from the source, what the view could not
        # read, when it was computed, and every open request, bounded.
        "counts": counts,
        "coverage": coverage,
        "view_generated_at": generated if isinstance(generated, str) and FULL_TIME.match(generated) else None,
        "requests": listed,
        "requests_omitted": counts["total"] - len(listed),
    }
    data = (json.dumps(doc, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    # The index yields room before anything else does: drop its last entries
    # (the least actionable) and count them as omitted until the file fits.
    while len(data) > FILE_MAX and doc["requests"]:
        doc["requests"].pop()
        doc["requests_omitted"] += 1
        data = (json.dumps(doc, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    if len(data) > FILE_MAX:
        raise ValueError("document is %d bytes, over the %d-byte cap" % (len(data), FILE_MAX))
    return data


def publish_file(state: str, name: str, data: bytes) -> None:
    fd, tmp = tempfile.mkstemp(prefix="." + name + ".", dir=state)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, os.path.join(state, name))
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
        data = assemble(args, use_cache=args.mode == "write")
        if args.mode == "print":
            sys.stdout.buffer.write(data)
        else:
            publish_file(os.path.join(args.home, "state"), FILE_NAME, data)
    except (OSError, ValueError) as exc:
        diag("not published: %s" % exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
