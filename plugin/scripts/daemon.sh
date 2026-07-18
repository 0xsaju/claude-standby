#!/usr/bin/env bash
# daemon.sh — detached wait-and-resume daemon for ONE workspace.
#
# Spawned by task-resume-at.sh (and later by on-stop.sh once detection
# exists) via: nohup daemon.sh <workspace> & disown
#
# Loop: wake every $AR_DAEMON_TICK_SECS (default 60), re-read state, compare
# wall clock against resume_at — never one long sleep, because laptop
# suspend breaks it. Stands down the moment status is no longer "waiting"
# (that is how /task-cancel stops a pending resume: state is the channel).
#
# Safety rails (C5): max_resumes enforced; failed resume attempts back off
# (AR_BACKOFF_BASE_SECS * attempt) instead of hammering; importance tiers:
#   critical -> resume with no confirmation
#   normal   -> notify, then auto-proceed after $AR_NORMAL_GRACE_SECS (60)
#   low      -> notify only, never auto-resume
#
# The claude binary is ${CLAUDE_AUTO_RESUME_CLAUDE_BIN:-claude} so tests run
# against test/fake-claude.sh (C6). Extra CLI args come from
# CLAUDE_AUTO_RESUME_EXTRA_ARGS / AR_CFG_EXTRA_ARGS (word-split on purpose);
# no --dangerously-skip-permissions unless the user opts in there.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh" || exit 0

WS="${1:-}"
[ -n "$WS" ] || exit 0

TICK="${AR_DAEMON_TICK_SECS:-60}"
GRACE="${AR_NORMAL_GRACE_SECS:-60}"
BACKOFF_BASE="${AR_BACKOFF_BASE_SECS:-300}"
PROBE_INTERVAL="${AR_PROBE_INTERVAL_SECS:-1800}"
PROBE_MODEL="${AR_PROBE_MODEL:-${AR_CFG_PROBE_MODEL:-haiku}}"
AUTO_GIVEUP="${AR_AUTO_GIVEUP_SECS:-21600}"
CLAUDE_BIN="${CLAUDE_AUTO_RESUME_CLAUDE_BIN:-${AR_CFG_CLAUDE_BIN:-claude}}"
EXTRA_ARGS="${CLAUDE_AUTO_RESUME_EXTRA_ARGS:-${AR_CFG_EXTRA_ARGS:-}}"

# One daemon per workspace: pidfile keyed by a hash of the path (kept
# outside state.json — the pid is host-local, not contract data; D11).
mkdir -p "$AR_HOME/daemons" 2>/dev/null
WS_HASH="$(printf '%s' "$WS" | cksum | awk '{print $1}')"
PIDFILE="$AR_HOME/daemons/$WS_HASH.pid"
if [ -f "$PIDFILE" ]; then
  OLD_PID="$(cat "$PIDFILE" 2>/dev/null)"
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    ar_log "daemon: pid $OLD_PID already watches $WS — exiting"
    exit 0
  fi
fi
printf '%s\n' "$$" > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT
trap 'rm -f "$PIDFILE"; exit 0' TERM INT

ar_log "daemon[$$]: watching $WS (tick=${TICK}s)"
AUTO_START="$(date +%s)"

stand_down() {
  ar_log "daemon[$$]: $1 — standing down"
  exit 0
}

PROBE_OUT=""
do_probe() {
  # Reset detection with a minimal cheap call (D13). "Still limited" means
  # nonzero exit OR the measured limit message in the output — exit codes
  # alone are not trusted because claude may exit 0 while limited
  # (HOOK-FINDINGS F1: exit code unmeasured). Output is kept in PROBE_OUT
  # so the caller can extract the announced reset time.
  local rc
  PROBE_OUT="$("$CLAUDE_BIN" -p "ok" --model "$PROBE_MODEL" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] && return 1
  case "$PROBE_OUT" in
    *"$AR_LIMIT_PATTERN"*) return 1 ;;
  esac
  return 0
}

