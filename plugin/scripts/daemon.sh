#!/usr/bin/env bash
# daemon.sh — detached wait-and-resume daemon for ONE workspace.
#
# Spawned by task-resume-at.sh via: nohup daemon.sh <workspace> & disown
#
# Loop: wake every $AR_DAEMON_TICK_SECS (default 60), re-read state, compare
# wall clock against resume_at — never one long sleep, because laptop
# suspend breaks it. Stands down the moment status is no longer "waiting"
# (that is how `claude-auto-resume cancel` stops a pending resume: state
# is the channel).
#
# Safety rails (C5): max_resumes enforced; failed resume attempts back off
# (AR_BACKOFF_BASE_SECS * attempt) instead of hammering; importance tiers:
#   critical -> resume with no confirmation
#   normal   -> notify, then auto-proceed after $AR_NORMAL_GRACE_SECS (300)
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
GRACE="${AR_NORMAL_GRACE_SECS:-300}"
# Safety buffer added AFTER a detected/announced reset before we actually
# attempt the resume. A resume fired at the exact reset instant (or a second
# early, from clock skew or the server rounding the window up) bounces off a
# still-active limit and wastes an attempt; waiting a beat avoids that.
RESET_GRACE="${AR_RESET_GRACE_SECS:-${AR_CFG_RESET_GRACE:-60}}"
# Never resume BEFORE the reset: a negative buffer would fire into a still-active
# limit. Clamp to >= 0 (also guards a non-numeric value).
case "$RESET_GRACE" in ''|*[!0-9]*) RESET_GRACE=60 ;; esac
BACKOFF_BASE="${AR_BACKOFF_BASE_SECS:-300}"
PROBE_INTERVAL="${AR_PROBE_INTERVAL_SECS:-1800}"
PROBE_MODEL="${AR_PROBE_MODEL:-${AR_CFG_PROBE_MODEL:-haiku}}"
AUTO_GIVEUP="${AR_AUTO_GIVEUP_SECS:-21600}"
# How long an auto-detect task stays armed (no limit ever observed) before
# it stands down instead of probing forever and burning quota (C6). 0 = no
# bound (probe until a limit appears or the user cancels). Default 24h.
ARMED_MAX="${AR_ARMED_MAX_SECS:-86400}"
# Auto mode uses the status-line sensor's rate.json (HOOK-FINDINGS F4) for the
# exact reset TIME once a limit is confirmed (quota-free). LIMIT_PCT is the
# used_percentage at which the sensor treats the account as limited (UNVERIFIED
# at a real limit — default 100, the conservative choice). Below it, we do NOT
# trust "not limited": a probe confirms (F4 must not blind F1).
LIMIT_PCT="${AR_LIMIT_PCT:-100}"
CLAUDE_BIN="${CLAUDE_AUTO_RESUME_CLAUDE_BIN:-${AR_CFG_CLAUDE_BIN:-claude}}"
EXTRA_ARGS="${CLAUDE_AUTO_RESUME_EXTRA_ARGS:-${AR_CFG_EXTRA_ARGS:-}}"

# One daemon per workspace: pidfile keyed by a hash of the path (kept
# outside state.json — the pid is host-local, not contract data; D11).
mkdir -p "$AR_HOME/daemons" 2>/dev/null
PIDFILE="$(ar_daemon_pidfile "$WS")"
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

