#!/usr/bin/env bash
# fm-console-signals.sh - publish this home's console signals for an external
# console (Astro's FirstMate page): whether FirstMate waits for the captain and
# why, its open questions, and its registered bots.
#
# Usage:
#   FM_HOME=<home> fm-console-signals.sh write   assemble and atomically publish
#   FM_HOME=<home> fm-console-signals.sh print   print the document, write nothing
#   fm-console-signals.sh --help
#
# Format: one JSON object, schema fm-console-signals.v1, at
# <home>/state/console-signals.json. The consumer owns the contract
# (docs/firstmate-console-signals.md in the herdr-console/Astro repository);
# bin/fm-console-signals.py is the engine that applies its bounds. In short:
# `home` is the canonical home path, `lock_pid` the pid holding the home's
# session lock exactly as `fm-inbox.sh ready` reports it, `generated_at` the
# UTC write time; `questions[]` (at most 4), `waiting`, and `bots[]` (at most
# 32) follow, every text field bounded in bytes, cut on a rune boundary, and
# cleaned of escape sequences and control characters; the file never exceeds
# 64 KiB and is replaced by a temp-file rename inside state/.
#
# Sources, all structured and read-only:
#   - Questions and waiting: the one combined view of everything waiting on
#     the captain, `bin/fm-captain-pending.sh list --json`
#     (fm-captain-pending-list.v1), which owns the classification. Only its
#     live items become questions: open or overdue captain-pending ledger
#     entries (chat-only asks), live captain holds, and live needs-decision
#     status decisions; paused, parked, blocked, aged, expired, and stale
#     items never do. Order: overdue ledger entries first, then newest first
#     by creation time (a ledger entry's add time, a hold's hold-set time or
#     since date; undated items last; equal times keep the newer ledger entry
#     first), at most four. id = the item id (cp-<n> or the task id) reduced
#     to A-Za-z0-9._- (no leading dot, no "..", unique); topic = the item's
#     kind (question, approval, command, task, other, hold, or status) plus
#     " · <task id>" when it names a task; text = the ask (a hold's title and
#     reason; the topic when blank); since = the creation time when it is a
#     full timestamp. No source carries answer options, so no question lists
#     options. waiting is "waiting" on the first question while any live item
#     exists, else "none"; its reason is the first question's topic, followed
#     by "(+N more waiting)" when more than four live items exist. Chat and
#     status prose outside these records are never read.
#     When the view's fleet snapshot is unavailable (`list` exit 3), only the
#     ledger is reliable: its entries are published with "holds and status
#     decisions unreadable" in the reason, and with no open entry nothing is
#     published (exit 1), so the previous file ages instead of claiming that
#     nothing waits. Any other `list` failure also publishes nothing. `write`
#     keeps the last complete view in state/.console-signals-pending.json and
#     reuses it for up to 60 s while the home's .tasks.toml, the top-level
#     files of data/, and every state/*.status and *.meta file are unchanged,
#     so an idle fleet runs the view at most once a minute while a new or
#     closed ask still shows on the next write; `print` never uses it.
#   - Bots: the bot code's own interface, `fm-bot list --json` once and
#     `fm-bot show <name> --json` per listed bot, run from $FM_CONFIG_ROOT/bin
#     (a firstmate-config checkout), else from `fm-bot` on PATH, with this
#     home's FM_HOME and this checkout as FIRSTMATE_ROOT. Never `fm bot due`,
#     `check-install`, or `file`. A spec the bot code reports invalid or cannot
#     show is skipped with a bounded stderr line; with no lister the document
#     has no bots. id/name = the spec name, enabled = not paused, state:
#     paused for a paused spec; running when its last run is an in-flight
#     backlog task (bin/fm-fleet-snapshot.sh --contribution-input, read only
#     when the lister lists a bot), due when that task is queued or the bot
#     code reports the daily window open now, idle for a daily bot otherwise,
#     unknown for an active interval or remote bot that is neither (only the
#     bot code's admission evaluation could tell). schedule is a short
#     summary of the spec's trigger, scope its one-liner, next_due the next
#     window or candidate when the bot code reports one; last_run is omitted
#     because the bot code exposes a run id, not a time.
#
# Lock binding: the document is published only while state/.lock is held by a
# live verified harness (bin/fm-session-lock-lib.sh fm_session_lock_inspect, the
# reader `ready` uses). Otherwise `write` removes any existing file and exits 0,
# and `print` exits 3 with nothing on stdout. This script never takes or
# releases the session lock, never writes outside <home>/state/, never creates
# that directory, and never mutates the backlog, holds, the captain-pending
# ledger, or bot specs.
#
# Exit: 0 published (or removed with no held lock), 3 print with no held lock,
# 1 refusal or failure (FM_HOME not explicit, no state directory, an
# unreadable or unreliable captain-pending view as above, assembly or write
# failure). Diagnostics go to stderr, prefixed "fm-console-signals:".
#
# Cadence: bin/fm-watch.sh runs `write` detached each poll while the home's
# config/console-signals presence flag exists (docs/configuration.md "Console
# signals"); FM_CONSOLE_SIGNALS_TIMEOUT (default 20 s) bounds the
# captain-pending view read and, separately, all bot reads together.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '/^set -u$/d'
}

die() {
  printf 'fm-console-signals: %s\n' "$1" >&2
  exit 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  write|print) MODE=$1 ;;
  *) usage >&2; exit 1 ;;
esac
[ "$#" -eq 1 ] || { usage >&2; exit 1; }

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  die "FM_HOME is not set; refusing to publish without an explicit firstmate home"
fi
HOME_DIR=$(cd -P -- "$FM_HOME" 2>/dev/null && pwd -P) || die "FM_HOME is not a directory: $FM_HOME"
STATE="$HOME_DIR/state"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || die "no state directory (or a symbolic link) at $STATE"
SIGNALS_FILE="$STATE/console-signals.json"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
fm_session_lock_inspect "$STATE"
if [ "$FM_LOCK_INSPECT_STATE" != held ]; then
  if [ "$MODE" = print ]; then
    printf 'fm-console-signals: session lock is %s; nothing to publish\n' "$FM_LOCK_INSPECT_STATE" >&2
    exit 3
  fi
  if [ -f "$SIGNALS_FILE" ] || [ -L "$SIGNALS_FILE" ]; then
    rm -f -- "$SIGNALS_FILE" || die "could not remove $SIGNALS_FILE"
  fi
  exit 0
fi

BOT_BIN=
if [ -n "${FM_CONFIG_ROOT:-}" ] && [ -f "$FM_CONFIG_ROOT/bin/fm-bot" ] && [ -x "$FM_CONFIG_ROOT/bin/fm-bot" ]; then
  BOT_BIN="$FM_CONFIG_ROOT/bin/fm-bot"
elif command -v fm-bot >/dev/null 2>&1; then
  BOT_BIN=$(command -v fm-bot)
fi
TIMEOUT=${FM_CONSOLE_SIGNALS_TIMEOUT:-20}
case "$TIMEOUT" in
  ''|0*|*[!0-9]*) TIMEOUT=20 ;;
esac
[ "$TIMEOUT" -le 300 ] || TIMEOUT=20

exec python3 "$SCRIPT_DIR/fm-console-signals.py" "$MODE" \
  --home "$HOME_DIR" --lock-pid "$FM_LOCK_INSPECT_PID" --code-root "$FM_ROOT" \
  --bot-bin "$BOT_BIN" --timeout "$TIMEOUT"