do_resume() {
  # $1: attempt number. Returns the claude exit code.
  local attempt="$1" session_id prompt out rc
  session_id="$(ar_task_get "$WS" session_id)"
  prompt="$(ar_task_get "$WS" resume_prompt_template)"
  [ -n "$prompt" ] || prompt="$AR_DEFAULT_RESUME_PROMPT"

  ar_task_upsert "$WS" "status=resuming" "resume_count=$attempt"
  ar_journal_append "$WS" "resumed" "attempt $attempt of $MAX"

  set -- -p "$prompt"
  if [ -n "$session_id" ]; then
    set -- --resume "$session_id" "$@"
  fi
  ar_log "daemon[$$]: exec $CLAUDE_BIN $* $EXTRA_ARGS (attempt $attempt)"
  # shellcheck disable=SC2086
  out="$(cd "$WS" 2>/dev/null && "$CLAUDE_BIN" "$@" $EXTRA_ARGS 2>&1)"
  rc=$?
  ar_task_set "$WS" last_output_tail "$(printf '%s' "$out" | tail -c 1500)"
  ar_log "daemon[$$]: attempt $attempt exited $rc"
  # A resume that bounced off a still-active limit may still exit 0
  # (HOOK-FINDINGS F1) — never let that count as success.
  case "$out" in
    *"$AR_LIMIT_PATTERN"*)
      ar_log "daemon[$$]: attempt $attempt output contains the limit message — treating as failed"
      return 1
      ;;
  esac
  return "$rc"
}

