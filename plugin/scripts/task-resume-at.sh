#!/usr/bin/env bash
# task-resume-at.sh — backend for `claude-standby resume-at`
#
# Post-limit scheduling: run this AFTER a limit already hit. No detection
# is needed — you read the reset time off the limit message yourself, and
# this schedules the daemon to resume the workspace then (D10). Also works
# before a limit, or to re-arm a failed task.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh" || { echo "auto-resume: failed to load lib.sh"; exit 0; }

USAGE='Usage: claude-standby resume-at [when] [critical|normal|low]
         [--session <n|id|latest|new>] [--prompt "<text>"] [--workspace <path>]
  [when] accepts:
    reset                      you just hit a limit: resume at the reset time
                               your usage data already knows (+ safety grace),
                               no probe, no quota
    (nothing) | auto           arm and watch: resume whenever a limit hits and
                               then lifts (uses live usage / a probe)
    2026-07-18T20:00:00+0600   ISO-8601 timestamp
    20:00                      clock time (next occurrence)
    2h30m | 45m | 3h           relative from now
    now                        immediately
  --session picks WHICH conversation to continue (see: claude-standby
  sessions). Default: the newest session in the workspace; "new" starts a
  fresh one.
  --prompt sets the message the resumed session receives (default:
  "Limit reset. Continue from where you stopped.")
  --workspace schedules for another project directory instead of the
  current one.'

# Pull the flags out of the argument list first (position-independent).
SESSION_ARG=""
PROMPT_ARG=""
WORKSPACE_ARG=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --session)     SESSION_ARG="${2:-latest}"; shift 2 || shift ;;
    --session=*)   SESSION_ARG="${1#--session=}"; shift ;;
    --prompt)      PROMPT_ARG="${2:-}"; shift 2 || shift ;;
    --prompt=*)    PROMPT_ARG="${1#--prompt=}"; shift ;;
    --workspace|-w) WORKSPACE_ARG="${2:-}"; shift 2 || shift ;;
    --workspace=*) WORKSPACE_ARG="${1#--workspace=}"; shift ;;
    *)             ARGS+=("$1"); shift ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

WHEN="${1:-auto}"
IMP="${2:-}"
# allow "resume-at critical" (tier only, auto-detect implied)
case "$WHEN" in
  critical|normal|low)
    IMP="$WHEN"
    WHEN="auto"
    ;;
esac
case "$IMP" in
  critical|normal|low|"") ;;
  *) echo "$USAGE"; exit 0 ;;
esac

