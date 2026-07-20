#!/usr/bin/env bash
# task-status.sh — backend for `claude-standby status`
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh" || { echo "auto-resume: failed to load lib.sh"; exit 0; }

WS="$(pwd)"
STATUS="$(ar_task_get "$WS" status)"
if [ -z "$STATUS" ]; then
  echo "No tracked task for this workspace ($WS)."
  echo "Start one with: claude-standby start <critical|normal|low> <task description>"
  exit 0
fi

IMPORTANCE="$(ar_task_get "$WS" importance)"
RESUME_AT="$(ar_task_get "$WS" resume_at)"
RESUME_MODE="$(ar_task_get "$WS" resume_mode)"
RESUME_COUNT="$(ar_task_get "$WS" resume_count)"
MAX_RESUMES="$(ar_task_get "$WS" max_resumes)"
PROMPT="$(ar_task_get "$WS" original_prompt)"
SESSION_ID="$(ar_task_get "$WS" session_id)"

echo "Task in $WS"
echo "  status     : $STATUS"
echo "  importance : $IMPORTANCE"
if [ -n "$SESSION_ID" ]; then
  echo "  session    : $(printf '%.8s' "$SESSION_ID") (resume continues this conversation)"
else
  echo "  session    : none pinned — resume starts a NEW chat (see: claude-standby sessions)"
fi
echo "  resumes    : ${RESUME_COUNT:-0} of ${MAX_RESUMES:-3}"
if [ "$RESUME_MODE" = "auto" ]; then
  echo "  resume     : auto-detect (probing; next probe: ${RESUME_AT:-soon})"
elif [ -n "$RESUME_AT" ]; then
  echo "  resume at  : $RESUME_AT"
fi
if [ -n "$PROMPT" ]; then
  if [ "${#PROMPT}" -gt 72 ]; then
    echo "  prompt     : ${PROMPT:0:72}…"
  else
    echo "  prompt     : $PROMPT"
  fi
fi
RESUME_PROMPT="$(ar_task_get "$WS" resume_prompt_template)"
if [ -n "$RESUME_PROMPT" ] && [ "$RESUME_PROMPT" != "$AR_DEFAULT_RESUME_PROMPT" ]; then
  if [ "${#RESUME_PROMPT}" -gt 72 ]; then
    echo "  on resume  : ${RESUME_PROMPT:0:72}…"
  else
    echo "  on resume  : $RESUME_PROMPT"
  fi
fi
echo "Recent journal:"
JOURNAL="$(ar_journal_show "$WS" 5)"
if [ -n "$JOURNAL" ]; then
  printf '%s\n' "$JOURNAL"
else
  echo "  (empty)"
fi
exit 0
