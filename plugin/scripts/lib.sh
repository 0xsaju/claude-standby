#!/usr/bin/env bash
# lib.sh — claude-standby core helpers: state.json access, logging,
# notifications, timestamps. Sourced by every plugin script.
#
# Portability (C2): runs on macOS (BSD userland) and Linux (GNU).
# JSON access degrades: jq -> python3 -> awk/sed text tier (DECISIONS D2).
# The text tier works because this library is the only writer of state.json
# and always writes the canonical 2-space-indent one-key-per-line layout
# that jq and python's json.dumps(indent=2) both produce.
#
# Nothing here may kill the caller or write to stderr (C4): failures log to
# $AR_LOG_DIR and return nonzero.

# ----------------------------------------------------------------- paths --

AR_STATE_FILE="${CLAUDE_STANDBY_STATE:-$HOME/.claude/auto-resume/state.json}"
AR_HOME="$(dirname "$AR_STATE_FILE")"
AR_LOG_DIR="${CLAUDE_STANDBY_LOG_DIR:-$AR_HOME/logs}"
# Rate-limit snapshot written by the status-line sensor (HOOK-FINDINGS F4):
# { captured_at, resets_at (epoch), used_percentage }.
AR_RATE_FILE="${CLAUDE_STANDBY_RATE_FILE:-$AR_HOME/rate.json}"

# Optional user config (shell syntax, AR_CFG_* variables only — see
# docs/USER-GUIDE.md). Environment variables always win over config values
# because consumers read ${CLAUDE_STANDBY_X:-${AR_CFG_X:-default}}.
AR_CONFIG_FILE="${CLAUDE_STANDBY_CONFIG:-$AR_HOME/config}"
if [ -f "$AR_CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$AR_CONFIG_FILE" 2>/dev/null || true
fi

# Task fields stored as JSON numbers, not strings.
AR_NUMERIC_FIELDS=" resume_count max_resumes "

AR_DEFAULT_RESUME_PROMPT="Limit reset. Continue from where you stopped."

# state.json schema version this build writes (F22). Older on-disk files that
# only added default-'' per-task fields stayed at 2, so both are accepted.
AR_SCHEMA_VERSION=3
AR_SUPPORTED_VERSIONS=" 2 3 "

# Journal entries retained per task; older ones are dropped so state.json can
# not grow without bound (F19). Resolved at use time (ar_journal_append) via the
# standard env-wins-over-config chain and coerced through ar_uint (F25).
AR_JOURNAL_MAX_FALLBACK=200

# Canonical per-task default object, shared by every jq code path so a task
# created by upsert and one auto-created by a journal-append are identical
# (F21). References the jq var $defprompt (pass --arg defprompt ...).
AR__DEFAULT_TASK_JQ='{
    "session_id": "",
    "status": "running",
    "importance": "normal",
    "original_prompt": "",
    "resume_at": "",
    "resume_mode": "at",
    "resume_count": 0,
    "max_resumes": 3,
    "limit_seen": "0",
    "limit_seen_at": "",
    "armed_noted": "0",
    "armed_since": "",
    "daemon_pid": "",
    "resume_prompt_template": $defprompt,
    "last_output_tail": "",
    "progress_file": "PROGRESS.md",
    "journal": []
  }'

# Substring that identifies a limit message. MEASURED — cite:
# docs/HOOK-FINDINGS.md F1 ("You've hit your session limit · resets ...").
AR_LIMIT_PATTERN="hit your session limit"

# ------------------------------------------------------------ timestamps --

ar_now_iso() {
  # ISO-8601 with numeric timezone, no colon (round-trips through %z parsers)
  date '+%Y-%m-%dT%H:%M:%S%z'
}

ar_iso_to_epoch() {
  # $1: ISO-8601 like 2026-07-18T13:00:00+0600 (tolerates +06:00 and a
  # trailing Z for UTC, e.g. from a third-party status-line cache)
  local iso="$1" norm
  # Colon-strip the offset for BSD %z, and turn a trailing Z into +0000.
  norm="$(printf '%s' "$iso" | sed 's/\([+-][0-9][0-9]\):\([0-9][0-9]\)$/\1\2/; s/Z$/+0000/')"
  date -j -f '%Y-%m-%dT%H:%M:%S%z' "$norm" '+%s' 2>/dev/null && return 0  # BSD
  date -d "$iso" '+%s' 2>/dev/null && return 0                            # GNU (handles Z)
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,datetime; print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")).timestamp()))' \
      "$iso" 2>/dev/null && return 0
  fi
  return 1
}

ar_epoch_to_iso() {
  # $1: unix epoch seconds
  date -r "$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null && return 0   # BSD
  date -d "@$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null && return 0  # GNU
  return 1
}

ar__date_field() {
  # $1: epoch seconds, $2: strftime field (e.g. %H) -> value on stdout.
  # BSD (date -r) then GNU (date -d @). rc 1 if neither works.
  date -r "$1" "+$2" 2>/dev/null && return 0   # BSD
  date -d "@$1" "+$2" 2>/dev/null && return 0  # GNU
  return 1
}

