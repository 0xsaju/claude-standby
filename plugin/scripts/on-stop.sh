#!/usr/bin/env bash
# on-stop.sh — entry point for the Stop and SessionEnd hooks ($1 = event).
#
# C4: this script ALWAYS exits 0, finishes fast, and sends nothing to
# stderr; problems go to the plugin log only.
#
# C1: DETECTION IS A STUB. The limit-hit payload/transcript shapes are
# unknown until docs/HOOK-FINDINGS.md contains real probe data. detect_limit
# below must only ever be implemented against formats documented there.
#
# Fallback seam: if findings show hooks don't fire on limit-hit, a
# supervisor wrapper becomes the caller of this same script (event
# "supervisor") — only the trigger changes, not the daemon or state logic.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EVENT="${1:-unknown}"

{
  . "$SCRIPT_DIR/lib.sh" || exit 0

  # Hook payload arrives on stdin as JSON (may be empty).
  PAYLOAD="$(cat 2>/dev/null || true)"
  ar_log "on-stop: event=$EVENT payload_bytes=${#PAYLOAD}"

  # Capture the full payload + transcript tail for docs/HOOK-FINDINGS.md —
  # a limit hit with the plugin installed produces the Phase 1 data
  # automatically, no separate probe install needed. Logging only; still
  # fast and always exit 0 (C4).
  mkdir -p "$AR_LOG_DIR" 2>/dev/null
  {
    echo "════ $(ar_now_iso) event=$EVENT"
    printf '%s\n' "$PAYLOAD"
    TRANSCRIPT="$(printf '%s' "$PAYLOAD" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
      echo "---- transcript tail (last 40 lines of $TRANSCRIPT) ----"
      tail -n 40 "$TRANSCRIPT"
    fi
    echo ""
  } >> "$AR_LOG_DIR/hook-payloads.log" 2>/dev/null

  detect_limit() {
    # TODO(C1): STUB — always reports "no limit". Implement ONLY against
    # payload/transcript shapes documented in docs/HOOK-FINDINGS.md
    # (open questions Q1–Q7). Inputs: $1=event name, $2=raw JSON payload.
    # Contract: return 0 and print the reset time (ISO-8601) on stdout if
    # a limit hit is detected; return 1 otherwise.
    return 1
  }

  if RESET_AT="$(detect_limit "$EVENT" "$PAYLOAD")"; then
    # TODO(C1)/TODO(Phase 2): unreachable while stubbed. When real:
    #   - fill session_id / last_output_tail / resume_at from the payload
    #   - set status=limit-hit, journal it, ar_notify the user
    #   - spawn the detached daemon (nohup ... & disown)
    ar_log "on-stop: limit detected, resume at $RESET_AT (unreachable: stub)"
  fi
} 2>/dev/null

exit 0