while :; do
  STATUS="$(ar_task_get "$WS" status)"
  [ "$STATUS" = "waiting" ] || stand_down "status is '${STATUS:-<none>}'"

  RESUME_AT="$(ar_task_get "$WS" resume_at)"
  TARGET="$(ar_iso_to_epoch "$RESUME_AT")" || TARGET=""
  if [ -z "$TARGET" ]; then
    ar_task_set "$WS" status failed
    ar_journal_append "$WS" "failed" "unparseable resume_at: '$RESUME_AT'"
    ar_notify "Auto-resume failed" "Could not parse resume time for $WS"
    stand_down "unparseable resume_at"
  fi

  NOW="$(date +%s)"
  if [ "$NOW" -lt "$TARGET" ]; then
    sleep "$TICK"
    continue
  fi

  # In auto mode, resume_at is the NEXT PROBE time, not a known reset
  # time: probe first, and only fall through to resuming once the limit
  # has provably lifted. Probe failures don't count against max_resumes.
  RESUME_MODE="$(ar_task_get "$WS" resume_mode)"
  if [ "$RESUME_MODE" = "auto" ]; then
    if [ $((NOW - AUTO_START)) -ge "$AUTO_GIVEUP" ]; then
      ar_task_set "$WS" status failed
      ar_journal_append "$WS" "failed" "auto mode: limit did not lift within ${AUTO_GIVEUP}s (weekly cap?)"
      ar_notify "Auto-resume gave up" "Task in $WS: limit still active after $((AUTO_GIVEUP / 3600))h. If this is a weekly cap, schedule manually later."
      stand_down "auto give-up window exceeded"
    fi
    if ! do_probe; then
      # Best case: the limit message announces the reset time (measured
      # format, HOOK-FINDINGS F1) — wait for exactly that moment instead
      # of blind-polling. Sanity window: >1 min (avoid rescheduling to
      # tomorrow on boundary/clock skew) and <23 h.
      NOW="$(date +%s)"
      PARSED="$(ar_parse_reset_time "$PROBE_OUT")" || PARSED=""
      if [ -n "$PARSED" ] && [ "$PARSED" -gt $((NOW + 60)) ] && [ "$PARSED" -lt $((NOW + 82800)) ]; then
        NEXT_ISO="$(ar_epoch_to_iso "$PARSED")"
        ar_task_set "$WS" resume_at "$NEXT_ISO"
        ar_journal_append "$WS" "reset-detected" "limit message announces reset at $NEXT_ISO"
        ar_log "daemon[$$]: reset time read from limit message: $NEXT_ISO"
      elif [ -n "$PARSED" ]; then
        # Message parsed but the time is now/borderline — retry soon.
        NEXT_ISO="$(ar_epoch_to_iso $((NOW + 300)) )"
        ar_task_set "$WS" resume_at "$NEXT_ISO"
        ar_log "daemon[$$]: still limited at announced reset; retrying at $NEXT_ISO"
      else
        NEXT_ISO="$(ar_epoch_to_iso $((NOW + PROBE_INTERVAL)) )"
        ar_task_set "$WS" resume_at "$NEXT_ISO"
        ar_log "daemon[$$]: probe failed (still limited, no reset time in output); next probe at $NEXT_ISO"
      fi
      continue
    fi
    ar_journal_append "$WS" "limit-lifted" "probe succeeded — limit has reset"
    ar_log "daemon[$$]: probe succeeded — proceeding to resume"
  fi

  COUNT="$(ar_task_get "$WS" resume_count)"
  COUNT="${COUNT:-0}"
  MAX="$(ar_task_get "$WS" max_resumes)"
  MAX="${MAX:-3}"
  if [ "$COUNT" -ge "$MAX" ]; then
    ar_task_set "$WS" status failed
    ar_journal_append "$WS" "failed" "max_resumes ($MAX) reached"
    ar_notify "Auto-resume gave up" "Task in $WS hit the $MAX-resume cap"
    stand_down "max_resumes reached"
  fi

  IMPORTANCE="$(ar_task_get "$WS" importance)"
  case "$IMPORTANCE" in
    low)
      ar_task_set "$WS" status limit-hit
      ar_journal_append "$WS" "reset-reached" "low importance — manual resume required"
      ar_notify "Claude limit reset" "Task in $WS is ready. Importance is low, so resume it manually."
      stand_down "low importance: notified only"
      ;;
    normal)
      ar_notify "Claude limit reset" "Auto-resuming task in $WS in ${GRACE}s. Run /task-cancel to stop it."
      sleep "$GRACE"
      STATUS="$(ar_task_get "$WS" status)"
      [ "$STATUS" = "waiting" ] || stand_down "status changed to '$STATUS' during grace window"
      ;;
    *)
      ar_notify "Claude limit reset" "Auto-resuming critical task in $WS now."
      ;;
  esac

  ATTEMPT=$((COUNT + 1))
  if do_resume "$ATTEMPT"; then
    ar_task_set "$WS" status done
    ar_journal_append "$WS" "done" "resume attempt $ATTEMPT finished cleanly"
    ar_notify "Task finished" "Resumed task in $WS completed."
    stand_down "task done"
  fi

  if [ "$ATTEMPT" -ge "$MAX" ]; then
    ar_task_set "$WS" status failed
    ar_journal_append "$WS" "failed" "attempt $ATTEMPT exited nonzero; max_resumes reached"
    ar_notify "Auto-resume failed" "Task in $WS failed after $ATTEMPT attempts. See /task-status."
    stand_down "final attempt failed"
  fi

  # Attempt failed (likely resumed too early and bounced off the limit):
  # back off and keep waiting, still bounded by max_resumes.
  NEXT_EPOCH=$(( $(date +%s) + BACKOFF_BASE * ATTEMPT ))
  NEXT_ISO="$(ar_epoch_to_iso "$NEXT_EPOCH")"
  ar_task_upsert "$WS" "status=waiting" "resume_at=$NEXT_ISO"
  ar_journal_append "$WS" "resume-failed" "attempt $ATTEMPT exited nonzero; retrying at $NEXT_ISO"
  ar_notify "Resume attempt failed" "Task in $WS: retrying at $NEXT_ISO (attempt $ATTEMPT of $MAX used)."
done
