#!/usr/bin/env bash
# fake-claude.sh — stand-in for the real `claude` CLI (C6: real quota is
# precious; all iterative testing runs against this stub).
#
# Mimics:   claude -p "<prompt>" [--resume <id>] [--output-format stream-json]
#           [--model <m>]  (model is accepted and ignored)
#
# Control via env:
#   FAKE_CLAUDE_MODE=clean|limit   behavior at end of "run" (default clean)
#   FAKE_CLAUDE_MODE_FILE=path     if set, mode is (re)read from this file
#                                  on every invocation — lets tests flip a
#                                  "limited" account to "reset" mid-daemon-run
#   FAKE_CLAUDE_RUN_SECS=N         seconds of simulated work (default 1)
#   FAKE_CLAUDE_RESET_AT=ISO       machine-readable reset time written to
#                                  the transcript (default: now + 5h)
#   FAKE_CLAUDE_RESET_DISPLAY=str  human reset time in the stdout limit
#                                  message (default: "4:10pm (Asia/Dhaka)")
#   FAKE_CLAUDE_LIMIT_EXIT=N       exit code in limit mode (default 1; the
#                                  real CLI's is unmeasured and may be 0 —
#                                  HOOK-FINDINGS F1)
#   FAKE_CLAUDE_TRANSCRIPT_DIR=D   where transcripts go
#                                  (default: $TMPDIR/fake-claude)
#
# Emits a JSONL transcript at $FAKE_CLAUDE_TRANSCRIPT_DIR/<session_id>.jsonl
# (appends when --resume is used) and, with --output-format stream-json,
# mirrors the lines to stdout.
#
# Exit codes: 0 = clean finish, 1 = limit hit, 2 = bad usage.
#
# NOTE (D5): the stdout limit message is the MEASURED format
# (docs/HOOK-FINDINGS.md F1). The transcript JSONL format is still a GUESS;
# reconcile when hook/transcript probe data lands.
set -u

MODE="${FAKE_CLAUDE_MODE:-clean}"
if [ -n "${FAKE_CLAUDE_MODE_FILE:-}" ] && [ -f "${FAKE_CLAUDE_MODE_FILE}" ]; then
  MODE="$(cat "${FAKE_CLAUDE_MODE_FILE}")"
fi
RUN_SECS="${FAKE_CLAUDE_RUN_SECS:-1}"
TDIR="${FAKE_CLAUDE_TRANSCRIPT_DIR:-${TMPDIR:-/tmp}/fake-claude}"

PROMPT=""
RESUME_ID=""
OUTFMT="text"

while [ $# -gt 0 ]; do
  case "$1" in
    -p)              PROMPT="${2:-}"; shift 2 ;;
    --resume)        RESUME_ID="${2:-}"; shift 2 ;;
    --output-format) OUTFMT="${2:-text}"; shift 2 ;;
    --model)         shift 2 ;;
    *)               shift ;;
  esac
done

if [ -z "$PROMPT" ]; then
  echo "fake-claude: missing -p <prompt>" >&2
  exit 2
fi

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

now_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }

epoch_to_iso() {
  date -r "$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null && return 0   # BSD
  date -d "@$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null && return 0  # GNU
  return 1
}

SESSION_ID="${RESUME_ID:-fake-$$-$(date +%s)}"
mkdir -p "$TDIR"
TRANSCRIPT="$TDIR/$SESSION_ID.jsonl"

emit() {
  printf '%s\n' "$1" >> "$TRANSCRIPT"
  if [ "$OUTFMT" = "stream-json" ]; then
    printf '%s\n' "$1"
  fi
}

if [ ! -f "$TRANSCRIPT" ] || [ -z "$RESUME_ID" ]; then
  emit "{\"type\":\"fake_meta\",\"note\":\"GUESSED FORMAT - reconcile with docs/HOOK-FINDINGS.md (D5)\",\"session_id\":\"$SESSION_ID\"}"
fi

emit "{\"type\":\"user\",\"session_id\":\"$SESSION_ID\",\"ts\":\"$(now_iso)\",\"message\":{\"role\":\"user\",\"content\":\"$(esc "$PROMPT")\"}}"

sleep "$RUN_SECS"

emit "{\"type\":\"assistant\",\"session_id\":\"$SESSION_ID\",\"ts\":\"$(now_iso)\",\"message\":{\"role\":\"assistant\",\"content\":\"Working on it: $(esc "$PROMPT")\"}}"

if [ "$MODE" = "limit" ]; then
  RESET_AT="${FAKE_CLAUDE_RESET_AT:-}"
  if [ -z "$RESET_AT" ]; then
    RESET_AT="$(epoch_to_iso $(( $(date +%s) + 18000 )) )"
  fi
  RESET_DISPLAY="${FAKE_CLAUDE_RESET_DISPLAY:-4:10pm (Asia/Dhaka)}"
  # Stdout wording is MEASURED (HOOK-FINDINGS F1); reset_at in the
  # transcript line is a machine-readable extra for tests.
  LIMIT_MSG="You've hit your session limit · resets $RESET_DISPLAY"
  emit "{\"type\":\"system\",\"subtype\":\"limit\",\"session_id\":\"$SESSION_ID\",\"ts\":\"$(now_iso)\",\"reset_at\":\"$RESET_AT\",\"message\":\"$(esc "$LIMIT_MSG")\"}"
  if [ "$OUTFMT" != "stream-json" ]; then
    echo "$LIMIT_MSG"
  fi
  exit "${FAKE_CLAUDE_LIMIT_EXIT:-1}"
fi

emit "{\"type\":\"result\",\"subtype\":\"success\",\"session_id\":\"$SESSION_ID\",\"ts\":\"$(now_iso)\",\"result\":\"Task completed cleanly.\"}"
if [ "$OUTFMT" != "stream-json" ]; then
  echo "Task completed cleanly."
fi
exit 0
