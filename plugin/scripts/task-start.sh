#!/usr/bin/env bash
# task-start.sh — backend for `claude-auto-resume start`
# Prints a human-readable result; exits 0 even on user error.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh" || { echo "auto-resume: failed to load lib.sh"; exit 0; }

USAGE="Usage: claude-auto-resume start <critical|normal|low> <task description>"

IMPORTANCE="${1:-}"
if [ $# -gt 0 ]; then shift; fi
PROMPT="$*"

case "$IMPORTANCE" in
  critical|normal|low) ;;
  *) echo "$USAGE"; exit 0 ;;
esac
if [ -z "$PROMPT" ]; then
  echo "$USAGE"
  exit 0
fi

WS="$(pwd)"
# session_id stays empty here; the Stop/SessionEnd hook fills it (D6).
if ! ar_task_upsert "$WS" \
    "status=running" \
    "importance=$IMPORTANCE" \
    "original_prompt=$PROMPT" \
    "resume_count=0"; then
  echo "auto-resume: could not write state file ($AR_STATE_FILE) — see $AR_LOG_DIR/plugin.log"
  exit 0
fi
ar_journal_append "$WS" "task-started" "importance=$IMPORTANCE"
ar_log "task-start: ws=$WS importance=$IMPORTANCE"

echo "Auto-resume is now tracking this workspace."
echo "  workspace  : $WS"
echo "  importance : $IMPORTANCE"
echo "  status     : running"
echo "  state file : $AR_STATE_FILE"
echo "Keep PROGRESS.md updated — it is the resume context."
exit 0
