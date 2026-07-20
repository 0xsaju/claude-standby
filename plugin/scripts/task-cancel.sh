#!/usr/bin/env bash
# task-cancel.sh — backend for `claude-standby cancel`
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

# Stop the daemon AND any in-flight resume right now — the state change
# alone would only take effect at the next tick, and a claude process
# already launched would keep running (and spending quota) until it
# finished on its own.
KILLED=""
PIDFILE="$(ar_daemon_pidfile "$WS")"
if [ -f "$PIDFILE" ]; then
  DPID="$(cat "$PIDFILE" 2>/dev/null)"
  if [ -n "$DPID" ] && kill -0 "$DPID" 2>/dev/null; then
    DESCENDANTS=""
    if command -v pgrep >/dev/null 2>&1; then
      for c in $(pgrep -P "$DPID" 2>/dev/null); do
        DESCENDANTS="$DESCENDANTS $c $(pgrep -P "$c" 2>/dev/null)"
      done
    fi
    kill "$DPID" 2>/dev/null
    for p in $DESCENDANTS; do
      kill "$p" 2>/dev/null
    done
    ar_log "task-cancel: stopped daemon $DPID and children:$DESCENDANTS"
    KILLED=1
  fi
  rm -f "$PIDFILE" 2>/dev/null
fi

if [ -n "$KILLED" ]; then
  echo "Cancelled tracked task in $WS (was: $STATUS). Stopped the daemon and any in-flight resume."
else
  echo "Cancelled tracked task in $WS (was: $STATUS)."
fi
exit 0