ar_parse_reset_time() {
  # $1: text containing a limit message in the MEASURED format
  # (docs/HOOK-FINDINGS.md F1):
  #   "You've hit your session limit · resets 4:10pm (Asia/Dhaka)"
  # -> epoch of the NEXT occurrence of that wall-clock time, on stdout.
  # Uses the zone's current UTC offset (no DST-transition handling; a
  # reset is always < 24h away so this is at most a rare 1h skew).
  local text="$1" t zone hh mm rest ampm today offset iso target now
  t="$(printf '%s' "$text" | sed -n 's/.*resets[[:space:]]*\([0-9][0-9]\{0,1\}:[0-9][0-9][ap]m\).*/\1/p' | head -1)"
  [ -n "$t" ] || return 1
  zone="$(printf '%s' "$text" | sed -n 's/.*resets[^(]*(\([A-Za-z0-9_/+-]*\)).*/\1/p' | head -1)"
  hh="${t%%:*}"
  rest="${t#*:}"
  mm="${rest%[ap]m}"
  ampm="${rest#"$mm"}"
  hh=$((10#$hh))
  mm=$((10#$mm))
  case "$ampm" in
    pm) [ "$hh" -ne 12 ] && hh=$((hh + 12)) ;;
    am) [ "$hh" -eq 12 ] && hh=0 ;;
  esac
  if [ -n "$zone" ]; then
    today="$(TZ="$zone" date '+%Y-%m-%d')"
    offset="$(TZ="$zone" date '+%z')"
  else
    today="$(date '+%Y-%m-%d')"
    offset="$(date '+%z')"
  fi
  iso="$(printf '%sT%02d:%02d:00%s' "$today" "$hh" "$mm" "$offset")"
  target="$(ar_iso_to_epoch "$iso")" || return 1
  now="$(date +%s)"
  if [ "$target" -le "$now" ]; then
    target=$((target + 86400))
  fi
  printf '%s\n' "$target"
}

# ------------------------------------------------------------ quiet hours --
# C5 quiet hours: an optional window of local time during which the daemon
# DEFERS an otherwise-ready auto-resume until the window closes (never earlier
# than the reset). Opt-in and OFF by default: both AR_CFG_QUIET_START and
# AR_CFG_QUIET_END must be set (24h local "HH" or "HH:MM"). Windows that cross
# midnight are supported (start > end, e.g. 22:00-07:00).

ar__hhmm_to_min() {
  # "HH" or "HH:MM" (24h) -> minutes since local midnight (0..1439) on stdout.
  # rc 1 on malformed / out-of-range input (fail closed: caller disables the
  # window). Base-10 forced so "08"/"09" are never read as octal.
  local v="$1" h m
  case "$v" in
    *:*) h="${v%%:*}"; m="${v#*:}" ;;
    *)   h="$v"; m=0 ;;
  esac
  case "$h" in ''|*[!0-9]*) return 1 ;; esac
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  h=$((10#$h)); m=$((10#$m))
  [ "$h" -ge 0 ] && [ "$h" -le 23 ] || return 1
  [ "$m" -ge 0 ] && [ "$m" -le 59 ] || return 1
  printf '%s\n' $((h * 60 + m))
}

ar_quiet_window_end() {
  # $1: reference epoch (default now). If it falls INSIDE the configured quiet
  # window, print the epoch at which the window closes (rc 0). Otherwise print
  # nothing (rc 1). Disabled (rc 1) unless both AR_CFG_QUIET_START and
  # AR_CFG_QUIET_END parse and differ.
  local now="${1:-$(date +%s)}" start end smin emin
  start="${AR_CFG_QUIET_START:-}"
  end="${AR_CFG_QUIET_END:-}"
  [ -n "$start" ] && [ -n "$end" ] || return 1
  smin="$(ar__hhmm_to_min "$start")" || return 1
  emin="$(ar__hhmm_to_min "$end")" || return 1
  [ "$smin" -eq "$emin" ] && return 1   # zero-length window => disabled
  local nh nm ns nmin midnight
  nh="$(ar__date_field "$now" %H)" || return 1
  nm="$(ar__date_field "$now" %M)" || return 1
  ns="$(ar__date_field "$now" %S)" || ns=0
  nh=$((10#$nh)); nm=$((10#$nm)); ns=$((10#$ns))
  nmin=$((nh * 60 + nm))
  # Local midnight for the reference instant, so the window end can be turned
  # back into an absolute epoch without another date parse.
  midnight=$((now - (nh * 3600 + nm * 60 + ns)))
  if [ "$smin" -lt "$emin" ]; then
    if [ "$nmin" -ge "$smin" ] && [ "$nmin" -lt "$emin" ]; then
      printf '%s\n' $((midnight + emin * 60)); return 0
    fi
  else
    # Crosses midnight: in-window on the evening side (>= start, ends tomorrow)
    # or the morning side (< end, ends today).
    if [ "$nmin" -ge "$smin" ]; then
      printf '%s\n' $((midnight + 86400 + emin * 60)); return 0
    elif [ "$nmin" -lt "$emin" ]; then
      printf '%s\n' $((midnight + emin * 60)); return 0
    fi
  fi
  return 1
}

# --------------------------------------------------------------- logging --

ar_log() {
  ar__ensure_private_dir "$AR_LOG_DIR" 2>/dev/null || return 0
  ( umask 077; printf '%s %s\n' "$(ar_now_iso)" "$*" >> "$AR_LOG_DIR/plugin.log" ) 2>/dev/null || true
  chmod 600 "$AR_LOG_DIR/plugin.log" 2>/dev/null || true
}

# ---------------------------------------------------------------- notify --

ar_notify() {
  # $1: title, $2: body. Best-effort, never blocks, never fails the caller.
  # Chain: osascript (macOS) -> notify-send (Linux) -> log only (D7).
  # AR_NOTIFY_SILENT=1 forces log-only (used by tests).
  local title="$1" body="${2:-}" t b
  if [ -n "${AR_NOTIFY_SILENT:-}" ]; then
    ar_log "notify(silent): $title — $body"
    return 0
  fi
  t="$(printf '%s' "$title" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  b="$(printf '%s' "$body" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  if command -v osascript >/dev/null 2>&1; then
    if osascript -e "display notification \"$b\" with title \"$t\"" >/dev/null 2>&1; then
      ar_log "notify(osascript): $title"
      return 0
    fi
  fi
  if command -v notify-send >/dev/null 2>&1; then
    if notify-send "$title" "$body" >/dev/null 2>&1; then
      ar_log "notify(notify-send): $title"
      return 0
    fi
  fi
  ar_log "notify(log-only): $title — $body"
  return 0
}

# ---------------------------------------------------- JSON string helpers --

ar_json_escape() {
  # $1 -> JSON string contents (no surrounding quotes). Emits well-formed
  # JSON: backslash/quote/tab/CR get their short escapes, every other C0
  # control byte (U+0000..U+001F, e.g. U+0001) becomes \u00XX, and a real
  # newline between input records becomes \n. Char-by-char so a literal
  # backslash-n round-trips as \\n, not a corrupt \n (F21).
  printf '%s' "$1" | awk '
    BEGIN {
      ORS = ""; first = 1
      for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
    }
    {
      if (!first) printf "\\n"
      first = 0
      s = $0; n = length(s)
      for (j = 1; j <= n; j++) {
        c = substr(s, j, 1); b = ord[c]
        if (c == "\\") printf "\\\\"
        else if (c == "\"") printf "\\\""
        else if (c == "\t") printf "\\t"
        else if (c == "\r") printf "\\r"
        else if (b != "" && (b + 0) < 32) printf "\\u%04x", (b + 0)
        else printf "%s", c
      }
    }'
}

ar_json_unescape() {
  # Inverse of ar_json_escape for the text tier: single left-to-right pass so
  # \\ is consumed before an following n is misread as a newline (F21).
  # Decodes \n \t \r \" \\ \/ and \u00XX (control-range) back to raw bytes.
  printf '%s' "$1" | awk '
    BEGIN {
      ORS = ""
      hex = "0123456789abcdef"
      for (i = 0; i < 16; i++) {
        d = substr(hex, i + 1, 1); hv[d] = i; hv[toupper(d)] = i
      }
    }
    {
      if (NR > 1) printf "\n"
      s = $0; n = length(s)
      for (j = 1; j <= n; j++) {
        c = substr(s, j, 1)
        if (c == "\\" && j < n) {
          d = substr(s, j + 1, 1)
          if (d == "n") { printf "\n"; j++ }
          else if (d == "t") { printf "\t"; j++ }
          else if (d == "r") { printf "\r"; j++ }
          else if (d == "\"") { printf "\""; j++ }
          else if (d == "\\") { printf "\\"; j++ }
          else if (d == "/") { printf "/"; j++ }
          else if (d == "u" && j + 5 <= n) {
            h = substr(s, j + 2, 4)
            code = hv[substr(h,1,1)] * 4096 + hv[substr(h,2,1)] * 256 \
                 + hv[substr(h,3,1)] * 16 + hv[substr(h,4,1)]
            printf "%c", code
            j += 5
          }
          else printf "%s", c
        } else {
          printf "%s", c
        }
      }
    }'
}

ar__is_numeric_field() {
  case "$AR_NUMERIC_FIELDS" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

ar__is_number() {
  printf '%s' "$1" | grep -q '^[0-9][0-9]*$'
}

ar_uint() {
  # Validate/coerce a value to a bounded NON-NEGATIVE INTEGER, failing closed
  # on garbage (F20/F25). Used for safety caps (max_resumes) and timing config.
  #   $1: value  $2: fallback (default 0)  $3: optional inclusive max (clamp)
  # Prints the resulting integer on stdout. Returns 0 when $1 was already a
  # clean in-range non-negative integer, 1 when it had to fall back or clamp —
  # so callers can either trust the printed value or notice the coercion.
  local v="$1" def="${2:-0}" max="${3:-}" out rc=0
  case "$v" in
    ''|*[!0-9]*) out="$def"; rc=1 ;;
    *) out=$((10#$v)) ;;   # base-10 so leading zeros never mean octal
  esac
  case "$out" in ''|*[!0-9]*) out=0 ;; esac   # sanitize a garbage fallback too
  if [ -n "$max" ]; then
    case "$max" in ''|*[!0-9]*) max="" ;; esac
    if [ -n "$max" ] && [ "$out" -gt "$max" ]; then out="$max"; rc=1; fi
  fi
  printf '%s\n' "$out"
  return $rc
}

# ------------------------------------------------------------ state: core --

ar_json_engine() {
  if [ -n "${AR_JSON_ENGINE:-}" ]; then
    printf '%s\n' "$AR_JSON_ENGINE"
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    echo jq
  elif command -v python3 >/dev/null 2>&1; then
    echo python3
  else
    echo text
  fi
}

ar__ensure_private_dir() {
  # Create $1 (and parents) owner-only. Runtime data holds prompts, session
  # ids, and output tails, so it must not be world-readable (F13). Existing
  # dirs are tightened best-effort. Never fails the caller loudly.
  [ -n "$1" ] || return 1
  if [ -d "$1" ]; then
    chmod 700 "$1" 2>/dev/null
    return 0
  fi
  ( umask 077; mkdir -p "$1" ) 2>/dev/null
  chmod 700 "$1" 2>/dev/null
  [ -d "$1" ]
}

# ---------------------------------------------- state: read-modify-write lock --
# A whole read-modify-write of state.json (upsert/journal-append) is NOT atomic
# on its own — every writer reads, edits, then replaces the entire file, so
# concurrent writers lose each other's updates (F15). Serialize the transaction
# with a mkdir-based mutex: mkdir is atomic on POSIX filesystems and works on
# bash 3.2/macOS with no flock dependency (C2).

ar__lock_dir() { printf '%s\n' "${AR_STATE_FILE}.lock"; }

ar_lock_acquire() {
  # Best-effort mutex. rc 0 on acquire, 1 on give-up. A lock older than
  # AR_LOCK_STALE seconds is presumed abandoned (writer died) and stolen.
  local d now age i=0
  local wait_ticks stale
  wait_ticks="$(ar_uint "${AR_LOCK_WAIT:-100}" 100)"   # * ~0.1s ≈ 10s
  stale="$(ar_uint "${AR_LOCK_STALE:-30}" 30)"          # seconds
  d="$(ar__lock_dir)"
  ar__ensure_private_dir "$(dirname "$AR_STATE_FILE")"
  while :; do
    if ( umask 077; mkdir "$d" ) 2>/dev/null; then
      printf '%s\n' "$$" > "$d/pid" 2>/dev/null
      return 0
    fi
    now="$(date +%s 2>/dev/null || echo 0)"
    age="$(ar__file_mtime "$d" 2>/dev/null)"; age="${age:-$now}"
    if [ "$((now - age))" -ge "$stale" ]; then
      rm -rf "$d" 2>/dev/null
      continue
    fi
    i=$((i + 1))
    if [ "$i" -ge "$wait_ticks" ]; then
      ar_log "WARN: state lock wait timed out ($d)"
      return 1
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
}

ar_lock_release() {
  rm -f "$(ar__lock_dir)/pid" 2>/dev/null
  rmdir "$(ar__lock_dir)" 2>/dev/null || true
}

ar_state_write() {
  # stdin -> state file, atomically (temp file in same dir + mv).
  # Refuses to clobber state with empty content. Files/dirs stay owner-only (F13).
  ar__ensure_private_dir "$(dirname "$AR_STATE_FILE")"
  local tmp="$AR_STATE_FILE.tmp.$$"
  if ( umask 077; cat > "$tmp" ) 2>/dev/null && [ -s "$tmp" ]; then
    chmod 600 "$tmp" 2>/dev/null
    mv "$tmp" "$AR_STATE_FILE"
    chmod 600 "$AR_STATE_FILE" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
    ar_log "ERROR: state write failed (empty content or unwritable dir)"
    return 1
  fi
}

ar_state_init() {
  [ -f "$AR_STATE_FILE" ] && return 0
  ar_state_write <<EOF
{
  "version": $AR_SCHEMA_VERSION,
  "tasks": {},
  "commands": []
}
EOF
}

ar_state_health() {
  # Classify the loaded state so doctor/daemon can fail closed (F22).
  # Prints one of: ok | corrupt | unsupported | missing.
  # rc: 0 ok, 1 corrupt, 2 unsupported, 3 missing.
  local f="${1:-$AR_STATE_FILE}" eng ver
  [ -f "$f" ] || { printf 'missing\n'; return 3; }
  eng="$(ar_json_engine)"
  case "$eng" in
    jq)
      if ! jq -e '(.tasks|type)=="object" and (.commands|type)=="array" and (.version|type)=="number"' \
           "$f" >/dev/null 2>&1; then
        printf 'corrupt\n'; return 1
      fi
      ver="$(jq -r '.version' "$f" 2>/dev/null)"
      ;;
    python3)
      ver="$(python3 - "$f" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("__CORRUPT__"); raise SystemExit
if (not isinstance(d, dict)
        or not isinstance(d.get("tasks"), dict)
        or not isinstance(d.get("commands"), list)
        or isinstance(d.get("version"), bool)
        or not isinstance(d.get("version"), int)):
    print("__CORRUPT__"); raise SystemExit
print(d["version"])
PY
)"
      if [ "$ver" = "__CORRUPT__" ] || [ -z "$ver" ]; then
        printf 'corrupt\n'; return 1
      fi
      ;;
    *)
      # text tier: coarse structural check on the canonical layout.
      if ! grep -q '"tasks"' "$f" 2>/dev/null || ! grep -q '"commands"' "$f" 2>/dev/null; then
        printf 'corrupt\n'; return 1
      fi
      ver="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$f" 2>/dev/null | head -1)"
      [ -n "$ver" ] || { printf 'corrupt\n'; return 1; }
      ;;
  esac
  case "$AR_SUPPORTED_VERSIONS" in
    *" $ver "*) printf 'ok\n'; return 0 ;;
    *)          printf 'unsupported\n'; return 2 ;;
  esac
}

