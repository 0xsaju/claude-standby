#!/usr/bin/env bash
# task-sessions.sh — backend for `claude-standby sessions`
#
# Lists this workspace's Claude Code sessions (HOOK-FINDINGS F2) so the
# user can pick WHICH conversation the daemon resumes after a limit reset.
# The index numbers printed here are accepted by:
#   claude-standby resume-at [when] [tier] --session <n|id|latest|new>
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh" || { echo "auto-resume: failed to load lib.sh"; exit 0; }

WS="$(pwd)"
case "${1:-}" in
  --workspace|-w)
    if [ -n "${2:-}" ] && [ -d "$2" ]; then
      WS="$(cd "$2" && pwd)"
    else
      echo "Workspace '${2:-}' is not a directory."
      exit 0
    fi
    ;;
  --workspace=*)
    W="${1#--workspace=}"
    if [ -d "$W" ]; then WS="$(cd "$W" && pwd)"; else echo "Workspace '$W' is not a directory."; exit 0; fi
    ;;
esac
PINNED="$(ar_task_get "$WS" session_id)"
LINES="$(ar_sessions_list "$WS")"

if [ -z "$LINES" ]; then
  echo "No Claude Code sessions found for this workspace."
  echo "  (looked in: $(ar_project_dir "$WS"))"
  echo "Sessions appear here after you run claude in this directory."
  exit 0
fi

age() {
  # $1: epoch -> compact relative age
  local d=$(( $(date +%s) - $1 ))
  [ "$d" -lt 0 ] && d=0
  if [ "$d" -lt 3600 ]; then echo "$((d / 60))m ago"
  elif [ "$d" -lt 86400 ]; then echo "$((d / 3600))h ago"
  else echo "$((d / 86400))d ago"
  fi
}

echo "Claude Code sessions in $WS (newest first):"
echo
I=0
printf '%s\n' "$LINES" | while IFS="$(printf '\t')" read -r id mt kb summary; do
  I=$((I + 1))
  MARK=""
  [ -n "$PINNED" ] && [ "$id" = "$PINNED" ] && MARK="  <- pinned for resume"
  printf '  %2d. %-10s %-8s %6sKB  %s%s\n' \
    "$I" "$(printf '%.8s' "$id")" "$(age "$mt")" "$kb" "${summary:-—}" "$MARK"
done
echo
if [ -n "$PINNED" ]; then
  echo "Resumes will continue session $(printf '%.8s' "$PINNED")."
else
  echo "No session pinned yet — scheduling a resume pins the newest one"
  echo "automatically (override with --session)."
fi
echo "Pick one:  claude-standby resume-at auto --session <n>"
exit 0