parse_when() {
  # $1: time spec -> unix epoch on stdout, or nonzero.
  # All numeric fields are forced to base-10 (10#…) so a leading zero (08, 09)
  # is never mis-read as octal — which silently rescheduled 08:30 to 00:30 and
  # rejected 08h/09h outright (F02). Out-of-range clock fields are rejected.
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
    # 10# forces base-10 so "08h"/"09m" don't trip the octal parser.
    echo $((now + (10#$h) * 3600 + (10#$m) * 60))
    return 0
  fi
  if printf '%s' "$w" | grep -Eq '^[0-9]{1,2}:[0-9]{2}$'; then
    h=$((10#${w%%:*}))
    m=$((10#${w#*:}))
    # Reject nonsense clock values instead of letting date wrap them silently.
    if [ "$h" -gt 23 ] || [ "$m" -gt 59 ]; then
      return 1
    fi
    tz="$(date '+%z')"
    today="$(date '+%Y-%m-%d')"
    target="$(ar_iso_to_epoch "${today}T$(printf '%02d:%02d' "$h" "$m"):00$tz")" || return 1
    if [ "$target" -le "$now" ]; then
      target=$((target + 86400))
    fi
    echo "$target"
    return 0
  fi
  ar_iso_to_epoch "$w"
}

# Safety buffer added after a known reset before we attempt the resume, so a
# resume fired on the exact reset instant can't bounce off a still-active limit
# (same knob the daemon uses; D30).
RESET_GRACE="${AR_RESET_GRACE_SECS:-${AR_CFG_RESET_GRACE:-60}}"
case "$RESET_GRACE" in ''|*[!0-9]*) RESET_GRACE=60 ;; esac  # >= 0, numeric

RESUME_MODE="at"
CONFIRMED_LIMIT=""
if [ "$WHEN" = "auto" ]; then
  RESUME_MODE="auto"
  EPOCH="$(date +%s)"   # in auto mode, resume_at is the next probe time
elif [ "$WHEN" = "reset" ]; then
  # Situation A: you already hit the limit — you confirmed it, so we don't
  # consult used_percentage at all. Read the exact reset time from local usage
  # data (D29/F4) and schedule a known-time resume (+ safety grace). Falls back
  # with guidance when no local reset time exists.
  if ar_rate_usable; then
    RESET_EPOCH="$(ar_rate_get resets_at)"
    EPOCH=$(( RESET_EPOCH + RESET_GRACE ))
    CONFIRMED_LIMIT=1
  else
    echo "No local reset time found (no rate snapshot yet)."
    echo "Options:"
    echo "  claude-standby resume-at auto      # watch and resume when a limit hits"
    echo "  claude-standby resume-at <time>    # if you know the reset time"
    echo "  claude-standby setup-statusline    # capture it for next time"
    exit 0
  fi
else
  EPOCH="$(parse_when "$WHEN")" || EPOCH=""
fi
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
if [ -n "$WORKSPACE_ARG" ]; then
  if [ ! -d "$WORKSPACE_ARG" ]; then
    echo "Workspace '$WORKSPACE_ARG' is not a directory."
    exit 0
  fi
  WS="$(cd "$WORKSPACE_ARG" && pwd)"
else
  WS="$(pwd)"
fi

# --- session pinning (HOOK-FINDINGS F2/F3) --------------------------------
# The daemon resumes with `claude --resume <session_id>` so the ORIGINAL
# conversation continues. The id is pinned now, at schedule time, because
# the daemon's own probes create new sessions and would corrupt any
# "most recent" lookup done later.
# All identity/ownership decisions defer to lib.sh's canonical helpers
# (ar_is_uuid / ar_session_match_prefix / ar_session_resolve): strict UUID
# syntax, FIXED-STRING (never regex) prefix match, ambiguity is an error, and
# the resolved id's transcript `cwd` must equal this workspace before it can be
# pinned. That closes the wrong-session pins in F03 (regex prefix, all-hyphen
# "uuid", path-encoding collisions across workspaces).
#
# rc: 0 prints the id | 10 explicit "new" (start fresh) | 1 none | 2 ambiguous
#     | 3 resolved id belongs to a different workspace
resolve_session() {
  local want="$1" id rc
  case "$want" in
    new) return 10 ;;
    latest) want="" ;;   # documented alias for "newest in this workspace"
  esac
  if printf '%s' "$want" | grep -Eq '^[0-9]+$'; then
    # numeric index into the (newest-first) listing
    id="$(ar_sessions_list "$WS" | sed -n "${want}p" | cut -f1)"
    [ -n "$id" ] || return 1
    ar_session_belongs "$WS" "$id" || return 3
    printf '%s\n' "$id"
    return 0
  fi
  # "" (newest), an exact canonical UUID, or a fixed-string prefix — every
  # branch is ownership-verified inside ar_session_resolve.
  id="$(ar_session_resolve "$WS" "$want")"; rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$id"
  return "$rc"
}

session_refuse() {
  # $1: rc from resolve_session, $2: the requested value (for messaging)
  case "$1" in
    2) echo "Session '$2' is an ambiguous prefix — more than one matches."
       echo "Use the full id: claude-standby sessions" ;;
    3) echo "Session '$2' belongs to a different workspace — refusing to pin it."
       echo "List this workspace's sessions: claude-standby sessions" ;;
    *) echo "No session matches '--session $2'."
       echo "List them with: claude-standby sessions" ;;
  esac
}

if [ -n "$SESSION_ARG" ]; then
  SESSION_ID="$(resolve_session "$SESSION_ARG")"; RC=$?
  case "$RC" in
    0)  SESSION_SOURCE="picked" ;;
    10) SESSION_ID=""; SESSION_SOURCE="new" ;;   # --session new: start fresh
    *)  session_refuse "$RC" "$SESSION_ARG"; exit 0 ;;
  esac
else
  # No --session given. A previously pinned id is kept as-is (it was
  # ownership-checked when it was pinned). With no pin we refuse to guess:
  # silently starting a NEW chat contradicts the product promise of resuming
  # the SAME conversation, so require an explicit choice (F03).
  SESSION_ID="$(ar_task_get "$WS" session_id)"
  SESSION_SOURCE="kept"
  if [ -z "$SESSION_ID" ]; then
    SESSION_ID="$(resolve_session latest)"; RC=$?
    if [ "$RC" -eq 0 ]; then
      SESSION_SOURCE="latest"
    else
      echo "No session is pinned and none could be resolved for this workspace."
      echo "Pick the conversation to continue, or start a fresh one explicitly:"
      echo "  claude-standby sessions                    # list this workspace's sessions"
      echo "  claude-standby resume-at $WHEN --session <n|id>"
      echo "  claude-standby resume-at $WHEN --session new   # start a new chat"
      exit 0
    fi
  fi