# ------------------------------------------------------- state: jq engine --

ar__jq_upsert() {
  local ws="$1"; shift
  local prog=".tasks[\$ws] = (.tasks[\$ws] // $AR__DEFAULT_TASK_JQ)"
  local args=(--arg ws "$ws" --arg defprompt "$AR_DEFAULT_RESUME_PROMPT")
  local i=0 pair f v
  for pair in "$@"; do
    f="${pair%%=*}"
    v="${pair#*=}"
    args+=(--arg "f$i" "$f")
    if ar__is_numeric_field "$f" && ar__is_number "$v"; then
      args+=(--argjson "v$i" "$v")
    else
      args+=(--arg "v$i" "$v")
    fi
    prog="$prog | .tasks[\$ws][\$f$i] = \$v$i"
    i=$((i + 1))
  done
  jq "${args[@]}" "$prog" "$AR_STATE_FILE" 2>/dev/null
}

# -------------------------------------------------- state: python3 engine --

ar__py() {
  # $1: op (get|upsert|journal|journal_show), rest: op args
  python3 - "$AR_STATE_FILE" "$AR_DEFAULT_RESUME_PROMPT" "$@" <<'PY' 2>/dev/null
import json, sys

path, defprompt, op = sys.argv[1], sys.argv[2], sys.argv[3]
rest = sys.argv[4:]

DEFAULTS = {
    "session_id": "", "status": "running", "importance": "normal",
    "original_prompt": "", "resume_at": "", "resume_mode": "at",
    "resume_count": 0,
    "max_resumes": 3,
    "limit_seen": "0", "limit_seen_at": "", "armed_noted": "0",
    "armed_since": "", "daemon_pid": "",
    "resume_prompt_template": defprompt,
    "last_output_tail": "", "progress_file": "PROGRESS.md", "journal": [],
}
NUMERIC = {"resume_count", "max_resumes"}

with open(path) as fh:
    state = json.load(fh)
tasks = state.setdefault("tasks", {})

if op == "get":
    ws, field = rest
    v = tasks.get(ws, {}).get(field, "")
    print(json.dumps(v) if isinstance(v, (dict, list)) else v)
elif op == "upsert":
    ws = rest[0]
    t = tasks.setdefault(ws, dict(DEFAULTS))
    for pair in rest[1:]:
        f, _, v = pair.partition("=")
        if f in NUMERIC and v.isdigit():
            v = int(v)
        t[f] = v
    print(json.dumps(state, indent=2))
elif op == "journal":
    ws, ts, event, detail = rest[0], rest[1], rest[2], rest[3]
    cap = int(rest[4]) if len(rest) > 4 and rest[4].isdigit() else 0
    t = tasks.setdefault(ws, dict(DEFAULTS))
    j = t.setdefault("journal", [])
    j.append({"ts": ts, "event": event, "detail": detail})
    if cap > 0 and len(j) > cap:
        t["journal"] = j[-cap:]
    print(json.dumps(state, indent=2))
elif op == "list":
    for k in tasks:
        print(k)
elif op == "journal_show":
    ws, n = rest[0], int(rest[1])
    for e in tasks.get(ws, {}).get("journal", [])[-n:]:
        print("  %s  %s  %s" % (e.get("ts", ""), e.get("event", ""), e.get("detail", "")))
PY
}

