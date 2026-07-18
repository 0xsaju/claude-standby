#!/usr/bin/env bash
# task-cancel.sh — backend for `claude-auto-resume cancel`
# Sets status=cancelled; the (future) daemon reads state before every action
# and stands down on cancelled, so no direct signaling is needed.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh" || { echo "auto-resume: failed to load lib.sh"; exit 0; }

WS="$(pwd)"
STATUS="$(ar_task_get "$WS" status)"
if [ -z "$STATUS" ]; then
  echo "No tracked task for this workspace ($WS) — nothing to cancel."
  exit 0
fi
if [ "$STATUS" = "cancelled" ]; then
  echo "Task in $WS is already cancelled."
  exit 0
fi

if ! ar_task_set "$WS" status cancelled; then
  echo "auto-resume: could not write state file — see $AR_LOG_DIR/plugin.log"
  exit 0
fi
ar_journal_append "$WS" "cancelled" "was: $STATUS"
ar_log "task-cancel: ws=$WS (was $STATUS)"
echo "Cancelled tracked task in $WS (was: $STATUS). Any pending auto-resume will stand down."
exit 0
