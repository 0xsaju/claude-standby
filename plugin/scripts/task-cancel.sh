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
# Find the direct children of a pid via `ps` (portable: works on both BSD
# ps (macOS) and GNU ps (Linux) with -eo, unlike the optional `pgrep` F14 —
# this makes immediate cancellation not depend on an optional tool).
ar_cancel_children_of() {
  ps -Ao pid,ppid 2>/dev/null | awk -v p="$1" '$2 == p { print $1 }'
}

KILLED=""
PIDFILE="$(ar_daemon_pidfile "$WS")"
if [ -f "$PIDFILE" ]; then
  DPID="$(cat "$PIDFILE" 2>/dev/null)"
  # F09: only ever signal a positive integer > 1 (never 0 = broadcast to
  # this process group, never a negative process-group id, never 1 = init/
  # launchd) — and only after confirming it belongs to THIS workspace's
  # daemon, cross-checked against the daemon_pid the daemon itself recorded
  # in state.json (the pidfile is already keyed by a hash of $WS, but the
  # cross-check guards against a stale pidfile pointing at a recycled pid).
  case "$DPID" in
    ''|0|1) DPID="" ;;
    *[!0-9]*) DPID="" ;;
  esac
  if [ -n "$DPID" ]; then
    STATE_DPID="$(ar_task_get "$WS" daemon_pid 2>/dev/null)"
    if [ -n "$STATE_DPID" ] && [ "$STATE_DPID" != "$DPID" ]; then
      ar_log "task-cancel: pidfile pid $DPID does not match state daemon_pid $STATE_DPID for $WS — not signaling"
      DPID=""
    fi
  fi
  if [ -n "$DPID" ] && kill -0 "$DPID" 2>/dev/null; then
    DESCENDANTS=""
    for c in $(ar_cancel_children_of "$DPID"); do
      DESCENDANTS="$DESCENDANTS $c $(ar_cancel_children_of "$c")"
    done
    kill "$DPID" 2>/dev/null
    for p in $DESCENDANTS; do
      case "$p" in
        ''|0|1) ;;
        *[!0-9]*) ;;
        *) kill "$p" 2>/dev/null ;;
      esac
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
