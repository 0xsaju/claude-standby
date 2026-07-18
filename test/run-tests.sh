#!/usr/bin/env bash
# run-tests.sh — shell test suite for claude-auto-resume Phase 0.
# Runs the lib.sh state suite against every available JSON engine
# (jq, python3, text) plus cross-engine interop, timestamp helpers,
# fake-claude behavior, and an on-stop.sh smoke test.
# Exit 0 iff everything passed.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$HERE/../plugin"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; shift; while [ $# -gt 0 ]; do printf '       %s\n' "$1"; shift; done; }

t_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected: $2" "actual:   $3"; fi
}

t_contains() { # name needle haystack
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) fail "$1" "missing:  $2" "in:       $3" ;;
  esac
}

# ---------------------------------------------------------- syntax checks --

for f in "$PLUGIN"/scripts/*.sh "$HERE"/fake-claude.sh "$HERE"/run-tests.sh; do
  if bash -n "$f" 2>/dev/null; then
    ok "syntax: $(basename "$f")"
  else
    fail "syntax: $(basename "$f")" "$(bash -n "$f" 2>&1 | head -2)"
  fi
done

# ----------------------------------------------------- per-engine state suite --

engine_available() {
  case "$1" in
    jq)      command -v jq >/dev/null 2>&1 ;;
    python3) command -v python3 >/dev/null 2>&1 ;;
    text)    true ;;
  esac
}

state_suite() {
  local eng="$1"
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ar-test-XXXXXX")"
  export CLAUDE_AUTO_RESUME_STATE="$tmp/state.json"
  export CLAUDE_AUTO_RESUME_LOG_DIR="$tmp/logs"
  export AR_JSON_ENGINE="$eng"
  # shellcheck disable=SC1091
  . "$PLUGIN/scripts/lib.sh"

  local WS="/Users/example/project one"
  local WS2="/Users/example/other"

  # 1. init
  ar_state_init
  [ -f "$CLAUDE_AUTO_RESUME_STATE" ] && ok "$eng: init creates state file" || fail "$eng: init creates state file"
  t_contains "$eng: init writes version 2" '"version": 2' "$(cat "$CLAUDE_AUTO_RESUME_STATE")"

  # 2. upsert + get round trip (incl. a value with quotes and equals sign)
  local PROMPT='Build the "thing" x=1 and keep going'
  ar_task_upsert "$WS" "status=running" "importance=critical" "original_prompt=$PROMPT" \
    || fail "$eng: upsert returns success"
  t_eq "$eng: get status after upsert" "running" "$(ar_task_get "$WS" status)"
  t_eq "$eng: get importance after upsert" "critical" "$(ar_task_get "$WS" importance)"
  t_eq "$eng: get prompt round-trips quotes" "$PROMPT" "$(ar_task_get "$WS" original_prompt)"
  t_eq "$eng: defaults filled (max_resumes)" "3" "$(ar_task_get "$WS" max_resumes)"
  t_eq "$eng: defaults filled (progress_file)" "PROGRESS.md" "$(ar_task_get "$WS" progress_file)"

  # 3. set one field, others untouched
  ar_task_set "$WS" status waiting
  t_eq "$eng: set updates status" "waiting" "$(ar_task_get "$WS" status)"
  t_eq "$eng: set leaves importance alone" "critical" "$(ar_task_get "$WS" importance)"

  # 4. numeric fields stay numbers
  ar_task_set "$WS" resume_count 2
  t_eq "$eng: numeric get" "2" "$(ar_task_get "$WS" resume_count)"
  t_contains "$eng: numeric stored unquoted" '"resume_count": 2' "$(cat "$CLAUDE_AUTO_RESUME_STATE")"

  # 5. journal append accumulates
  ar_journal_append "$WS" "limit-hit" "reset at 20:00"
  ar_journal_append "$WS" "resumed" "attempt 1"
  local shown
  shown="$(ar_journal_show "$WS" 10)"
  t_contains "$eng: journal has first event" "limit-hit" "$shown"
  t_contains "$eng: journal has second event" "resumed" "$shown"

  # 6. second task doesn't clobber the first
  ar_task_upsert "$WS2" "status=running" "importance=low"
  t_eq "$eng: second task readable" "low" "$(ar_task_get "$WS2" importance)"
  t_eq "$eng: first task intact" "waiting" "$(ar_task_get "$WS" status)"
  t_eq "$eng: first prompt intact" "$PROMPT" "$(ar_task_get "$WS" original_prompt)"

  # 7. task_exists
  ar_task_exists "$WS" && ok "$eng: task_exists true" || fail "$eng: task_exists true"
  ar_task_exists "/nope" && fail "$eng: task_exists false" || ok "$eng: task_exists false"

  # 8. atomic write leaves no temp litter
  if ls "$tmp"/state.json.tmp.* >/dev/null 2>&1; then
    fail "$eng: no temp litter"
  else
    ok "$eng: no temp litter"
  fi

  # 9. state file is valid JSON (checked with any real parser available)
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CLAUDE_AUTO_RESUME_STATE" 2>/dev/null; then
      ok "$eng: state file is valid JSON"
    else
      fail "$eng: state file is valid JSON" "$(cat "$CLAUDE_AUTO_RESUME_STATE")"
    fi
  fi

  rm -rf "$tmp"
}

for eng in jq python3 text; do
  if engine_available "$eng"; then
    state_suite "$eng"
  else
    printf 'skip - engine %s not available on this machine\n' "$eng"
  fi
done

# --------------------------------------- cross-engine interop (jq -> text) --

if command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ar-test-XXXXXX")"
  export CLAUDE_AUTO_RESUME_STATE="$tmp/state.json"
  export CLAUDE_AUTO_RESUME_LOG_DIR="$tmp/logs"
  export AR_JSON_ENGINE="jq"
  . "$PLUGIN/scripts/lib.sh"
  WS="/interop/ws"
  ar_task_upsert "$WS" "status=limit-hit" "resume_at=2026-07-18T20:00:00+0600"
  ar_journal_append "$WS" "limit-hit" "interop"
  export AR_JSON_ENGINE="text"
  t_eq "interop: text reads jq-written status" "limit-hit" "$(ar_task_get "$WS" status)"
  t_eq "interop: text reads jq-written resume_at" "2026-07-18T20:00:00+0600" "$(ar_task_get "$WS" resume_at)"
  ar_task_set "$WS" status waiting
  export AR_JSON_ENGINE="jq"
  t_eq "interop: jq reads text-written status" "waiting" "$(ar_task_get "$WS" status)"
  # text-tier journal append onto a jq-expanded journal array
  export AR_JSON_ENGINE="text"
  ar_journal_append "$WS" "resumed" "interop 2"
  export AR_JSON_ENGINE="jq"
  t_contains "interop: jq reads text-appended journal" "interop 2" "$(ar_journal_show "$WS" 10)"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CLAUDE_AUTO_RESUME_STATE" 2>/dev/null \
      && ok "interop: mixed-engine file still valid JSON" \
      || fail "interop: mixed-engine file still valid JSON" "$(cat "$CLAUDE_AUTO_RESUME_STATE")"
  fi
  rm -rf "$tmp"
else
  printf 'skip - interop suite needs jq\n'
fi

# ------------------------------------------------------------- timestamps --

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ar-test-XXXXXX")"
export CLAUDE_AUTO_RESUME_STATE="$tmp/state.json"
export CLAUDE_AUTO_RESUME_LOG_DIR="$tmp/logs"
unset AR_JSON_ENGINE
. "$PLUGIN/scripts/lib.sh"

t_eq "time: known ISO to epoch" "1767225600" "$(ar_iso_to_epoch '2026-01-01T00:00:00+0000')"
t_eq "time: colon offset tolerated" "1767225600" "$(ar_iso_to_epoch '2026-01-01T00:00:00+00:00')"
NOW_ISO="$(ar_now_iso)"
NOW_EPOCH="$(ar_iso_to_epoch "$NOW_ISO")"
case "$NOW_EPOCH" in
  [0-9]*) ok "time: now round-trips to epoch" ;;
  *) fail "time: now round-trips to epoch" "got: $NOW_EPOCH" ;;
esac
ROUND="$(ar_iso_to_epoch "$(ar_epoch_to_iso "$NOW_EPOCH")")"
t_eq "time: epoch <-> iso round trip" "$NOW_EPOCH" "$ROUND"
rm -rf "$tmp"

# ------------------------------------------------------------ fake-claude --

FTMP="$(mktemp -d "${TMPDIR:-/tmp}/ar-test-XXXXXX")"
export FAKE_CLAUDE_TRANSCRIPT_DIR="$FTMP/transcripts"
export FAKE_CLAUDE_RUN_SECS=0

# clean run
OUT="$(FAKE_CLAUDE_MODE=clean bash "$HERE/fake-claude.sh" -p "do the thing")"
RC=$?
t_eq "fake: clean exit code" "0" "$RC"
t_contains "fake: clean stdout" "Task completed cleanly." "$OUT"
COUNT="$(ls "$FAKE_CLAUDE_TRANSCRIPT_DIR" | wc -l | tr -d ' ')"
t_eq "fake: clean wrote one transcript" "1" "$COUNT"

# limit run with pinned reset time
RESET="2026-07-18T20:00:00+0600"
OUT="$(FAKE_CLAUDE_MODE=limit FAKE_CLAUDE_RESET_AT="$RESET" bash "$HERE/fake-claude.sh" -p "long task")"
RC=$?
t_eq "fake: limit exit code" "1" "$RC"
t_contains "fake: limit stdout has message" "usage limit reached" "$OUT"
t_contains "fake: limit stdout has reset time" "$RESET" "$OUT"
LIMIT_TRANSCRIPT="$(ls -t "$FAKE_CLAUDE_TRANSCRIPT_DIR"/*.jsonl | head -1)"
t_contains "fake: transcript tail has limit text" "usage limit reached" "$(tail -2 "$LIMIT_TRANSCRIPT")"
t_contains "fake: transcript tail has reset time" "$RESET" "$(tail -2 "$LIMIT_TRANSCRIPT")"

# resume appends to the same transcript
SID="resume-test-1"
FAKE_CLAUDE_MODE=clean bash "$HERE/fake-claude.sh" -p "start" --resume "$SID" >/dev/null
LINES1="$(wc -l < "$FAKE_CLAUDE_TRANSCRIPT_DIR/$SID.jsonl" | tr -d ' ')"
FAKE_CLAUDE_MODE=clean bash "$HERE/fake-claude.sh" -p "continue" --resume "$SID" >/dev/null
LINES2="$(wc -l < "$FAKE_CLAUDE_TRANSCRIPT_DIR/$SID.jsonl" | tr -d ' ')"
if [ "$LINES2" -gt "$LINES1" ]; then
  ok "fake: --resume appends to same transcript"
else
  fail "fake: --resume appends to same transcript" "before: $LINES1 after: $LINES2"
fi

# stream-json mirrors to stdout
OUT="$(FAKE_CLAUDE_MODE=clean bash "$HERE/fake-claude.sh" -p "stream" --output-format stream-json)"
t_contains "fake: stream-json emits typed lines" '"type":"result"' "$OUT"

rm -rf "$FTMP"

# -------------------------------------------------- task-resume-at parsing --

PTMP="$(mktemp -d "${TMPDIR:-/tmp}/ar-test-XXXXXX")"
export CLAUDE_AUTO_RESUME_STATE="$PTMP/state.json"
export CLAUDE_AUTO_RESUME_LOG_DIR="$PTMP/logs"
unset AR_JSON_ENGINE
export AR_NOTIFY_SILENT=1

NOW="$(date +%s)"
E="$(AR_PARSE_ONLY=1 bash "$PLUGIN/scripts/task-resume-at.sh" now)"
D=$((E - NOW)); [ "$D" -ge 0 ] && [ "$D" -le 3 ] && ok "parse: now" || fail "parse: now" "delta: $D"
E="$(AR_PARSE_ONLY=1 bash "$PLUGIN/scripts/task-resume-at.sh" 2h30m)"
D=$((E - NOW - 9000)); [ "$D" -ge -3 ] && [ "$D" -le 3 ] && ok "parse: 2h30m" || fail "parse: 2h30m" "delta: $D"
E="$(AR_PARSE_ONLY=1 bash "$PLUGIN/scripts/task-resume-at.sh" 45m)"
D=$((E - NOW - 2700)); [ "$D" -ge -3 ] && [ "$D" -le 3 ] && ok "parse: 45m" || fail "parse: 45m" "delta: $D"
t_eq "parse: ISO passthrough" "1767225600" "$(AR_PARSE_ONLY=1 bash "$PLUGIN/scripts/task-resume-at.sh" '2026-01-01T00:00:00+0000')"
E="$(AR_PARSE_ONLY=1 bash "$PLUGIN/scripts/task-resume-at.sh" 23:59)"
if [ "$E" -gt "$NOW" ] && [ "$E" -le $((NOW + 86400 + 60)) ]; then
  ok "parse: HH:MM is next occurrence"
else
  fail "parse: HH:MM is next occurrence" "now: $NOW got: $E"
fi
t_contains "parse: garbage rejected" "Could not parse" "$(bash "$PLUGIN/scripts/task-resume-at.sh" 'not-a-time!!')"
rm -rf "$PTMP"

# ------------------------------------------------- scheduling + daemon --

DTMP="$(mktemp -d "${TMPDIR:-/tmp}/ar-test-XXXXXX")"
DTMP="$(cd "$DTMP" && pwd)"   # normalize: workspace keys come from pwd
export CLAUDE_AUTO_RESUME_STATE="$DTMP/state.json"
export CLAUDE_AUTO_RESUME_LOG_DIR="$DTMP/logs"
export CLAUDE_AUTO_RESUME_CLAUDE_BIN="$HERE/fake-claude.sh"
export FAKE_CLAUDE_TRANSCRIPT_DIR="$DTMP/transcripts"
export FAKE_CLAUDE_RUN_SECS=0
export FAKE_CLAUDE_MODE=clean
export AR_DAEMON_TICK_SECS=1
export AR_NORMAL_GRACE_SECS=0
export AR_BACKOFF_BASE_SECS=0
export AR_NOTIFY_SILENT=1
unset AR_JSON_ENGINE
. "$PLUGIN/scripts/lib.sh"

# schedule writes state (no daemon)
WS1="$DTMP/ws-critical"; mkdir -p "$WS1"
OUT="$(cd "$WS1" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" now)"
t_contains "schedule: confirms" "Resume scheduled." "$OUT"
t_eq "schedule: status waiting" "waiting" "$(ar_task_get "$WS1" status)"
t_eq "schedule: untracked defaults to critical" "critical" "$(ar_task_get "$WS1" importance)"
[ -n "$(ar_task_get "$WS1" resume_at)" ] && ok "schedule: resume_at set" || fail "schedule: resume_at set"
t_contains "schedule: journaled" "scheduled" "$(ar_journal_show "$WS1" 5)"

# daemon: critical + clean resume -> done
bash "$PLUGIN/scripts/daemon.sh" "$WS1"
t_eq "daemon: critical clean run ends done" "done" "$(ar_task_get "$WS1" status)"
t_eq "daemon: resume_count incremented" "1" "$(ar_task_get "$WS1" resume_count)"
t_contains "daemon: journal has resumed" "resumed" "$(ar_journal_show "$WS1" 10)"
t_contains "daemon: journal has done" "done" "$(ar_journal_show "$WS1" 10)"
t_contains "daemon: captured output tail" "Task completed cleanly." "$(ar_task_get "$WS1" last_output_tail)"

# daemon: normal importance with zero grace also resumes
WS2="$DTMP/ws-normal"; mkdir -p "$WS2"
(cd "$WS2" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" now normal >/dev/null)
bash "$PLUGIN/scripts/daemon.sh" "$WS2"
t_eq "daemon: normal tier resumes after grace" "done" "$(ar_task_get "$WS2" status)"

# daemon: low importance -> notify only, no claude invocation
WS3="$DTMP/ws-low"; mkdir -p "$WS3"
BEFORE="$(ls "$DTMP/transcripts" 2>/dev/null | wc -l | tr -d ' ')"
(cd "$WS3" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" now low >/dev/null)
bash "$PLUGIN/scripts/daemon.sh" "$WS3"
AFTER="$(ls "$DTMP/transcripts" 2>/dev/null | wc -l | tr -d ' ')"
t_eq "daemon: low tier never auto-resumes" "limit-hit" "$(ar_task_get "$WS3" status)"
t_eq "daemon: low tier spawned no session" "$BEFORE" "$AFTER"
t_contains "daemon: low tier journaled reset" "reset-reached" "$(ar_journal_show "$WS3" 5)"

# daemon: stands down on cancelled
WS4="$DTMP/ws-cancelled"; mkdir -p "$WS4"
(cd "$WS4" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" now >/dev/null)
ar_task_set "$WS4" status cancelled
bash "$PLUGIN/scripts/daemon.sh" "$WS4"
t_eq "daemon: cancelled task untouched" "cancelled" "$(ar_task_get "$WS4" status)"

# daemon: repeated limit hits -> backoff then failed at max_resumes
WS5="$DTMP/ws-limited"; mkdir -p "$WS5"
(cd "$WS5" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" now >/dev/null)
ar_task_set "$WS5" max_resumes 2
FAKE_CLAUDE_MODE=limit bash "$PLUGIN/scripts/daemon.sh" "$WS5"
t_eq "daemon: limited resume ends failed" "failed" "$(ar_task_get "$WS5" status)"
t_eq "daemon: attempts bounded by max_resumes" "2" "$(ar_task_get "$WS5" resume_count)"
t_contains "daemon: backoff journaled" "resume-failed" "$(ar_journal_show "$WS5" 10)"

# daemon: pre-exhausted max_resumes -> failed without attempting
WS6="$DTMP/ws-exhausted"; mkdir -p "$WS6"
(cd "$WS6" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" now >/dev/null)
ar_task_upsert "$WS6" "resume_count=3" "max_resumes=3"
bash "$PLUGIN/scripts/daemon.sh" "$WS6"
t_eq "daemon: exhausted cap fails fast" "failed" "$(ar_task_get "$WS6" status)"
t_contains "daemon: cap journaled" "max_resumes" "$(ar_journal_show "$WS6" 5)"

# auto mode: bare invocation schedules probe-based detection
WS7="$DTMP/ws-auto"; mkdir -p "$WS7"
OUT="$(cd "$WS7" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh")"
t_contains "auto: bare invocation confirms" "auto-detect" "$OUT"
t_eq "auto: resume_mode stored" "auto" "$(ar_task_get "$WS7" resume_mode)"
t_eq "auto: status waiting" "waiting" "$(ar_task_get "$WS7" status)"

# auto mode: tier-only argument implies auto
WS8="$DTMP/ws-auto-tier"; mkdir -p "$WS8"
(cd "$WS8" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" low >/dev/null)
t_eq "auto: tier-only arg implies auto" "auto" "$(ar_task_get "$WS8" resume_mode)"
t_eq "auto: tier-only arg sets tier" "low" "$(ar_task_get "$WS8" importance)"

# auto mode: limit lifts mid-wait -> daemon probes, detects, resumes
MODEFILE="$DTMP/fake-mode"
printf 'limit' > "$MODEFILE"
export FAKE_CLAUDE_MODE_FILE="$MODEFILE"
export AR_PROBE_INTERVAL_SECS=1
bash "$PLUGIN/scripts/daemon.sh" "$WS7" &
DPID=$!
sleep 3
printf 'clean' > "$MODEFILE"
WAITED=0
while kill -0 "$DPID" 2>/dev/null && [ "$WAITED" -lt 15 ]; do sleep 1; WAITED=$((WAITED + 1)); done
if kill -0 "$DPID" 2>/dev/null; then
  kill "$DPID" 2>/dev/null
  fail "auto: daemon resumes when limit lifts" "daemon still running after ${WAITED}s"
else
  t_eq "auto: daemon resumes when limit lifts" "done" "$(ar_task_get "$WS7" status)"
  t_contains "auto: limit-lifted journaled" "limit-lifted" "$(ar_journal_show "$WS7" 10)"
  t_eq "auto: probe failures didn't consume attempts" "1" "$(ar_task_get "$WS7" resume_count)"
fi

# auto mode: gives up when limit never lifts within the window
WS9="$DTMP/ws-auto-giveup"; mkdir -p "$WS9"
printf 'limit' > "$MODEFILE"
(cd "$WS9" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" auto >/dev/null)
AR_AUTO_GIVEUP_SECS=1 bash "$PLUGIN/scripts/daemon.sh" "$WS9"
t_eq "auto: gives up after window" "failed" "$(ar_task_get "$WS9" status)"
t_contains "auto: give-up journaled" "did not lift" "$(ar_journal_show "$WS9" 5)"
unset FAKE_CLAUDE_MODE_FILE AR_PROBE_INTERVAL_SECS

# daemon: pidfiles cleaned up
if ls "$DTMP"/daemons/*.pid >/dev/null 2>&1; then
  fail "daemon: pidfiles cleaned up" "$(ls "$DTMP"/daemons/)"
else
  ok "daemon: pidfiles cleaned up"
fi

unset CLAUDE_AUTO_RESUME_CLAUDE_BIN FAKE_CLAUDE_TRANSCRIPT_DIR FAKE_CLAUDE_MODE
rm -rf "$DTMP"

# ---------------------------------------------------------- on-stop smoke --

STMP="$(mktemp -d "${TMPDIR:-/tmp}/ar-test-XXXXXX")"
export CLAUDE_AUTO_RESUME_STATE="$STMP/state.json"
export CLAUDE_AUTO_RESUME_LOG_DIR="$STMP/logs"
ERR="$(echo '{"session_id":"abc","transcript_path":"/nonexistent"}' | bash "$PLUGIN/scripts/on-stop.sh" Stop 2>&1 >/dev/null)"
RC=$?
t_eq "on-stop: always exits 0" "0" "$RC"
t_eq "on-stop: no stderr noise" "" "$ERR"
t_contains "on-stop: logged the event" "event=Stop" "$(cat "$STMP/logs/plugin.log" 2>/dev/null)"
ERR="$(printf '' | bash "$PLUGIN/scripts/on-stop.sh" SessionEnd 2>&1 >/dev/null)"
RC=$?
t_eq "on-stop: empty payload still exits 0" "0" "$RC"
rm -rf "$STMP"

# ---------------------------------------------------------------- summary --

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
