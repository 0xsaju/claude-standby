#!/usr/bin/env bash
# task-start.sh — backend for `claude-standby start`
# Prints a human-readable result; exits 0 even on user error.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh" || { echo "auto-resume: failed to load lib.sh"; exit 0; }

USAGE="Usage: claude-standby start <critical|normal|low> <task description>"

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
# `start` begins a NEW task. ar_task_upsert MERGES onto any existing record,
# so we must explicitly reset every field that belongs to a prior task's
# lifecycle — otherwise the new task inherits the old task's pinned session,
# "already saw a limit" flags, custom resume prompt, spent attempt budget, and
# daemon ownership, and a later resume-at would continue the WRONG, unrelated
# conversation (F04). session_id is cleared here; resume-at (HOOK-FINDINGS F2)
# discovers and pins the right session at schedule time.
if ! ar_task_upsert "$WS" \
    "status=running" \
    "importance=$IMPORTANCE" \
    "original_prompt=$PROMPT" \
    "session_id=" \
    "limit_seen=0" \
    "limit_seen_at=" \
    "armed_noted=0" \
    "armed_since=" \
    "daemon_pid=" \
    "resume_prompt_template=$AR_DEFAULT_RESUME_PROMPT" \
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
echo "Tip: a progress/handoff file in the workspace makes resumes sturdier (point --prompt at it)."
exit 0