# ----------------------------------------------------- state: text engine --
# Line-oriented awk over the canonical layout (DECISIONS D2). Values reach
# awk via ENVIRON, never -v, so backslashes survive untouched.

ar__text_task_get() {
  local ws_esc raw
  ws_esc="$(ar_json_escape "$1")"
  [ -f "$AR_STATE_FILE" ] || return 0
  raw="$(AR_K="    \"$ws_esc\": {" AR_F="$2" awk '
    BEGIN { key = ENVIRON["AR_K"]; f = ENVIRON["AR_F"] }
    intask && !injournal {
      if (index($0, "      \"" f "\":") == 1) {
        line = $0
        sub(/^      "[^"]*": /, "", line)
        sub(/,$/, "", line)
        print line
        exit
      }
      if (index($0, "      \"journal\":") == 1) injournal = 1
    }
    intask && ($0 == "    }" || $0 == "    },") { exit }
    $0 == key { intask = 1 }
  ' "$AR_STATE_FILE")"
  case "$raw" in
    \"*\")
      ar_json_unescape "$(printf '%s' "$raw" | sed 's/^"//; s/"$//')"
      echo
      ;;
    *)
      [ -n "$raw" ] && printf '%s\n' "$raw"
      ;;
  esac
}

ar__text_task_exists() {
  local ws_esc
  ws_esc="$(ar_json_escape "$1")"
  [ -f "$AR_STATE_FILE" ] || return 1
  grep -F "    \"$ws_esc\": {" "$AR_STATE_FILE" >/dev/null 2>&1
}

