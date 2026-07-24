#!/usr/bin/env bash
# statusline.sh — status-line SENSOR for claude-standby.
#
# Claude Code streams live rate-limit state to the status-line command on
# stdin (HOOK-FINDINGS F4): .rate_limits.five_hour.{used_percentage,resets_at}.
# This captures those into ~/.claude/auto-resume/rate.json so the daemon can
# schedule an auto-resume to the EXACT reset time with no probing and no
# quota — the reset time is NOT available to the Stop hook (F4, measured).
#
# It is a SENSOR, not a replacement: if you already had a status line, its
# command is chained (run with the same stdin, output passed through) so your
# display is unchanged. Registered/removed by `setup-statusline`. It must
# never break the status line, so it always exits 0 (C4-style).
#
# lib.sh sources an optional user config file (~/.claude/auto-resume/config)
# on load, and the chained command below is arbitrary user-controlled text.
# Both are untrusted from this sensor's point of view: an `exit` in either
# must not make the sensor itself exit non-zero, and a `sleep`/hang in
# either must not block the status line forever. Everything that depends on
# them therefore runs in a backgrounded subshell under a hard wall-clock
# budget (F28) — the subshell's own exit code and runtime can never escape
# to this process.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

INPUT="$(cat)"

AR_SENSOR_BUDGET="${CLAUDE_STANDBY_SENSOR_TIMEOUT:-2}"
case "$AR_SENSOR_BUDGET" in
  ''|*[!0-9]*) AR_SENSOR_BUDGET=2 ;;
esac

(
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/lib.sh" 2>/dev/null || exit 0

  # --- capture (best-effort; must never break the display) -----------------
  capture() {
    local used="" resets="" out epoch now tmp
    if command -v jq >/dev/null 2>&1; then
      used="$(printf '%s' "$INPUT" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)"
      resets="$(printf '%s' "$INPUT" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)"
    elif command -v python3 >/dev/null 2>&1; then
      out="$(printf '%s' "$INPUT" | python3 -c 'import sys,json
try:
    d = json.load(sys.stdin); f = d.get("rate_limits", {}).get("five_hour", {})
    print(str(f.get("used_percentage", "")) + "\t" + str(f.get("resets_at", "")))
except Exception:
    print("\t")' 2>/dev/null)"
      used="${out%%$'\t'*}"; resets="${out##*$'\t'}"
    else
      used="$(printf '%s' "$INPUT" | grep -oE '"used_percentage"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+$')"
      resets="$(printf '%s' "$INPUT" | grep -oE '"resets_at"[[:space:]]*:[[:space:]]*"?[0-9T:+Z.-]+"?' | head -1 | sed 's/.*:[[:space:]]*//; s/"//g')"
    fi
    [ -n "$resets" ] || return 0
    case "$resets" in
      *T*) epoch="$(ar_iso_to_epoch "$resets" 2>/dev/null)" || epoch="" ;;
      *)   epoch="$resets" ;;
    esac
    [ -n "$epoch" ] && printf '%s' "$epoch" | grep -Eq '^[0-9]+$' || return 0
    printf '%s' "${used:-0}" | grep -Eq '^[0-9]+(\.[0-9]+)?$' || used=0
    now="$(date +%s)"
    mkdir -p "$(dirname "$AR_RATE_FILE")" 2>/dev/null || return 0
    tmp="$AR_RATE_FILE.tmp.$$"
    if printf '{\n  "captured_at": %s,\n  "resets_at": %s,\n  "used_percentage": %s\n}\n' \
         "$now" "$epoch" "${used:-0}" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$AR_RATE_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    fi
  }
  capture 2>/dev/null || true

  # --- chain to the user's original status line, if one was saved ----------
  CHAIN_FILE="$AR_HOME/statusline-chain"
  if [ -f "$CHAIN_FILE" ]; then
    CHAIN_CMD="$(cat "$CHAIN_FILE" 2>/dev/null)"
    if [ -n "$CHAIN_CMD" ]; then
      printf '%s' "$INPUT" | eval "$CHAIN_CMD" 2>/dev/null
    fi
  fi
  exit 0
) &
BODY_PID=$!

waited=0
while kill -0 "$BODY_PID" 2>/dev/null && [ "$waited" -lt "$AR_SENSOR_BUDGET" ]; do
  sleep 1
  waited=$((waited + 1))
done
if kill -0 "$BODY_PID" 2>/dev/null; then
  kill -9 "$BODY_PID" 2>/dev/null
fi
wait "$BODY_PID" 2>/dev/null

exit 0
