#!/usr/bin/env bash
# task-resume-at.sh — backend for /task-resume-at <when> [importance]
#
# Post-limit scheduling: run this AFTER a limit already hit. No detection
# is needed — you read the reset time off the limit message yourself, and
# this schedules the daemon to resume the workspace then (D10). Also works
# before a limit, or to re-arm a failed task.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh" || { echo "auto-resume: failed to load lib.sh"; exit 0; }

USAGE='Usage: /task-resume-at <when> [critical|normal|low]
  <when> accepts:
    2026-07-18T20:00:00+0600   ISO-8601 timestamp
    20:00                      clock time (next occurrence)
    2h30m | 45m | 3h           relative from now
    now                        immediately'

WHEN="${1:-}"
IMP="${2:-}"
if [ -z "$WHEN" ]; then
  echo "$USAGE"
  exit 0
fi
case "$IMP" in
  critical|normal|low|"") ;;
  *) echo "$USAGE"; exit 0 ;;
esac

parse_when() {
  # $1: time spec -> unix epoch on stdout, or nonzero
  local w="$1" now rest h m today tz target
  now="$(date +%s)"
  if [ "$w" = "now" ]; then
    echo "$now"
    return 0
  fi
  rest="${w#+}"
  if [ -n "$rest" ] && printf '%s' "$rest" | grep -Eq '^([0-9]+h)?([0-9]+m)?$'; then
    h=0; m=0
    case "$rest" in
      *h*) h="${rest%%h*}"; rest="${rest#*h}" ;;
    esac
    case "$rest" in
      *m) m="${rest%m}" ;;
    esac
    echo $((now + h * 3600 + m * 60))
    return 0
  fi
  if printf '%s' "$w" | grep -Eq '^[0-9]{1,2}:[0-9]{2}$'; then
    tz="$(date '+%z')"
    today="$(date '+%Y-%m-%d')"
    target="$(ar_iso_to_epoch "${today}T$(printf '%02d' "${w%%:*}"):${w#*:}:00$tz")" || return 1
    if [ "$target" -le "$now" ]; then
      target=$((target + 86400))
    fi
    echo "$target"
    return 0
  fi
  ar_iso_to_epoch "$w"
}

EPOCH="$(parse_when "$WHEN")" || EPOCH=""
if [ -z "$EPOCH" ]; then
  echo "Could not parse time '$WHEN'."
  echo "$USAGE"
  exit 0
fi
if [ -n "${AR_PARSE_ONLY:-}" ]; then
  echo "$EPOCH"
  exit 0
fi

RESUME_AT="$(ar_epoch_to_iso "$EPOCH")"
WS="$(pwd)"

FIELDS=("status=waiting" "resume_at=$RESUME_AT")
if ! ar_task_exists "$WS"; then
  # Untracked workspace being scheduled post-hoc: an explicit schedule
  # means "resume without asking", so default importance is critical.
  FIELDS+=("importance=${IMP:-critical}")
elif [ -n "$IMP" ]; then
  FIELDS+=("importance=$IMP")
fi

if ! ar_task_upsert "$WS" "${FIELDS[@]}"; then
  echo "auto-resume: could not write state file ($AR_STATE_FILE) — see $AR_LOG_DIR/plugin.log"
  exit 0
fi
ar_journal_append "$WS" "scheduled" "resume at $RESUME_AT"

if [ -z "${AR_NO_DAEMON:-}" ]; then
  nohup bash "$SCRIPT_DIR/daemon.sh" "$WS" >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

DELTA=$((EPOCH - $(date +%s)))
[ "$DELTA" -lt 0 ] && DELTA=0
echo "Resume scheduled."
echo "  workspace  : $WS"
echo "  resume at  : $RESUME_AT (~$((DELTA / 60)) min from now)"
echo "  importance : $(ar_task_get "$WS" importance)"
echo "  daemon     : $([ -n "${AR_NO_DAEMON:-}" ] && echo 'not spawned (AR_NO_DAEMON)' || echo 'running detached, wakes every 60s')"
echo "Cancel any time with /task-cancel. Watch with /task-status."
exit 0