ar__text_insert_task() {
  # stdin: state content; stdout: content with a default task block added
  AR_K="\"$(ar_json_escape "$1")\"" AR_DP="$(ar_json_escape "$AR_DEFAULT_RESUME_PROMPT")" awk '
    function block(suffix) {
      print "    " ENVIRON["AR_K"] ": {"
      print "      \"session_id\": \"\","
      print "      \"status\": \"running\","
      print "      \"importance\": \"normal\","
      print "      \"original_prompt\": \"\","
      print "      \"resume_at\": \"\","
      print "      \"resume_mode\": \"at\","
      print "      \"resume_count\": 0,"
      print "      \"max_resumes\": 3,"
      print "      \"limit_seen\": \"0\","
      print "      \"limit_seen_at\": \"\","
      print "      \"armed_noted\": \"0\","
      print "      \"armed_since\": \"\","
      print "      \"daemon_pid\": \"\","
      print "      \"resume_prompt_template\": \"" ENVIRON["AR_DP"] "\","
      print "      \"last_output_tail\": \"\","
      print "      \"progress_file\": \"PROGRESS.md\","
      print "      \"journal\": []"
      print "    }" suffix
    }
    $0 == "  \"tasks\": {}," { print "  \"tasks\": {"; block(""); print "  },"; next }
    $0 == "  \"tasks\": {}"  { print "  \"tasks\": {"; block(""); print "  }";  next }
    $0 == "  \"tasks\": {"   { print; block(","); next }
    { print }
  '
}

ar__text_set_field() {
  # stdin: state content; $1: ws, $2: field, $3: rendered JSON value.
  # Updates the field in place; if the task has no such line yet (e.g. a
  # field added after the task was created), it is INSERTED just before the
  # journal, so ar_task_set works for any field — matching the jq/python3
  # engines. Without this, unknown fields were silently dropped.
  AR_K="    \"$(ar_json_escape "$1")\": {" AR_F="$2" AR_V="$3" awk '
    BEGIN { key = ENVIRON["AR_K"]; f = ENVIRON["AR_F"]; nv = ENVIRON["AR_V"]; found = 0 }
    intask && !injournal && index($0, "      \"" f "\":") == 1 {
      comma = ($0 ~ /,$/) ? "," : ""
      print "      \"" f "\": " nv comma
      found = 1; intask = 0; next
    }
    intask && !injournal && index($0, "      \"journal\":") == 1 {
      if (!found) { print "      \"" f "\": " nv "," }
      found = 1; injournal = 1; print; next
    }
    intask && ($0 == "    }" || $0 == "    },") { intask = 0 }
    $0 == key { intask = 1 }
    { print }
  '
}

ar__text_upsert() {
  local ws="$1"; shift
  local content pair f v v_out
  content="$(cat "$AR_STATE_FILE")"
  if ! ar__text_task_exists "$ws"; then
    content="$(printf '%s\n' "$content" | ar__text_insert_task "$ws")"
  fi
  for pair in "$@"; do
    f="${pair%%=*}"
    v="${pair#*=}"
    if ar__is_numeric_field "$f" && ar__is_number "$v"; then
      v_out="$v"
    else
      v_out="\"$(ar_json_escape "$v")\""
    fi
    content="$(printf '%s\n' "$content" | ar__text_set_field "$ws" "$f" "$v_out")"
  done
  printf '%s\n' "$content"
}

ar__text_journal_trim() {
  # stdin: state content; $1: ws, $2: cap -> content with ws's journal kept to
  # its last $2 entries (F19). A no-op when $2 <= 0 or the journal is short.
  # The text engine writes each entry as ONE line, so trimming keeps the last N
  # single-line entries. To stay safe if the file was written by jq/python
  # (which pretty-print each entry over several lines), the trim BAILS to a
  # verbatim pass-through unless every entry is a single line — it never
  # corrupts a multi-line entry.
  [ "${2:-0}" -gt 0 ] 2>/dev/null || { cat; return 0; }
  AR_K="    \"$(ar_json_escape "$1")\": {" AR_MAX="$2" awk '
    BEGIN { key = ENVIRON["AR_K"]; max = ENVIRON["AR_MAX"] + 0 }
    { L[NR] = $0 }
    END {
      n = NR
      # locate the target task, then its journal open/close lines
      ts = 0
      for (i = 1; i <= n; i++) if (L[i] == key) { ts = i; break }
      if (!ts) { for (i = 1; i <= n; i++) print L[i]; exit }
      js = 0; je = 0
      for (i = ts + 1; i <= n; i++) {
        if (L[i] == "      \"journal\": [") { js = i; continue }
        if (js && (L[i] == "      ]" || L[i] == "      ],")) { je = i; break }
        if (!js && (L[i] == "    }" || L[i] == "    },")) break   # empty/[] journal
      }
      if (!js || !je) { for (i = 1; i <= n; i++) print L[i]; exit }
      # are all entries single-line? count them
      allsingle = 1; cnt = 0
      for (i = js + 1; i < je; i++) {
        e = L[i]; sub(/,$/, "", e)
        if (e ~ /^        \{.*\}$/) cnt++
        else { allsingle = 0; break }
      }
      if (!allsingle || cnt <= max) { for (i = 1; i <= n; i++) print L[i]; exit }
      keepfrom = (js + 1) + (cnt - max)
      for (i = 1; i <= n; i++) {
        if (i > js && i < je) {
          if (i < keepfrom) continue
          e = L[i]; sub(/,$/, "", e)
          print e ((i < je - 1) ? "," : "")
        } else print L[i]
      }
    }
  '
}

ar__text_journal_append() {
  # $1: ws, $2: ts, $3: event, $4: detail, $5: journal cap -> new content on stdout
  local ws="$1" entry max="${5:-0}"
  entry="{ \"ts\": \"$(ar_json_escape "$2")\", \"event\": \"$(ar_json_escape "$3")\", \"detail\": \"$(ar_json_escape "${4:-}")\" }"
  local content
  content="$(cat "$AR_STATE_FILE")"
  if ! ar__text_task_exists "$ws"; then
    content="$(printf '%s\n' "$content" | ar__text_insert_task "$ws")"
  fi
  printf '%s\n' "$content" | AR_K="    \"$(ar_json_escape "$ws")\": {" AR_E="        $entry" awk '
    BEGIN { key = ENVIRON["AR_K"]; entry = ENVIRON["AR_E"]; prev = "" }
    injournal && ($0 == "      ]" || $0 == "      ],") {
      if (prev != "") print prev ","
      print entry
      print $0
      injournal = 0
      done = 1
      next
    }
    injournal { if (prev != "") print prev; prev = $0; next }
    intask && !done && ($0 == "      \"journal\": []" || $0 == "      \"journal\": [],") {
      suffix = ($0 ~ /,$/) ? "," : ""
      print "      \"journal\": ["
      print entry
      print "      ]" suffix
      done = 1
      next
    }
    intask && !done && $0 == "      \"journal\": [" { print; injournal = 1; prev = ""; next }
    intask && ($0 == "    }" || $0 == "    },") { intask = 0 }
    $0 == key && !done { intask = 1 }
    { print }
  ' | ar__text_journal_trim "$ws" "$max"
}