# Record which process is watching this workspace, so the cockpit can tell
# a genuinely in-flight resume (this pid alive) from an interrupted one
# (status stuck at "resuming" but the daemon gone). Best-effort.
ar_task_set "$WS" daemon_pid "$$" 2>/dev/null || true

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
  if [ -n "$session_id" ]; then
    ar_journal_append "$WS" "resumed" "attempt $attempt of $MAX — continuing session $(printf '%.8s' "$session_id")"
  else
    ar_journal_append "$WS" "resumed" "attempt $attempt of $MAX — new session (none pinned)"
  fi

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
    [ -n "${AR_DAEMON_ONESHOT:-}" ] && stand_down "oneshot: not due yet"
    sleep "$TICK"
    continue
  fi

  # In auto mode, resume_at is the NEXT PROBE time, not a known reset
  # time: probe first, and only fall through to resuming once the limit
  # has provably lifted. Probe failures don't count against max_resumes.
  RESUME_MODE="$(ar_task_get "$WS" resume_mode)"
  if [ "$RESUME_MODE" = "auto" ]; then
    # A resume must only fire after a limit was actually OBSERVED and then
    # lifted. Without this, scheduling auto-detect while not currently
    # limited would make the first probe succeed and resume immediately —
    # injecting the resume prompt into a live, un-limited session. So we
    # gate on limit_seen: unset => "armed, waiting for a limit to appear".
    LIMIT_SEEN="$(ar_task_get "$WS" limit_seen)"
    # Give up only once a limit was seen but never lifts (measured from
    # when the limit was first observed, not from daemon start).
    if [ "$LIMIT_SEEN" = "1" ]; then
      SEEN_AT="$(ar_task_get "$WS" limit_seen_at)"; SEEN_AT="${SEEN_AT:-$AUTO_START}"
      if [ $((NOW - SEEN_AT)) -ge "$AUTO_GIVEUP" ]; then
        ar_task_set "$WS" status failed
        ar_journal_append "$WS" "failed" "auto mode: limit did not lift within ${AUTO_GIVEUP}s (weekly cap?)"
        ar_notify "Auto-resume gave up" "Task in $WS: limit still active after $((AUTO_GIVEUP / 3600))h. If this is a weekly cap, schedule manually later."
        stand_down "auto give-up window exceeded"
      fi
    fi

    # --- rate-sensor fast path (HOOK-FINDINGS F4) ------------------------
    # When the status-line sensor has captured a future reset time into
    # rate.json, use it: detection (used_percentage) and the EXACT reset
    # time come from local data — no probe, no quota. We fall through to the
    # probe path only when rate.json is absent or stale.
    RATE_RESUME=""
    if ar_rate_usable; then
      USED="$(ar_rate_get used_percentage)"; USED="${USED%%.*}"
      # Guard against a null/blank/non-numeric reading (e.g. JSON null -> "None"):
      # treat anything not all-digits as 0 so the -ge comparison can't error out.
      case "$USED" in ''|*[!0-9]*) USED=0 ;; esac
      RESETS_AT="$(ar_rate_get resets_at)"
      RESET_ISO="$(ar_epoch_to_iso "$RESETS_AT")"
      if [ "$USED" -ge "$LIMIT_PCT" ]; then
        # Limited per the sensor. Record it, then wait for the EXACT reset.
        if [ "$LIMIT_SEEN" != "1" ]; then
          ar_task_set "$WS" limit_seen 1
          ar_task_set "$WS" limit_seen_at "$NOW"
          ar_journal_append "$WS" "limit-hit" "sensor: ${USED}% used — waiting for reset $RESET_ISO"
        fi
        # Attempt the resume a safety beat AFTER the reset, not on the dot.
        RESET_TARGET=$(( RESETS_AT + RESET_GRACE ))
        RESET_TGT_ISO="$(ar_epoch_to_iso "$RESET_TARGET")"
        if [ "$NOW" -lt "$RESET_TARGET" ]; then
          ar_task_set "$WS" resume_at "$RESET_TGT_ISO"
          ar_log "daemon[$$]: sensor limited (${USED}%); reset $RESET_ISO, resuming $RESET_TGT_ISO (+${RESET_GRACE}s)"
          [ -n "${AR_DAEMON_ONESHOT:-}" ] && stand_down "oneshot: sensor limited, waiting for reset"
          continue
        fi
        ar_journal_append "$WS" "limit-lifted" "sensor: reset time reached (+${RESET_GRACE}s grace)"
        RATE_RESUME=1
      elif [ "$LIMIT_SEEN" = "1" ]; then
        # We saw a limit and usage has since dropped below the threshold —
        # the window reset. Resume.
        ar_journal_append "$WS" "limit-lifted" "sensor: usage fell to ${USED}% — limit reset"
        RATE_RESUME=1
      else
        # Sensor says NOT limited — but used_percentage at a real block is
        # unverified (C6) and can under-report, and F4 must not blind F1. So we
        # do NOT trust "not limited" from the sensor: fall through to the probe
        # (F1) as the detector, which arms, bounds (ARMED_MAX), and paces this
        # case on $PROBE_INTERVAL. The sensor still supplies the exact reset
        # TIME the moment a limit is actually confirmed (fast path above).
        ar_log "daemon[$$]: sensor ${USED}% (<${LIMIT_PCT}%); probing to confirm (reset would be $RESET_ISO)"
      fi
    fi

    if [ -z "$RATE_RESUME" ]; then
    if ! do_probe; then
      # Limit is active right now — record that we've seen it, so a later
      # successful probe counts as a real "lifted" and can resume.
      if [ "$LIMIT_SEEN" != "1" ]; then
        ar_task_set "$WS" limit_seen 1
        ar_task_set "$WS" limit_seen_at "$NOW"
        ar_journal_append "$WS" "limit-hit" "limit detected — waiting for it to reset"
      fi
      # Best case: the limit message announces the reset time (measured
      # format, HOOK-FINDINGS F1) — wait for exactly that moment instead
      # of blind-polling. Sanity window: >1 min (avoid rescheduling to
      # tomorrow on boundary/clock skew) and <23 h.
      NOW="$(date +%s)"
      PARSED="$(ar_parse_reset_time "$PROBE_OUT")" || PARSED=""
      if [ -n "$PARSED" ] && [ "$PARSED" -gt $((NOW + 60)) ] && [ "$PARSED" -lt $((NOW + 82800)) ]; then
        ANNOUNCED_ISO="$(ar_epoch_to_iso "$PARSED")"
        # Resume a safety beat after the announced reset, not on the dot.
        NEXT_ISO="$(ar_epoch_to_iso $((PARSED + RESET_GRACE)) )"
        ar_task_set "$WS" resume_at "$NEXT_ISO"
        ar_journal_append "$WS" "reset-detected" "limit message announces reset at $ANNOUNCED_ISO; resuming $NEXT_ISO (+${RESET_GRACE}s)"
        ar_log "daemon[$$]: reset from limit message $ANNOUNCED_ISO; resuming $NEXT_ISO (+${RESET_GRACE}s)"
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
      [ -n "${AR_DAEMON_ONESHOT:-}" ] && stand_down "oneshot: probed, still limited"
      continue
    fi
    # Probe succeeded. If we've NEVER seen a limit, this task is armed and
    # waiting — the current session is fine, so do NOT resume it. Keep
    # watching so a future limit (and its reset) triggers the resume.
    if [ "$LIMIT_SEEN" != "1" ]; then
      # Bound the armed window so an auto-detect scheduled on a healthy
      # session can't probe every $PROBE_INTERVAL forever (C6). Measured
      # from when arming began; ARMED_MAX=0 opts out (probe indefinitely).
      ARMED_SINCE="$(ar_task_get "$WS" armed_since)"
      if [ -z "$ARMED_SINCE" ]; then
        ARMED_SINCE="$NOW"
        ar_task_set "$WS" armed_since "$NOW"
      fi
      if [ "$ARMED_MAX" -gt 0 ] && [ $((NOW - ARMED_SINCE)) -ge "$ARMED_MAX" ]; then
        ar_task_set "$WS" status failed
        ar_journal_append "$WS" "failed" "armed ${ARMED_MAX}s with no limit — stood down; reschedule when you expect one"
        ar_notify "Auto-resume stood down" "No limit hit in $((ARMED_MAX / 3600))h for $WS. Reschedule when you expect to hit one."
        stand_down "armed window exceeded"
      fi
      NEXT_ISO="$(ar_epoch_to_iso $((NOW + PROBE_INTERVAL)) )"
      ar_task_set "$WS" resume_at "$NEXT_ISO"
      if [ "$(ar_task_get "$WS" armed_noted)" != "1" ]; then
        ar_task_set "$WS" armed_noted 1
        ar_journal_append "$WS" "armed" "not limited right now — will resume after you hit a limit and it resets"
      fi
      ar_log "daemon[$$]: armed (not limited); next check $NEXT_ISO"
      [ -n "${AR_DAEMON_ONESHOT:-}" ] && stand_down "oneshot: armed, not limited"
      continue
    fi
    ar_journal_append "$WS" "limit-lifted" "probe succeeded — limit has reset"
    ar_log "daemon[$$]: probe succeeded — proceeding to resume"
    fi
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
      ar_notify "Claude limit reset" "Auto-resuming task in $WS in ${GRACE}s. Stop it with: claude-auto-resume cancel"
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
    RESUME_RC=0
  else
    RESUME_RC=1
  fi

  # The user may have cancelled (or rescheduled) while the resume was in
  # flight — never overwrite a status someone else changed under us.
  STATUS="$(ar_task_get "$WS" status)"
  if [ "$STATUS" != "resuming" ]; then
    ar_journal_append "$WS" "resume-finished" "attempt $ATTEMPT ended after status became '$STATUS' — leaving it"
    stand_down "status changed to '$STATUS' during resume"
  fi

  if [ "$RESUME_RC" -eq 0 ]; then
    ar_task_set "$WS" status done
    ar_journal_append "$WS" "done" "resume attempt $ATTEMPT finished cleanly"
    ar_notify "Task finished" "Resumed task in $WS completed."
    stand_down "task done"
  fi

  if [ "$ATTEMPT" -ge "$MAX" ]; then
    ar_task_set "$WS" status failed
    ar_journal_append "$WS" "failed" "attempt $ATTEMPT exited nonzero; max_resumes reached"
    ar_notify "Auto-resume failed" "Task in $WS failed after $ATTEMPT attempts. See: claude-auto-resume status"
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
