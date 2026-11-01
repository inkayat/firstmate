#!/usr/bin/env bash
# fm-console-submit.sh - the console submit channel's command line: a
# same-user console (Astro's FirstMate page) queues the captain's own message
# for the omp primary's conversation and reads its receipt.
#
# Usage:
#   FM_HOME=<home> fm-console-submit.sh enqueue --id <id> [--reply-to <ref>] [--from <name>]
#                                         (the message text on stdin, raw UTF-8)
#   FM_HOME=<home> fm-console-submit.sh status <id>
#   FM_HOME=<home> fm-console-submit.sh status
#   fm-console-submit.sh --help
#
# docs/console-submit.md owns the contract (fm-console-submit.v1): the opt-in
# flag config/console-submit, message rules, delivery, receipts, and bounds.
# bin/fm-console-submit.py is the engine; .omp/extensions/fm-console-submit.ts
# is the omp primary that delivers. This script never contacts a session,
# never touches the wake queue or the captain inbox, and makes no network call.
#
# Output: one JSON object on stdout (none for a status of an unknown or
# invalid id), diagnostics on stderr.
#   enqueue  fm-console-submit-result.v1: {outcome, id, reason, detail,
#            receipt}. outcome is queued (receipt written), replay (the same
#            id with the same text was already accepted; receipt is its
#            current state), or refused (reason disabled, invalid, too-large,
#            operational-format, id-conflict, queue-full, or rate-limited;
#            nothing written, receipt null, and except after id-conflict the
#            id may be sent again).
#   status <id>  the receipt (fm-console-submit-receipt.v1), after applying
#            the TTL and refusing a handed message whose omp process is gone.
#   status   fm-console-submit-status.v1: {enabled, consumer {live, pid,
#            session_id}, queued, inflight, bounds}.
#
# Exit: 0 queued, replay, or printed; 1 failure (FM_HOME not explicit, no
# state directory, python3 missing, unreadable channel, classifier failure);
# 2 invalid input (usage, invalid, too-large, operational-format,
# id-conflict); 3 disabled (enqueue) or unknown id (status); 4 queue-full or
# rate-limited, worth retrying later.
#
# Environment: FM_HOME (required, the home whose state/ holds the channel);
# FM_STATE_OVERRIDE and FM_CONFIG_OVERRIDE replace <home>/state and
# <home>/config, as for the extension. Under the test suite only
# (FM_TEST_SEAM=1), FM_TEST_CONSOLE_SUBMIT_NOW_MS fixes the clock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '/^set -u$/d'
}

die() {
  printf 'fm-console-submit: %s\n' "$1" >&2
  exit 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  enqueue|status) ;;
  *) usage >&2; exit 2 ;;
esac

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  die "FM_HOME is not set; refusing to use the channel without an explicit firstmate home"
fi
HOME_DIR=$(cd -P -- "$FM_HOME" 2>/dev/null && pwd -P) || die "FM_HOME is not a directory: $FM_HOME"
STATE="${FM_STATE_OVERRIDE:-$HOME_DIR/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$HOME_DIR/config}"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || die "no state directory (or a symbolic link) at $STATE"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

exec python3 "$SCRIPT_DIR/fm-console-submit.py" \
  --state "$STATE" --config "$CONFIG" --code-root "$FM_ROOT" "$@"