ar__text_journal_show() {
  # $1: ws, $2: max lines — raw journal lines (display only)
  local ws_esc
  ws_esc="$(ar_json_escape "$1")"
  [ -f "$AR_STATE_FILE" ] || return 0
  AR_K="    \"$ws_esc\": {" awk '
    BEGIN { key = ENVIRON["AR_K"] }
    injournal { if ($0 == "      ]" || $0 == "      ],") exit; print; next }
    intask && index($0, "      \"journal\": [") == 1 { if ($0 ~ /\]/) exit; injournal = 1; next }
    intask && ($0 == "    }" || $0 == "    },") { exit }
    $0 == key { intask = 1 }
  ' "$AR_STATE_FILE" | tail -n "${2:-10}"
}

# ------------------------------------------------------- state: public API --

ar_task_get() {
  # $1: workspace, $2: field -> value on stdout ("" if absent)
  local eng
  eng="$(ar_json_engine)"
  case "$eng" in
    jq)
      jq -r --arg ws "$1" --arg f "$2" \
        '.tasks[$ws][$f] // "" | if type == "object" or type == "array" then tojson else tostring end' \
        "$AR_STATE_FILE" 2>/dev/null
      ;;
    python3) ar__py get "$1" "$2" ;;
    *) ar__text_task_get "$1" "$2" ;;
  esac
}

ar_task_exists() {
  # $1: workspace
  [ -n "$(ar_task_get "$1" status)" ]
}

ar_task_upsert() {
  # $1: workspace, rest: field=value pairs. Creates the task with schema
  # defaults if missing, then applies the pairs. The whole read-modify-write
  # is serialized under the state lock so concurrent writers don't clobber each
  # other (F15). Atomic write.
  local ws="$1"; shift
  ar_state_init || return 1
  ar_lock_acquire || return 1
  local eng new rc=0
  eng="$(ar_json_engine)"
  case "$eng" in
    jq) new="$(ar__jq_upsert "$ws" "$@")" ;;
    python3) new="$(ar__py upsert "$ws" "$@")" ;;
    *) new="$(ar__text_upsert "$ws" "$@")" ;;
  esac
  if [ -z "$new" ]; then
    ar_log "ERROR: task upsert produced no output (engine=$eng ws=$ws)"
    rc=1
  else
    printf '%s\n' "$new" | ar_state_write; rc=$?
  fi
  ar_lock_release
  return $rc
}

ar_task_set() {
  # $1: workspace, $2: field, $3: value
  ar_task_upsert "$1" "$2=$3"
}

ar_journal_append() {
  # $1: workspace, $2: event, $3: detail. Serialized under the state lock (F15);
  # the journal is capped so state.json can't grow unbounded (F19). All engines
  # auto-create the task with identical schema defaults when it is missing (F21).
  local ws="$1" event="$2" detail="${3:-}" ts eng new rc=0 cap
  ts="$(ar_now_iso)"
  cap="$(ar_uint "${CLAUDE_STANDBY_JOURNAL_MAX:-${AR_CFG_JOURNAL_MAX:-$AR_JOURNAL_MAX_FALLBACK}}" 200 1000000)"
  ar_state_init || return 1
  ar_lock_acquire || return 1
  eng="$(ar_json_engine)"
  case "$eng" in
    jq)
      new="$(jq --arg ws "$ws" --arg defprompt "$AR_DEFAULT_RESUME_PROMPT" \
        --arg ts "$ts" --arg e "$event" --arg d "$detail" --argjson cap "$cap" \
        ".tasks[\$ws] = (.tasks[\$ws] // $AR__DEFAULT_TASK_JQ)
         | .tasks[\$ws].journal =
             (((.tasks[\$ws].journal) // []) + [{\"ts\": \$ts, \"event\": \$e, \"detail\": \$d}]
              | if length > \$cap then .[length - \$cap:] else . end)" \
        "$AR_STATE_FILE" 2>/dev/null)"
      ;;
    python3) new="$(ar__py journal "$ws" "$ts" "$event" "$detail" "$cap")" ;;
    *) new="$(ar__text_journal_append "$ws" "$ts" "$event" "$detail" "$cap")" ;;
  esac
  if [ -z "$new" ]; then
    ar_log "ERROR: journal append produced no output (engine=$eng ws=$ws)"
    rc=1
  else
    printf '%s\n' "$new" | ar_state_write; rc=$?
  fi
  ar_lock_release
  return $rc
}

# ------------------------------------------------- Claude Code sessions --
# Session discovery against the MEASURED store layout (HOOK-FINDINGS F2):
# ~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl

AR_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

ar_project_dir() {
  # $1: workspace path -> its session directory (may not exist)
  printf '%s/%s\n' "$AR_PROJECTS_DIR" "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"
}

ar__file_mtime() {
  stat -f %m "$1" 2>/dev/null && return 0   # BSD
  stat -c %Y "$1" 2>/dev/null && return 0   # GNU
  return 1
}

ar__session_summary() {
  # $1: session jsonl -> first real user prompt, one line, <=70 chars.
  # Only the first 40 lines are read (files can be many MB — F2). Slash
  # command invocations (<command-name> tags) and meta lines are skipped.
  local f="$1" out=""
  if command -v python3 >/dev/null 2>&1; then
    out="$(head -40 "$f" 2>/dev/null | python3 -c '
import json, sys
for line in sys.stdin:
    try:
        o = json.loads(line)
    except Exception:
        continue
    if o.get("type") != "user" or o.get("isMeta"):
        continue
    c = o.get("message", {}).get("content", "")
    if isinstance(c, list):
        c = " ".join(b.get("text", "") for b in c if b.get("type") == "text")
    c = " ".join(c.split())
    if not c or c.startswith("<command-") or c.startswith("<local-command"):
        continue
    print(c[:70])
    break
' 2>/dev/null)"
  fi
  if [ -z "$out" ]; then
    # Text tier: first user line's content field, crudely de-JSONed.
    # Command/meta-only sessions yield "" (caller shows a dash).
    out="$(head -40 "$f" 2>/dev/null | grep '"type":"user"' |
      grep -v '<command-\|<local-command\|"isMeta":true' | head -1 |
      sed -n 's/.*"content":"\([^"]*\)".*/\1/p' | cut -c1-70)"
  fi
  printf '%s\n' "$out"
}