fi

# limit_seen/armed_noted are reset every schedule so a re-arm never
# inherits a stale "already saw a limit" from a previous cycle (which
# would let auto-detect resume a non-limited session immediately). For a
# `reset` schedule you confirmed the limit yourself, so limit_seen=1.
# resume_count is reset too (D43): a schedule is a fresh attempt budget —
# carrying the spent count of a finished/failed cycle made the daemon
# fail fast at the max_resumes cap without ever attempting the resume.
LIMIT_SEEN_INIT=0
[ -n "$CONFIRMED_LIMIT" ] && LIMIT_SEEN_INIT=1
# F05: stamp a fresh generation token on every schedule. The daemon snapshots
# it and revalidates after grace + immediately before exec, so a schedule the
# user replaced never spends quota. Monotonic (prev+1) so two quick reschedules
# in the same second still differ.
NEW_GEN=$(( $(ar_uint "$(ar_task_get "$WS" resume_generation)" 0) + 1 ))
FIELDS=("status=waiting" "resume_at=$RESUME_AT" "resume_mode=$RESUME_MODE" "session_id=$SESSION_ID" "resume_count=0" "resume_generation=$NEW_GEN" "limit_seen=$LIMIT_SEEN_INIT" "limit_seen_at=" "armed_noted=0" "armed_since=" "daemon_pid=")
if [ -n "$PROMPT_ARG" ]; then
  FIELDS+=("resume_prompt_template=$PROMPT_ARG")
fi
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
if [ -n "$SESSION_ID" ]; then
  ar_journal_append "$WS" "session-pinned" "will continue session $(printf '%.8s' "$SESSION_ID") ($SESSION_SOURCE)"
elif [ "$SESSION_ARG" = "new" ]; then
  ar_journal_append "$WS" "session-pinned" "will start a fresh session (--session new)"
fi
if [ -n "$PROMPT_ARG" ]; then
  ar_journal_append "$WS" "prompt-set" "custom resume prompt: ${PROMPT_ARG:0:60}"
fi
ar_log "task-resume-at: ws=$WS mode=$RESUME_MODE resume_at=$RESUME_AT session=${SESSION_ID:-<new>}"

if [ -z "${AR_NO_DAEMON:-}" ]; then
  nohup bash "$SCRIPT_DIR/daemon.sh" "$WS" >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

echo "Resume scheduled."
echo "  workspace  : $WS"
if [ "$RESUME_MODE" = "auto" ]; then
  echo "  resume at  : auto-detect (probing every $(( ${AR_PROBE_INTERVAL_SECS:-1800} / 60 )) min until the limit lifts)"
else
  DELTA=$((EPOCH - $(date +%s)))
  [ "$DELTA" -lt 0 ] && DELTA=0
  if [ -n "$CONFIRMED_LIMIT" ]; then
    echo "  resume at  : $RESUME_AT (~$((DELTA / 60)) min) — exact reset from your usage data +${RESET_GRACE}s"
  else
    echo "  resume at  : $RESUME_AT (~$((DELTA / 60)) min from now)"
  fi
fi
if [ -n "$SESSION_ID" ]; then
  echo "  session    : $(printf '%.8s' "$SESSION_ID") — the original conversation continues (claude --resume)"
else
  echo "  session    : new chat (no existing session$( [ "$SESSION_ARG" = "new" ] && echo ' — --session new' ))"
fi
PROMPT_SHOW="$(ar_task_get "$WS" resume_prompt_template)"
if [ -n "$PROMPT_SHOW" ]; then
  if [ "${#PROMPT_SHOW}" -gt 60 ]; then PROMPT_SHOW="${PROMPT_SHOW:0:60}…"; fi
  echo "  prompt     : $PROMPT_SHOW"
fi
echo "  importance : $(ar_task_get "$WS" importance)"
echo "  daemon     : $([ -n "${AR_NO_DAEMON:-}" ] && echo 'not spawned (AR_NO_DAEMON)' || echo 'running detached, wakes every 60s')"
echo "Cancel any time with: claude-standby cancel   Watch: claude-standby status"
exit 0