ar_sessions_list() {
  # $1: workspace -> lines "id<TAB>mtime_epoch<TAB>size_kb<TAB>summary",
  # newest first. Empty output (rc 0) when no sessions exist.
  local dir f id mt kb
  dir="$(ar_project_dir "$1")"
  [ -d "$dir" ] || return 0
  # F2: session files are UUID-named; ls -t sorts by mtime (last activity).
  ls -t "$dir" 2>/dev/null | while IFS= read -r f; do
    case "$f" in
      *.jsonl) ;;
      *) continue ;;
    esac
    id="${f%.jsonl}"
    printf '%s' "$id" | grep -Eq '^[0-9a-fA-F-]{32,40}$' || continue
    mt="$(ar__file_mtime "$dir/$f")" || mt=0
    kb=$(( $(wc -c < "$dir/$f" 2>/dev/null || echo 0) / 1024 ))
    printf '%s\t%s\t%s\t%s\n' "$id" "$mt" "$kb" "$(ar__session_summary "$dir/$f")"
  done
}

ar_session_latest() {
  # $1: workspace -> most recent session id, or empty (rc 1)
  local id
  id="$(ar_sessions_list "$1" | head -1 | cut -f1)"
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

# ------------------------------------ canonical session identity (F32/F03) --
# One place that decides what a valid session id is and whether a session
# belongs to a workspace, so the CLI, daemon, and cockpit stop drifting.

ar_is_uuid() {
  # rc 0 iff $1 is a canonical 8-4-4-4-12 hex UUID. REJECTS an all-hyphen
  # string, a bare prefix, and anything with non-hex bytes (F03/F32).
  printf '%s' "$1" | grep -Eq \
    '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

ar_session_match_prefix() {
  # $1: workspace, $2: prefix. FIXED-STRING (never regex) prefix match against
  # this workspace's session ids. Prints the single match (rc 0). ERRORS on
  # ambiguity (rc 2) instead of silently picking the newest; rc 1 when none —
  # never a fallback (F03). An exact full-id match always wins.
  local ws="$1" pfx="$2" id match="" count=0
  [ -n "$pfx" ] || return 1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if [ "$id" = "$pfx" ]; then printf '%s\n' "$id"; return 0; fi
    case "$id" in
      "$pfx"*) match="$id"; count=$((count + 1)) ;;   # $pfx quoted -> literal
    esac
  done <<EOF
$(ar_sessions_list "$ws" | cut -f1)
EOF
  [ "$count" -eq 0 ] && return 1
  if [ "$count" -gt 1 ]; then
    ar_log "session prefix '$pfx' is ambiguous ($count matches) — refusing"
    return 2
  fi
  printf '%s\n' "$match"
}

ar_session_cwd() {
  # $1: workspace, $2: session id -> the `cwd` recorded in that transcript
  # (F2), or empty (rc 1). Reads only the first few lines (files can be huge).
  local dir f
  dir="$(ar_project_dir "$1")"
  f="$dir/$2.jsonl"
  [ -f "$f" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    head -5 "$f" 2>/dev/null | python3 -c '
import json, sys
for line in sys.stdin:
    try:
        o = json.loads(line)
    except Exception:
        continue
    if isinstance(o, dict) and o.get("cwd"):
        print(o["cwd"]); break
' 2>/dev/null
  else
    head -5 "$f" 2>/dev/null | sed -n 's/.*"cwd":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
  fi
}

ar_session_belongs() {
  # rc 0 iff session $2's transcript records a `cwd` equal to workspace $1.
  # FAIL-CLOSED: a missing transcript, missing cwd, or mismatch is rc nonzero,
  # so another workspace's session can never be accepted (F03).
  local ws="$1" id="$2" cwd
  cwd="$(ar_session_cwd "$ws" "$id")" || return 1
  [ -n "$cwd" ] || return 1
  [ "$cwd" = "$ws" ]
}

ar_session_resolve() {
  # $1: workspace, $2: requested session ("" = newest, an exact UUID, or a
  # fixed-string prefix). Prints the resolved id ONLY after cross-checking it
  # belongs to this workspace (rc 0). Fail-closed otherwise — never silently
  # substitutes another session:
  #   rc 1 nothing matched / no session   rc 2 ambiguous prefix
  #   rc 3 resolved id's transcript cwd != workspace
  # NOTE: the "empty means newest" policy here is a convenience; a caller that
  # must refuse an implicit session (require an explicit --session) should test
  # "$2" itself before calling. Passing a literal "new" is NOT handled here —
  # that's the CLI's start-fresh path, not a resolvable existing session.
  local ws="$1" req="$2" id
  if [ -n "$req" ]; then
    if ar_is_uuid "$req"; then
      id="$req"
    else
      id="$(ar_session_match_prefix "$ws" "$req")" || return $?
    fi
  else
    id="$(ar_session_latest "$ws")" || return 1
  fi
  ar_session_belongs "$ws" "$id" || return 3
  printf '%s\n' "$id"
}

ar_daemon_pidfile() {
  # $1: workspace -> the pidfile path its daemon uses (D11)
  printf '%s/daemons/%s.pid\n' "$AR_HOME" "$(printf '%s' "$1" | cksum | awk '{print $1}')"
}

ar_path_digest() {
  # $1 -> a stable, collision-resistant hex digest of the string. Prefers a
  # real hash (SHA-1/MD5); falls back to cksum(CRC32)+byte-count only when no
  # hasher exists. Deterministic across runs so a derived filename is stable.
  local s="$1" d=""
  if command -v shasum >/dev/null 2>&1; then
    d="$(printf '%s' "$s" | shasum 2>/dev/null | awk '{print $1}')"
  elif command -v sha1sum >/dev/null 2>&1; then
    d="$(printf '%s' "$s" | sha1sum 2>/dev/null | awk '{print $1}')"
  elif command -v md5 >/dev/null 2>&1; then
    d="$(printf '%s' "$s" | md5 2>/dev/null)"
  elif command -v md5sum >/dev/null 2>&1; then
    d="$(printf '%s' "$s" | md5sum 2>/dev/null | awk '{print $1}')"
  fi
  if [ -z "$d" ]; then
    d="$(printf '%s' "$s" | cksum | awk '{print $1"-"$2}')"
  fi
  printf '%s\n' "$d"
}

ar_resume_live_file() {
  # $1: workspace -> the file a resume streams its output to, live (D44).
  # Host-local (not contract data). Keyed by a collision-resistant digest of
  # the workspace path so distinct workspaces that differ only in punctuation
  # (a-b vs a_b vs a/b) can't collide onto the same file (F17). The cockpit
  # must NOT reimplement this hash — it derives the path via the CLI (the
  # `output` command reads it; expose a path accessor in the CLI for P3).
  printf '%s/live/%s.out\n' "$AR_HOME" "$(ar_path_digest "$1")"
}

ar_progress_fingerprint() {
  # $1: workspace -> a cheap digest of that workspace's progress file (the file
  # named by the task's progress_file field, default PROGRESS.md), so the daemon
  # can tell whether a resume actually CHANGED anything (C5 stall detection).
  # Content-only (cksum + byte count) so an identical rewrite is still "no
  # progress". A missing/empty file yields the sentinel "none" — the caller
  # then declines to judge progress, avoiding a false stall on repos that keep
  # no progress file. Never fails the caller.
  local ws="$1" pf f
  pf="$(ar_task_get "$ws" progress_file 2>/dev/null)"
  [ -n "$pf" ] || pf="PROGRESS.md"
  case "$pf" in
    /*) f="$pf" ;;
    *)  f="$ws/$pf" ;;
  esac
  if [ -s "$f" ]; then
    cksum < "$f" 2>/dev/null | awk '{print $1"-"$2}'
  else
    printf 'none\n'
  fi
}

# ------------------------------------------- rate-limit snapshot (F4) --
# rate.json is written by the status-line sensor (plugin/scripts/statusline.sh)
# and holds only JSON numbers, so the text tier is a simple number grep.

ar_rate_file() {
  # Resolve WHICH rate snapshot to read, in priority order. The point: if a
  # file with the reset time already exists (e.g. a status line that caches
  # it), just read it — no sensor, no setup. The sensor is only the fallback
  # that PRODUCES this file for users who have none.
  #   1. explicit override (tests / config)
  #   2. our sensor's output, if registered
  #   3. a common status-line cache already on disk (read-only)
  local common
  if [ -n "${CLAUDE_STANDBY_RATE_FILE:-}" ]; then printf '%s\n' "$CLAUDE_STANDBY_RATE_FILE"; return 0; fi
  if [ -n "${AR_CFG_RATE_SOURCE:-}" ] && [ -f "$AR_CFG_RATE_SOURCE" ]; then printf '%s\n' "$AR_CFG_RATE_SOURCE"; return 0; fi
  if [ -f "$AR_HOME/rate.json" ]; then printf '%s\n' "$AR_HOME/rate.json"; return 0; fi
  common="/tmp/claude_rate_cache_${USER:-$(id -un 2>/dev/null)}.json"
  # Only trust the predictable world-writable-dir cache if WE own it — an
  # attacker who pre-creates it must not be able to steer detection (F13).
  if [ -f "$common" ] && [ -O "$common" ]; then printf '%s\n' "$common"; return 0; fi
  printf '%s\n' "$AR_HOME/rate.json"   # default (may not exist yet)
}

ar_rate_get() {
  # $1: field -> value ("" if absent). used_percentage falls back to the
  # `rate_pct` field name that some status-line caches use.
  local f rf
  rf="$(ar_rate_file)"
  [ -f "$rf" ] || return 0
  local eng
  eng="$(ar_json_engine)"
  case "$1" in
    used_percentage)
      case "$eng" in
        jq) jq -r '.used_percentage // .rate_pct // "" | tostring' "$rf" 2>/dev/null ;;
        python3) python3 -c 'import sys,json
try:
    d=json.load(open(sys.argv[1])); v=d.get("used_percentage", d.get("rate_pct",""))
    if v is None: v=d.get("rate_pct","")
    print("" if v in ("", None) else v)
except Exception: pass' "$rf" 2>/dev/null ;;
        *) { grep -oE "\"used_percentage\"[[:space:]]*:[[:space:]]*[0-9.]+" "$rf" 2>/dev/null
             grep -oE "\"rate_pct\"[[:space:]]*:[[:space:]]*[0-9.]+" "$rf" 2>/dev/null; } | head -1 | sed 's/.*:[[:space:]]*//' ;;
      esac ;;
    resets_at)
      # Normalize to epoch so an external cache storing an ISO timestamp
      # still works (our sensor already writes epoch).
      local raw
      case "$eng" in
        jq) raw="$(jq -r '.resets_at // "" | tostring' "$rf" 2>/dev/null)" ;;
        python3) raw="$(python3 -c 'import sys,json
try:
    d=json.load(open(sys.argv[1])); v=d.get("resets_at","")
    print("" if v=="" else v)
except Exception: pass' "$rf" 2>/dev/null)" ;;
        *) raw="$(grep -oE "\"resets_at\"[[:space:]]*:[[:space:]]*\"?[0-9T:+Z.-]+\"?" "$rf" 2>/dev/null | head -1 | sed -E 's/^"resets_at"[[:space:]]*:[[:space:]]*"?//; s/"$//')" ;;
      esac
      case "$raw" in
        *T*) ar_iso_to_epoch "$raw" 2>/dev/null || true ;;
        *)   printf '%s' "$raw" | grep -oE '^[0-9]+' ;;
      esac ;;
    *)
      case "$eng" in
        jq) jq -r --arg f "$1" '.[$f] // "" | tostring' "$rf" 2>/dev/null ;;
        python3) python3 -c 'import sys,json
try:
    d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2],"")
    print("" if v=="" else v)
except Exception: pass' "$rf" "$1" 2>/dev/null ;;
        *) grep -oE "\"$1\"[[:space:]]*:[[:space:]]*[0-9.]+" "$rf" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*//' ;;
      esac ;;
  esac
}

ar_rate_usable() {
  # 0 (true) when the resolved snapshot carries a resets_at still in the
  # future — the reset time is absolute, so it stays valid regardless of age.
  local r now
  r="$(ar_rate_get resets_at)"
  printf '%s' "$r" | grep -Eq '^[0-9]+$' || return 1
  now="$(date +%s)"
  [ "$r" -gt "$now" ]
}

ar_task_list() {
  # All tracked workspace paths, one per line.
  [ -f "$AR_STATE_FILE" ] || return 0
  local eng
  eng="$(ar_json_engine)"
  case "$eng" in
    jq) jq -r '.tasks | keys[]' "$AR_STATE_FILE" 2>/dev/null ;;
    python3) ar__py list ;;
    *)
      sed -n 's/^    "\(.*\)": {$/\1/p' "$AR_STATE_FILE" | while IFS= read -r k; do
        ar_json_unescape "$k"
        echo
      done
      ;;
  esac
}

ar_journal_show() {
  # $1: workspace, $2: max entries (default 5) — human-readable lines
  local n="${2:-5}" eng
  eng="$(ar_json_engine)"
  case "$eng" in
    jq)
      jq -r --arg ws "$1" --argjson n "$n" \
        '.tasks[$ws].journal // [] | .[-$n:] | .[] | "  \(.ts)  \(.event)  \(.detail)"' \
        "$AR_STATE_FILE" 2>/dev/null
      ;;
    python3) ar__py journal_show "$1" "$n" ;;
    *) ar__text_journal_show "$1" $((n * 5)) ;;
  esac
}
