#!/usr/bin/env bash
# run-tests.sh — shell test suite for claude-standby Phase 0.
# Runs the lib.sh state suite against every available JSON engine
# (jq, python3, text) plus cross-engine interop, timestamp helpers,
# and fake-claude behavior.
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

# wait_until <timeout_secs> <cmd...> — poll until cmd (run via eval) succeeds or
# the timeout elapses; returns 0/1. Keeps background-daemon assertions robust on
# a loaded machine instead of racing a fixed sleep (which flakes under load).
wait_until() {
  local t="$1" n=0; shift
  while [ "$n" -lt "$t" ]; do
    if eval "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1; n=$((n + 1))
  done
  return 1
}

# ---------------------------------------------------------- syntax checks --

for f in "$PLUGIN"/scripts/*.sh "$HERE"/fake-claude.sh "$HERE"/run-tests.sh "$HERE"/../bin/claude-standby "$HERE"/../install.sh; do
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
  export CLAUDE_STANDBY_STATE="$tmp/state.json"
  export CLAUDE_STANDBY_LOG_DIR="$tmp/logs"
  export AR_JSON_ENGINE="$eng"
  # shellcheck disable=SC1091
  . "$PLUGIN/scripts/lib.sh"

  local WS="/Users/example/project one"
  local WS2="/Users/example/other"

  # 1. init
  ar_state_init
  [ -f "$CLAUDE_STANDBY_STATE" ] && ok "$eng: init creates state file" || fail "$eng: init creates state file"
  t_contains "$eng: init writes version 2" '"version": 2' "$(cat "$CLAUDE_STANDBY_STATE")"

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
  t_contains "$eng: numeric stored unquoted" '"resume_count": 2' "$(cat "$CLAUDE_STANDBY_STATE")"

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

  # 7. task_exists + list
  ar_task_exists "$WS" && ok "$eng: task_exists true" || fail "$eng: task_exists true"
  ar_task_exists "/nope" && fail "$eng: task_exists false" || ok "$eng: task_exists false"
  LISTED="$(ar_task_list)"
  t_contains "$eng: task_list has first ws" "$WS" "$LISTED"
  t_contains "$eng: task_list has second ws" "$WS2" "$LISTED"

  # 8. atomic write leaves no temp litter
  if ls "$tmp"/state.json.tmp.* >/dev/null 2>&1; then
    fail "$eng: no temp litter"
  else
    ok "$eng: no temp litter"
  fi

  # 9. state file is valid JSON (checked with any real parser available)
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CLAUDE_STANDBY_STATE" 2>/dev/null; then
      ok "$eng: state file is valid JSON"
    else
      fail "$eng: state file is valid JSON" "$(cat "$CLAUDE_STANDBY_STATE")"
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
  export CLAUDE_STANDBY_STATE="$tmp/state.json"
  export CLAUDE_STANDBY_LOG_DIR="$tmp/logs"
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
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CLAUDE_STANDBY_STATE" 2>/dev/null \
      && ok "interop: mixed-engine file still valid JSON" \
      || fail "interop: mixed-engine file still valid JSON" "$(cat "$CLAUDE_STANDBY_STATE")"
  fi
  rm -rf "$tmp"
else
  printf 'skip - interop suite needs jq\n'
fi

# ------------------------------------------------------------- timestamps --

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ar-test-XXXXXX")"
export CLAUDE_STANDBY_STATE="$tmp/state.json"
export CLAUDE_STANDBY_LOG_DIR="$tmp/logs"
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

# limit run with pinned reset times (stdout format is measured — F1)
RESET="2026-07-18T20:00:00+0600"
DISPLAY="8:00pm (Asia/Dhaka)"
OUT="$(FAKE_CLAUDE_MODE=limit FAKE_CLAUDE_RESET_AT="$RESET" FAKE_CLAUDE_RESET_DISPLAY="$DISPLAY" bash "$HERE/fake-claude.sh" -p "long task")"
RC=$?
t_eq "fake: limit exit code (default)" "1" "$RC"
t_contains "fake: limit stdout has measured wording" "hit your session limit" "$OUT"
t_contains "fake: limit stdout has display reset time" "$DISPLAY" "$OUT"
LIMIT_TRANSCRIPT="$(ls -t "$FAKE_CLAUDE_TRANSCRIPT_DIR"/*.jsonl | head -1)"
t_contains "fake: transcript tail has limit text" "hit your session limit" "$(tail -2 "$LIMIT_TRANSCRIPT")"
t_contains "fake: transcript tail has ISO reset time" "$RESET" "$(tail -2 "$LIMIT_TRANSCRIPT")"
FAKE_CLAUDE_MODE=limit FAKE_CLAUDE_LIMIT_EXIT=0 bash "$HERE/fake-claude.sh" -p "x" >/dev/null
t_eq "fake: limit exit code overridable to 0" "0" "$?"

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
export CLAUDE_STANDBY_STATE="$PTMP/state.json"
export CLAUDE_STANDBY_LOG_DIR="$PTMP/logs"
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

# reset-time extraction from the measured limit message (F1)
. "$PLUGIN/scripts/lib.sh"
MSG="You've hit your session limit · resets 4:10pm (Asia/Dhaka)"
E="$(ar_parse_reset_time "$MSG")"
if [ -n "$E" ] && [ "$E" -gt "$(date +%s)" ] && [ "$E" -le $(( $(date +%s) + 86400 )) ]; then
  ok "resetparse: F1 message yields a future epoch within 24h"
else
  fail "resetparse: F1 message yields a future epoch within 24h" "got: '$E'"
fi
SHOWN="$(TZ=Asia/Dhaka date -r "$E" '+%I:%M%p' 2>/dev/null || TZ=Asia/Dhaka date -d "@$E" '+%I:%M%p')"
t_eq "resetparse: wall clock preserved in zone" "04:10PM" "$SHOWN"
E="$(ar_parse_reset_time "hit your session limit · resets 12:05am (America/New_York)")"
SHOWN="$(TZ=America/New_York date -r "$E" '+%I:%M%p' 2>/dev/null || TZ=America/New_York date -d "@$E" '+%I:%M%p')"
t_eq "resetparse: 12:05am midnight handling" "12:05AM" "$SHOWN"
E="$(ar_parse_reset_time "resets 9:00am")"
[ -n "$E" ] && [ "$E" -gt "$(date +%s)" ] && ok "resetparse: zoneless message uses local zone" \
  || fail "resetparse: zoneless message uses local zone" "got: '$E'"
if ar_parse_reset_time "no reset info here" >/dev/null; then
  fail "resetparse: garbage rejected"
else
  ok "resetparse: garbage rejected"
fi
rm -rf "$PTMP"

# ------------------------------------------------- scheduling + daemon --

DTMP="$(mktemp -d "${TMPDIR:-/tmp}/ar-test-XXXXXX")"
DTMP="$(cd "$DTMP" && pwd)"   # normalize: workspace keys come from pwd
export CLAUDE_STANDBY_STATE="$DTMP/state.json"
# Pin the rate snapshot to an isolated (absent) path so tests never read a
# real status-line cache on the dev machine (/tmp/claude_rate_cache_*).
# Rate-sensor tests point it at a file they control, then reset it here.
export CLAUDE_STANDBY_RATE_FILE="$DTMP/rate.json"
export CLAUDE_STANDBY_LOG_DIR="$DTMP/logs"
export CLAUDE_STANDBY_CLAUDE_BIN="$HERE/fake-claude.sh"
export CLAUDE_PROJECTS_DIR="$DTMP/projects"   # hermetic: no real session store
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

# daemon: repeated limit hits -> backoff then failed at max_resumes.
# Display is unparseable ("soon"): with no announced reset time the failure
# path must fall back to the blind backoff (0s here) and burn through the cap.
WS5="$DTMP/ws-limited"; mkdir -p "$WS5"
(cd "$WS5" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" now >/dev/null)
ar_task_set "$WS5" max_resumes 2
FAKE_CLAUDE_MODE=limit FAKE_CLAUDE_RESET_DISPLAY="soon" bash "$PLUGIN/scripts/daemon.sh" "$WS5"
t_eq "daemon: limited resume ends failed" "failed" "$(ar_task_get "$WS5" status)"
t_eq "daemon: attempts bounded by max_resumes" "2" "$(ar_task_get "$WS5" resume_count)"
t_contains "daemon: backoff journaled" "resume-failed" "$(ar_journal_show "$WS5" 10)"

# daemon: a resume that hits the limit again with an ANNOUNCED reset time
# (F1) reschedules to that time (+grace) instead of the blind backoff —
# retrying sooner would fire the remaining attempts into a still-active
# limit and burn max_resumes. Display computed ~2h ahead (see WS10 note).
_b2h=$(( $(date +%s) + 7200 ))
_bdisp="$(TZ='Asia/Dhaka' date -r "$_b2h" '+%I:%M%p' 2>/dev/null || TZ='Asia/Dhaka' date -d "@$_b2h" '+%I:%M%p' 2>/dev/null)"
_bdisp="$(printf '%s' "$_bdisp" | tr 'APM' 'apm') (Asia/Dhaka)"
WS5B="$DTMP/ws-bounce-reset"; mkdir -p "$WS5B"
(cd "$WS5B" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" now >/dev/null)
FAKE_CLAUDE_MODE=limit FAKE_CLAUDE_RESET_DISPLAY="$_bdisp" \
  AR_DAEMON_ONESHOT=1 AR_RESET_GRACE_SECS=0 bash "$PLUGIN/scripts/daemon.sh" "$WS5B"
t_eq "daemon: limited bounce keeps waiting" "waiting" "$(ar_task_get "$WS5B" status)"
t_eq "daemon: bounce consumed one attempt" "1" "$(ar_task_get "$WS5B" resume_count)"
t_contains "daemon: bounce journaled announced reset" "reset-detected" "$(ar_journal_show "$WS5B" 10)"
_bexpect="$(ar_parse_reset_time "resets $_bdisp")"
_bgot="$(ar_iso_to_epoch "$(ar_task_get "$WS5B" resume_at)")"
t_eq "daemon: bounce retries at the announced reset" "$_bexpect" "$_bgot"

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

# auto mode: limit lifts mid-wait -> daemon probes, detects, resumes.
# The limited CLI exits 0 here to prove the probe trusts the measured
# limit message (F1), not the exit code. Display is unparseable so the
# daemon falls back to interval polling.
MODEFILE="$DTMP/fake-mode"
printf 'limit' > "$MODEFILE"
export FAKE_CLAUDE_MODE_FILE="$MODEFILE"
export FAKE_CLAUDE_LIMIT_EXIT=0
export FAKE_CLAUDE_RESET_DISPLAY="soon"
export AR_PROBE_INTERVAL_SECS=1
bash "$PLUGIN/scripts/daemon.sh" "$WS7" &
DPID=$!
# Wait until the daemon has actually observed the limit before lifting it, so a
# loaded machine can't race us to "clean" before the first probe lands.
wait_until 20 '[ "$(ar_task_get "$WS7" limit_seen)" = 1 ]'
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

# auto mode: announced reset time is read from the limit message (F1).
# The reset display is computed ~2h ahead of NOW (not a hardcoded wall-clock
# time): the daemon only accepts an announced reset in (now+60s, now+23h), and
# a hardcoded past time rolls to ~tomorrow (parser adds 24h) which falls outside
# that window — so a fixed "4:10pm" made this test fail for the ~1h each day
# after that time had passed. Formatted in the measured 12-hour form, TZ-pinned
# so it matches the zone named in the message, portable across BSD/GNU date.
_r2h=$(( $(date +%s) + 7200 ))
_rdisp="$(TZ='Asia/Dhaka' date -r "$_r2h" '+%I:%M%p' 2>/dev/null || TZ='Asia/Dhaka' date -d "@$_r2h" '+%I:%M%p' 2>/dev/null)"
_rdisp="$(printf '%s' "$_rdisp" | tr 'APM' 'apm')"
WS10="$DTMP/ws-auto-parse"; mkdir -p "$WS10"
printf 'limit' > "$MODEFILE"
export FAKE_CLAUDE_RESET_DISPLAY="$_rdisp (Asia/Dhaka)"
(cd "$WS10" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" auto >/dev/null)
bash "$PLUGIN/scripts/daemon.sh" "$WS10" &
DPID=$!
wait_until 20 'ar_journal_show "$WS10" 5 | grep -q reset-detected'
t_contains "auto: reset-detected journaled from message" "reset-detected" "$(ar_journal_show "$WS10" 5)"
t_eq "auto: waits for the announced time" "waiting" "$(ar_task_get "$WS10" status)"
kill "$DPID" 2>/dev/null
wait "$DPID" 2>/dev/null

# scheduled mode: a resume that bounces off the limit with exit 0 must
# NOT be marked done (bounce guard on the measured message)
WS11="$DTMP/ws-bounce0"; mkdir -p "$WS11"
export FAKE_CLAUDE_RESET_DISPLAY="soon"
(cd "$WS11" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" now >/dev/null)
ar_task_set "$WS11" max_resumes 1
bash "$PLUGIN/scripts/daemon.sh" "$WS11"
t_eq "daemon: exit-0 limit bounce ends failed, not done" "failed" "$(ar_task_get "$WS11" status)"

# auto mode: scheduled while NOT limited must NOT resume a live session.
# (Regression: auto-detect probed, the first probe succeeded because there
# was no limit, and it resumed the user's active conversation immediately.)
WS14="$DTMP/ws-auto-armed"; mkdir -p "$WS14"
printf 'clean' > "$MODEFILE"           # never limited
(cd "$WS14" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" auto critical >/dev/null)
AR_DAEMON_ONESHOT=1 bash "$PLUGIN/scripts/daemon.sh" "$WS14"
t_eq   "auto-armed: not limited => stays waiting, no resume" "waiting" "$(ar_task_get "$WS14" status)"
t_eq   "auto-armed: resume_count stays 0" "0" "$(ar_task_get "$WS14" resume_count)"
t_contains "auto-armed: journaled as armed" "armed" "$(ar_journal_show "$WS14" 6)"
# and it must NOT have journaled a resume or a false limit-lifted
RJ="$(ar_journal_show "$WS14" 8)"
case "$RJ" in
  *limit-lifted*|*resumed*) fail "auto-armed: no false limit-lifted/resumed" "$RJ" ;;
  *) ok "auto-armed: no false limit-lifted/resumed" ;;
esac

# once a limit IS seen (probe fails), a later clean probe DOES resume
WS15="$DTMP/ws-auto-armed-then-limit"; mkdir -p "$WS15"
printf 'limit' > "$MODEFILE"
(cd "$WS15" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" auto critical >/dev/null)
AR_DAEMON_ONESHOT=1 bash "$PLUGIN/scripts/daemon.sh" "$WS15"   # sees limit, arms
t_eq "auto-armed: limit observed sets limit_seen" "1" "$(ar_task_get "$WS15" limit_seen)"
t_eq "auto-armed: still waiting after seeing limit" "waiting" "$(ar_task_get "$WS15" status)"
printf 'clean' > "$MODEFILE"
bash "$PLUGIN/scripts/daemon.sh" "$WS15" &                     # limit lifts -> resume
DPID=$!; WAITED=0
while kill -0 "$DPID" 2>/dev/null && [ "$WAITED" -lt 15 ]; do sleep 1; WAITED=$((WAITED + 1)); done
kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
t_eq "auto-armed: resumes once the seen limit lifts" "done" "$(ar_task_get "$WS15" status)"

# the limit_seen gate must survive under the awk/text engine too (the C2
# fallback when neither jq nor python3 exists) — otherwise auto-detect
# could never remember a limit and would never resume on jq-less hosts.
WS16="$DTMP/ws-armed-text"; mkdir -p "$WS16"
printf 'clean' > "$MODEFILE"
(cd "$WS16" && AR_JSON_ENGINE=text AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" auto critical >/dev/null)
AR_JSON_ENGINE=text AR_DAEMON_ONESHOT=1 bash "$PLUGIN/scripts/daemon.sh" "$WS16"
t_eq "text-engine: armed (not limited) stays waiting" "waiting" "$(ar_task_get "$WS16" status)"
WS17="$DTMP/ws-limit-text"; mkdir -p "$WS17"
printf 'limit' > "$MODEFILE"
(cd "$WS17" && AR_JSON_ENGINE=text AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" auto critical >/dev/null)
AR_JSON_ENGINE=text AR_DAEMON_ONESHOT=1 bash "$PLUGIN/scripts/daemon.sh" "$WS17"
t_eq "text-engine: a seen limit is remembered (limit_seen=1)" "1" "$(ar_task_get "$WS17" limit_seen)"

# the daemon records its own pid, so the cockpit can distinguish an
# in-flight resume (pid alive) from an interrupted one (status stuck at
# "resuming" but the daemon gone). WS14's daemon ran above.
PIDVAL="$(ar_task_get "$WS14" daemon_pid)"
case "$PIDVAL" in
  ''|*[!0-9]*) fail "daemon: records its numeric pid" "got '$PIDVAL'" ;;
  *) ok "daemon: records its numeric pid" ;;
esac

# armed-window bound: an armed auto-detect task that never sees a limit
# must stand down instead of probing forever and burning quota (C6).
WS18="$DTMP/ws-armed-expire"; mkdir -p "$WS18"
printf 'clean' > "$MODEFILE"
(cd "$WS18" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" auto critical >/dev/null)
ar_task_set "$WS18" armed_since "$(( $(date +%s) - 100 ))"
AR_ARMED_MAX_SECS=1 AR_DAEMON_ONESHOT=1 bash "$PLUGIN/scripts/daemon.sh" "$WS18"
t_eq "armed-bound: stands down after the armed window" "failed" "$(ar_task_get "$WS18" status)"
t_contains "armed-bound: give-up journaled" "stood down" "$(ar_journal_show "$WS18" 5)"
t_eq "armed-bound: no resume happened" "0" "$(ar_task_get "$WS18" resume_count)"

# armed-window bound: ARMED_MAX=0 opts out — probe indefinitely, never
# giving up on arming even with an ancient armed_since.
WS19="$DTMP/ws-armed-nobound"; mkdir -p "$WS19"
(cd "$WS19" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" auto critical >/dev/null)
ar_task_set "$WS19" armed_since "$(( $(date +%s) - 100000 ))"
AR_ARMED_MAX_SECS=0 AR_DAEMON_ONESHOT=1 bash "$PLUGIN/scripts/daemon.sh" "$WS19"
t_eq "armed-bound: ARMED_MAX=0 keeps waiting" "waiting" "$(ar_task_get "$WS19" status)"

# --- rate-sensor auto path (HOOK-FINDINGS F4) --------------------------------
# A dedicated rate file so these don't perturb the probe-path tests (which
# rely on the default rate.json being absent). Unset again at the end.
export CLAUDE_STANDBY_RATE_FILE="$DTMP/rate-sensor.json"
RFUT=$(( $(date +%s) + 3600 ))
mkrate() { printf '{ "captured_at": %s, "resets_at": %s, "used_percentage": %s }\n' \
  "$(date +%s)" "$RFUT" "$1" > "$CLAUDE_STANDBY_RATE_FILE"; }

# the status-line sensor captures rate_limits into rate.json
printf '{"rate_limits":{"five_hour":{"used_percentage":33,"resets_at":%s}}}' "$RFUT" |
  bash "$PLUGIN/scripts/statusline.sh"
t_contains "sensor: captures used_percentage into rate.json" '"used_percentage": 33' \
  "$(cat "$CLAUDE_STANDBY_RATE_FILE")"

# armed via sensor (low usage): the sensor says "not limited", but we do NOT
# trust used_percentage (unverified at a real block) — we fall through to a
# probe as a backstop. Probe is clean here, so the task stays armed, no limit.
WSR1="$DTMP/ws-rate-armed"; mkdir -p "$WSR1"
(cd "$WSR1" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" auto critical >/dev/null)
mkrate 20
printf 'clean' > "$MODEFILE"
AR_DAEMON_ONESHOT=1 bash "$PLUGIN/scripts/daemon.sh" "$WSR1"
t_eq "rate: armed (low usage) stays waiting" "waiting" "$(ar_task_get "$WSR1" status)"
t_eq "rate: armed keeps limit_seen 0" "0" "$(ar_task_get "$WSR1" limit_seen)"
t_contains "rate: armed journaled" "will resume after you hit a limit" "$(ar_journal_show "$WSR1" 3)"

# F4 must not blind F1: the sensor under-reports (used 20 < 100) but a probe
# detects a real limit — the backstop catches it (limit_seen=1) instead of
# leaving a genuinely-limited task stranded "armed" until it stands down.
WSR1b="$DTMP/ws-rate-underreport"; mkdir -p "$WSR1b"
(cd "$WSR1b" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" auto critical >/dev/null)
mkrate 20
printf 'limit' > "$MODEFILE"
AR_DAEMON_ONESHOT=1 bash "$PLUGIN/scripts/daemon.sh" "$WSR1b"
t_eq "rate: sensor under-reports but the probe backstop catches the limit" "1" "$(ar_task_get "$WSR1b" limit_seen)"
printf 'clean' > "$MODEFILE"

# limited via sensor (100%): limit_seen=1, schedules the reset time plus the
# post-reset safety grace (default 60s) so we don't attempt on the exact dot.
WSR2="$DTMP/ws-rate-limited"; mkdir -p "$WSR2"
(cd "$WSR2" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" auto critical >/dev/null)
mkrate 100
AR_RESET_GRACE_SECS=60 AR_DAEMON_ONESHOT=1 bash "$PLUGIN/scripts/daemon.sh" "$WSR2"
t_eq "rate: limited sets limit_seen" "1" "$(ar_task_get "$WSR2" limit_seen)"
t_eq "rate: schedules reset + safety grace" "$(ar_epoch_to_iso $(( RFUT + 60 )))" "$(ar_task_get "$WSR2" resume_at)"
# grace is configurable: 0 = attempt exactly at the reset
WSR2b="$DTMP/ws-rate-limited-nograce"; mkdir -p "$WSR2b"
(cd "$WSR2b" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" auto critical >/dev/null)
mkrate 100
AR_RESET_GRACE_SECS=0 AR_DAEMON_ONESHOT=1 bash "$PLUGIN/scripts/daemon.sh" "$WSR2b"
t_eq "rate: grace 0 schedules the exact reset" "$(ar_epoch_to_iso "$RFUT")" "$(ar_task_get "$WSR2b" resume_at)"

# `resume-at reset` (Situation A): you confirmed the limit, so schedule a
# known-time resume to the local reset + grace (mode=at), no probe, no
# used_percentage. Rate says used=50 here on purpose — reset must NOT consult it.
WSRR="$DTMP/ws-reset-kw"; mkdir -p "$WSRR"
printf '{ "captured_at": %s, "resets_at": %s, "used_percentage": 50 }\n' "$(date +%s)" "$RFUT" > "$CLAUDE_STANDBY_RATE_FILE"
(cd "$WSRR" && AR_NO_DAEMON=1 AR_RESET_GRACE_SECS=60 bash "$PLUGIN/scripts/task-resume-at.sh" reset critical >/dev/null)
t_eq "reset: schedules known-time mode (not auto)" "at" "$(ar_task_get "$WSRR" resume_mode)"
t_eq "reset: resume_at is reset + grace" "$(ar_epoch_to_iso $(( RFUT + 60 )))" "$(ar_task_get "$WSRR" resume_at)"
t_eq "reset: marks the limit confirmed" "1" "$(ar_task_get "$WSRR" limit_seen)"
# reset with NO local rate snapshot: refuses and guides, does not schedule
WSRR2="$DTMP/ws-reset-norate"; mkdir -p "$WSRR2"
rm -f "$CLAUDE_STANDBY_RATE_FILE"
ROUT="$(cd "$WSRR2" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" reset 2>&1)"
t_contains "reset: no rate snapshot is guided, not scheduled" "No local reset time" "$ROUT"
t_eq "reset: nothing scheduled without a reset time" "" "$(ar_task_get "$WSRR2" resume_mode)"
mkrate 100   # restore for the tests below

# seen a limit, then usage fell: resumes via the sensor (no probe)
WSR3="$DTMP/ws-rate-resume"; mkdir -p "$WSR3"
(cd "$WSR3" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" auto critical >/dev/null)
ar_task_set "$WSR3" limit_seen 1; ar_task_set "$WSR3" limit_seen_at "$(date +%s)"
mkrate 5
printf 'clean' > "$MODEFILE"
bash "$PLUGIN/scripts/daemon.sh" "$WSR3" & DPR=$!; WR=0
while kill -0 "$DPR" 2>/dev/null && [ "$WR" -lt 15 ]; do sleep 1; WR=$((WR + 1)); done
kill "$DPR" 2>/dev/null; wait "$DPR" 2>/dev/null
t_eq "rate: resumes when usage falls after a seen limit" "done" "$(ar_task_get "$WSR3" status)"

# absent rate.json -> the probe path still runs (no regression)
rm -f "$CLAUDE_STANDBY_RATE_FILE"
WSR4="$DTMP/ws-rate-absent"; mkdir -p "$WSR4"
printf 'clean' > "$MODEFILE"
(cd "$WSR4" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" auto critical >/dev/null)
AR_DAEMON_ONESHOT=1 bash "$PLUGIN/scripts/daemon.sh" "$WSR4"
t_contains "rate: absent rate.json falls back to probe wording" "will resume after you hit a limit" \
  "$(ar_journal_show "$WSR4" 3)"

# setup-statusline chains an existing status line and restores it on remove
SLT="$DTMP/sl-settings.json"
printf '{ "statusLine": { "type": "command", "command": "echo ORIG" }, "model": "x" }\n' > "$SLT"
CLAUDE_SETTINGS_FILE="$SLT" bash "$PLUGIN/scripts/setup-statusline.sh" install >/dev/null
t_contains "setup-statusline: registers our sensor" "statusline.sh" "$(cat "$SLT")"
t_contains "setup-statusline: chains the original command" "echo ORIG" "$(cat "$DTMP/statusline-chain")"
CLAUDE_SETTINGS_FILE="$SLT" bash "$PLUGIN/scripts/setup-statusline.sh" remove >/dev/null
t_contains "setup-statusline: restores the original on remove" "echo ORIG" "$(cat "$SLT")"
t_contains "setup-statusline: preserves unrelated keys" '"model"' "$(cat "$SLT")"

# a registration pointing at an OLD install path is refreshed, not chained
printf '{ "statusLine": { "type": "command", "command": "bash \\"/old/gone/plugin/scripts/statusline.sh\\"" } }\n' > "$SLT"
OUT="$(CLAUDE_SETTINGS_FILE="$SLT" bash "$PLUGIN/scripts/setup-statusline.sh" install)"
t_contains "setup-statusline: stale path is refreshed" "path refreshed" "$OUT"
t_contains "setup-statusline: settings point at current install" "$(cd "$PLUGIN" && pwd)/scripts/statusline.sh" "$(cat "$SLT")"
[ ! -f "$DTMP/statusline-chain" ] && ok "setup-statusline: never chains our own stale sensor" \
  || fail "setup-statusline: never chains our own stale sensor" "$(cat "$DTMP/statusline-chain")"
OUT="$(CLAUDE_SETTINGS_FILE="$SLT" bash "$PLUGIN/scripts/setup-statusline.sh" install)"
t_contains "setup-statusline: idempotent when current" "already registered" "$OUT"
CLAUDE_SETTINGS_FILE="$SLT" bash "$PLUGIN/scripts/setup-statusline.sh" remove >/dev/null

# back to the isolated (absent) default for the remaining probe-path tests
rm -f "$DTMP/rate-sensor.json"
export CLAUDE_STANDBY_RATE_FILE="$DTMP/rate.json"

# auto mode: gives up when limit never lifts within the window
WS9="$DTMP/ws-auto-giveup"; mkdir -p "$WS9"
printf 'limit' > "$MODEFILE"
(cd "$WS9" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" auto >/dev/null)
AR_AUTO_GIVEUP_SECS=1 bash "$PLUGIN/scripts/daemon.sh" "$WS9"
t_eq "auto: gives up after window" "failed" "$(ar_task_get "$WS9" status)"
t_contains "auto: give-up journaled" "did not lift" "$(ar_journal_show "$WS9" 5)"
unset FAKE_CLAUDE_MODE_FILE AR_PROBE_INTERVAL_SECS FAKE_CLAUDE_LIMIT_EXIT FAKE_CLAUDE_RESET_DISPLAY

# cancel while a resume is in flight must not be overwritten by "done"
WS12="$DTMP/ws-cancel-mid"; mkdir -p "$WS12"
(cd "$WS12" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" now >/dev/null)
FAKE_CLAUDE_RUN_SECS=3 bash "$PLUGIN/scripts/daemon.sh" "$WS12" &
DPID=$!
# Cancel genuinely mid-flight: wait until the resume has actually started
# (status=resuming) rather than blindly racing a fixed sleep.
wait_until 20 '[ "$(ar_task_get "$WS12" status)" = resuming ]'
ar_task_set "$WS12" status cancelled
wait "$DPID" 2>/dev/null
t_eq "daemon: cancel during in-flight resume preserved" "cancelled" "$(ar_task_get "$WS12" status)"
t_contains "daemon: in-flight cancel journaled" "resume-finished" "$(ar_journal_show "$WS12" 5)"

# cancel kills the daemon (and any children) immediately, not next tick
WS13="$DTMP/ws-cancel-kills"; mkdir -p "$WS13"
(cd "$WS13" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" 45m >/dev/null)
AR_DAEMON_TICK_SECS=600 bash "$PLUGIN/scripts/daemon.sh" "$WS13" &
DPID=$!
# Wait until the daemon has registered its pid before cancelling, so cancel has
# a live daemon to kill even on a loaded machine; then give it a moment to exit.
wait_until 20 '[ -n "$(ar_task_get "$WS13" daemon_pid)" ]'
(cd "$WS13" && bash "$PLUGIN/scripts/task-cancel.sh" >/dev/null)
wait_until 20 '! kill -0 "$DPID" 2>/dev/null'
if kill -0 "$DPID" 2>/dev/null; then
  kill "$DPID" 2>/dev/null
  fail "cancel: kills waiting daemon immediately" "daemon $DPID survived cancel"
else
  ok "cancel: kills waiting daemon immediately"
fi
wait "$DPID" 2>/dev/null
t_eq "cancel: status set" "cancelled" "$(ar_task_get "$WS13" status)"

# daemon: pidfiles cleaned up
if ls "$DTMP"/daemons/*.pid >/dev/null 2>&1; then
  fail "daemon: pidfiles cleaned up" "$(ls "$DTMP"/daemons/)"
else
  ok "daemon: pidfiles cleaned up"
fi

unset CLAUDE_STANDBY_CLAUDE_BIN FAKE_CLAUDE_TRANSCRIPT_DIR FAKE_CLAUDE_MODE
rm -rf "$DTMP"

# ------------------------------------------------------ session selection --
# Session discovery + pinning against a fixture store in the MEASURED
# layout (HOOK-FINDINGS F2): projects/<encoded-ws>/<uuid>.jsonl

SETMP="$(mktemp -d "${TMPDIR:-/tmp}/ar-test-XXXXXX")"
SETMP="$(cd "$SETMP" && pwd)"
export CLAUDE_STANDBY_STATE="$SETMP/state.json"
export CLAUDE_STANDBY_LOG_DIR="$SETMP/logs"
export CLAUDE_PROJECTS_DIR="$SETMP/projects"
export CLAUDE_STANDBY_CLAUDE_BIN="$HERE/fake-claude.sh"
export FAKE_CLAUDE_TRANSCRIPT_DIR="$SETMP/transcripts"
export FAKE_CLAUDE_RUN_SECS=0
export FAKE_CLAUDE_MODE=clean
export AR_DAEMON_TICK_SECS=1
export AR_NOTIFY_SILENT=1
unset AR_JSON_ENGINE
. "$PLUGIN/scripts/lib.sh"

SWS="$SETMP/ws-sessions"; mkdir -p "$SWS"
SPDIR="$(ar_project_dir "$SWS")"
t_eq "sessions: project dir encoding" \
  "$SETMP/projects/$(printf '%s' "$SWS" | sed 's/[^A-Za-z0-9]/-/g')" "$SPDIR"

mkdir -p "$SPDIR/memory"
OLD_ID="aaaaaaaa-1111-2222-3333-444444444444"
NEW_ID="bbbbbbbb-5555-6666-7777-888888888888"
# older session: string content (F2 sample shape)
printf '%s\n' \
  '{"type":"user","message":{"role":"user","content":"Fix the login bug in auth.js"},"sessionId":"'"$OLD_ID"'","timestamp":"2026-07-18T10:00:00.000Z"}' \
  > "$SPDIR/$OLD_ID.jsonl"
# newer session: command line first (must be skipped), then array content
printf '%s\n' \
  '{"type":"user","message":{"role":"user","content":"<command-message>x</command-message>\n<command-name>/x</command-name>"},"sessionId":"'"$NEW_ID"'"}' \
  '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Migrate the database schema to v2"}]},"sessionId":"'"$NEW_ID"'"}' \
  > "$SPDIR/$NEW_ID.jsonl"
echo '{"not":"a session"}' > "$SPDIR/notes.jsonl"
touch -t 202607181000 "$SPDIR/$OLD_ID.jsonl"

SLIST="$(ar_sessions_list "$SWS")"
t_eq "sessions: uuid files only, both found" "2" "$(printf '%s\n' "$SLIST" | grep -c .)"
t_eq "sessions: newest first" "$NEW_ID" "$(printf '%s\n' "$SLIST" | head -1 | cut -f1)"
t_eq "sessions: latest helper" "$NEW_ID" "$(ar_session_latest "$SWS")"
if command -v python3 >/dev/null 2>&1; then
  t_contains "sessions: summary skips command lines" "Migrate the database" \
    "$(printf '%s\n' "$SLIST" | head -1 | cut -f4)"
fi

SOUT="$(cd "$SWS" && bash "$PLUGIN/scripts/task-sessions.sh")"
t_contains "sessions cmd: lists newest id" "bbbbbbbb" "$SOUT"
t_contains "sessions cmd: hints at pinning" "resume-at" "$SOUT"

# scheduling with no --session pins the newest session automatically
(cd "$SWS" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" now >/dev/null)
t_eq "pin: default pins latest session" "$NEW_ID" "$(ar_task_get "$SWS" session_id)"
t_contains "pin: journaled" "session-pinned" "$(ar_journal_show "$SWS" 5)"

# --session <index> picks from the numbered list; prefix works too
(cd "$SWS" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" now --session 2 >/dev/null)
t_eq "pin: --session index" "$OLD_ID" "$(ar_task_get "$SWS" session_id)"
(cd "$SWS" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" now --session bbbbbbbb >/dev/null)
t_eq "pin: --session id prefix" "$NEW_ID" "$(ar_task_get "$SWS" session_id)"

# --session new explicitly starts a fresh chat
SOUT="$(cd "$SWS" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" now --session new)"
t_eq "pin: --session new clears" "" "$(ar_task_get "$SWS" session_id)"
t_contains "pin: new chat confirmed" "new chat" "$SOUT"

# a pinned session survives rescheduling (no silent re-pin to latest)
ar_task_set "$SWS" session_id "$OLD_ID"
(cd "$SWS" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" 45m >/dev/null)
t_eq "pin: reschedule keeps existing pin" "$OLD_ID" "$(ar_task_get "$SWS" session_id)"

# unknown --session refuses instead of silently starting a new chat
SOUT="$(cd "$SWS" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" now --session 99)"
t_contains "pin: bad --session index refused" "No session matches" "$SOUT"

# a non-matching, non-uuid-shaped value is a typo, not an id: refuse it
# instead of pinning the raw string (would resume a nonexistent session).
SOUT="$(cd "$SWS" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" now --session zzzz9999)"
t_contains "pin: bad --session prefix refused" "No session matches" "$SOUT"
if [ "$(ar_task_get "$SWS" session_id)" != "zzzz9999" ]; then
  ok "pin: bad --session prefix never pinned the raw value"
else
  fail "pin: bad --session prefix never pinned the raw value"
fi

# but a full uuid-shaped id not in the listing is still accepted (cap-proof)
UNLISTED="ffffffff-ffff-ffff-ffff-ffffffffffff"
(cd "$SWS" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" now --session "$UNLISTED" >/dev/null)
t_eq "pin: uuid-shaped id accepted even if unlisted" "$UNLISTED" "$(ar_task_get "$SWS" session_id)"

# the daemon resumes THE PINNED SESSION: fake-claude appends to
# <session_id>.jsonl when called with --resume (its transcript is keyed
# by the resume id), so that file proves --resume was passed through.
(cd "$SWS" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" now --session 1 >/dev/null)
bash "$PLUGIN/scripts/daemon.sh" "$SWS"
t_eq "daemon: resume continues pinned session" "done" "$(ar_task_get "$SWS" status)"
if [ -f "$SETMP/transcripts/$NEW_ID.jsonl" ]; then
  ok "daemon: claude called with --resume <pinned id>"
else
  fail "daemon: claude called with --resume <pinned id>" \
    "$(ls "$SETMP/transcripts" 2>/dev/null)"
fi
t_contains "daemon: journal names the session" "bbbbbbbb" "$(ar_journal_show "$SWS" 10)"

# --prompt: custom resume message is stored and delivered verbatim
(cd "$SWS" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" now --session 1 \
  --prompt "Custom continue: finish step 4 then run the tests" >/dev/null)
t_eq "prompt: custom prompt stored" "Custom continue: finish step 4 then run the tests" \
  "$(ar_task_get "$SWS" resume_prompt_template)"
t_contains "prompt: journaled" "prompt-set" "$(ar_journal_show "$SWS" 5)"
bash "$PLUGIN/scripts/daemon.sh" "$SWS"
t_contains "prompt: daemon delivers the custom prompt" "Custom continue: finish step 4" \
  "$(cat "$SETMP/transcripts/$NEW_ID.jsonl")"

# --workspace: schedule another project without cd-ing into it
WSB="$SETMP/ws-other"; mkdir -p "$WSB"
WOUT="$(cd "$SETMP" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" 45m --workspace "$WSB")"
t_contains "workspace flag: confirms" "Resume scheduled." "$WOUT"
t_eq "workspace flag: task keyed to target dir" "waiting" "$(ar_task_get "$WSB" status)"
t_contains "workspace flag: bad path refused" "not a directory" \
  "$(AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" now --workspace "$SETMP/nope")"

# sessions --workspace lists another project's sessions
t_contains "sessions --workspace" "bbbbbbbb" \
  "$(cd "$SETMP" && bash "$PLUGIN/scripts/task-sessions.sh" --workspace "$SWS")"

unset CLAUDE_STANDBY_CLAUDE_BIN CLAUDE_PROJECTS_DIR FAKE_CLAUDE_TRANSCRIPT_DIR FAKE_CLAUDE_MODE
rm -rf "$SETMP"

# -------------------------------------------------------------- cli wrapper --

CTMP="$(mktemp -d "${TMPDIR:-/tmp}/ar-test-XXXXXX")"
CTMP="$(cd "$CTMP" && pwd)"
export CLAUDE_STANDBY_STATE="$CTMP/state.json"
export CLAUDE_STANDBY_LOG_DIR="$CTMP/logs"
export AR_NOTIFY_SILENT=1
unset AR_JSON_ENGINE
. "$PLUGIN/scripts/lib.sh"
CLI="$HERE/../bin/claude-standby"
CWS="$CTMP/cli-ws"; mkdir -p "$CWS"

t_contains "cli: status with no task" "No tracked task" "$(cd "$CWS" && bash "$CLI" status)"
t_contains "cli: default command is status" "No tracked task" "$(cd "$CWS" && bash "$CLI")"
t_contains "cli: empty list" "No tracked tasks." "$(bash "$CLI" list)"
(cd "$CWS" && bash "$CLI" start normal "cli smoke task" >/dev/null)
t_eq "cli: start tracks task" "normal" "$(ar_task_get "$CWS" importance)"
LOUT="$(bash "$CLI" list)"
t_contains "cli: list shows workspace" "$CWS" "$LOUT"
t_contains "cli: list shows status column" "running" "$LOUT"
t_contains "cli: resume-at schedules" "Resume scheduled." "$(cd "$CWS" && AR_NO_DAEMON=1 bash "$CLI" resume-at 30m)"
(cd "$CWS" && bash "$CLI" cancel >/dev/null)
t_eq "cli: cancel works" "cancelled" "$(ar_task_get "$CWS" status)"
t_contains "cli: log shows entries" "task-start:" "$(bash "$CLI" log)"
t_contains "cli: unknown command shows usage" "Usage" "$(bash "$CLI" bogus 2>&1)"
HOUT="$(bash "$CLI" --help)"
t_contains "cli: help shows usage" "Usage" "$HOUT"
case "$HOUT" in
  *"set -u"*) fail "cli: help leaks no code" "$HOUT" ;;
  *) ok "cli: help leaks no code" ;;
esac

# version comes from the VERSION file — read it, don't hardcode it
MANIFEST_VER="$(head -1 "$HERE/../VERSION" | tr -d '[:space:]')"
t_contains "cli: version" "claude-standby $MANIFEST_VER" "$(bash "$CLI" version)"
t_contains "cli: --version flag" "claude-standby $MANIFEST_VER" "$(bash "$CLI" --version)"
DOUT="$(CLAUDE_STANDBY_CLAUDE_BIN="$HERE/fake-claude.sh" bash "$CLI" doctor)"
DRC=$?
t_eq "cli: doctor exits 0 when healthy" "0" "$DRC"
t_contains "cli: doctor reports claude" "claude" "$DOUT"
t_contains "cli: doctor reports json engine" "engine:" "$DOUT"
t_contains "cli: doctor reports daemons" "daemons" "$DOUT"
DOUT="$(CLAUDE_STANDBY_CLAUDE_BIN="/nonexistent-claude" bash "$CLI" doctor)"
DRC=$?
t_eq "cli: doctor exits 1 when claude missing" "1" "$DRC"
t_contains "cli: doctor flags missing claude" "MISS" "$DOUT"
rm -rf "$CTMP"

# --------------------------------------------------------------- installer --
# Offline: installs from a tarball of the local repo's HEAD (D36 — the
# install is a plain tree, never a git checkout).

ROOT="$(cd "$HERE/.." && pwd)"
if command -v git >/dev/null 2>&1 && [ -d "$ROOT/.git" ]; then
  # Never let the installer's sensor offer prompt (a dev terminal has a
  # /dev/tty) or touch the real ~/.claude/settings.json; the sensor tests
  # below opt in explicitly against an isolated settings file.
  export CAR_SETUP_STATUSLINE=no
  ITMP="$(mktemp -d "${TMPDIR:-/tmp}/ar-test-XXXXXX")"
  ITMP="$(cd "$ITMP" && pwd)"
  TARBALL="$ITMP/src.tgz"
  git -C "$ROOT" archive --prefix=car/ HEAD | gzip > "$TARBALL"
  OUT="$(CAR_TARBALL_URL="$TARBALL" CAR_INSTALL_DIR="$ITMP/app" CAR_BIN_DIR="$ITMP/bin" bash "$ROOT/install.sh" 2>&1)"
  t_contains "installer: links the CLI" "Linked" "$OUT"
  [ -x "$ITMP/bin/claude-standby" ] && ok "installer: CLI link executable" || fail "installer: CLI link executable"
  [ ! -e "$ITMP/app/.git" ] && ok "installer: install is a plain tree (no .git)" \
    || fail "installer: install is a plain tree (no .git)"
  IWS="$ITMP/ws"; mkdir -p "$IWS"
  OUT="$(cd "$IWS" && CLAUDE_STANDBY_STATE="$ITMP/state.json" CLAUDE_STANDBY_LOG_DIR="$ITMP/logs" "$ITMP/bin/claude-standby" status)"
  t_contains "installer: installed CLI runs through symlink" "No tracked task" "$OUT"
  OUT="$(CAR_TARBALL_URL="$TARBALL" CAR_INSTALL_DIR="$ITMP/app" CAR_BIN_DIR="$ITMP/bin" bash "$ROOT/install.sh" 2>&1)"
  t_contains "installer: re-run updates in place" "Updating existing install" "$OUT"

  # statusline sensor offer (D41): opt-in at install time. Explicit yes
  # registers into the given settings file (preserving unrelated keys);
  # the default here is CAR_SETUP_STATUSLINE=no (exported above), which
  # must leave settings untouched but print the recommendation.
  ISL="$ITMP/sensor-settings.json"; printf '{"model": "opus"}\n' > "$ISL"
  OUT="$(CAR_TARBALL_URL="$TARBALL" CAR_INSTALL_DIR="$ITMP/app" CAR_BIN_DIR="$ITMP/bin" \
    CLAUDE_SETTINGS_FILE="$ISL" CAR_SETUP_STATUSLINE=yes bash "$ROOT/install.sh" 2>&1)"
  t_contains "installer: sensor opt-in registers" "plugin/scripts/statusline.sh" "$(cat "$ISL")"
  t_contains "installer: sensor opt-in preserves settings keys" '"model"' "$(cat "$ISL")"
  OUT="$(CAR_TARBALL_URL="$TARBALL" CAR_INSTALL_DIR="$ITMP/app" CAR_BIN_DIR="$ITMP/bin" \
    CLAUDE_SETTINGS_FILE="$ISL" bash "$ROOT/install.sh" 2>&1)"
  case "$OUT" in
    *"Recommended:  claude-standby setup-statusline"*)
      fail "installer: no sensor hint once registered" "$OUT" ;;
    *) ok "installer: no sensor hint once registered" ;;
  esac
  ISL2="$ITMP/sensor-settings-no.json"; printf '{"model": "opus"}\n' > "$ISL2"
  OUT="$(CAR_TARBALL_URL="$TARBALL" CAR_INSTALL_DIR="$ITMP/app" CAR_BIN_DIR="$ITMP/bin" \
    CLAUDE_SETTINGS_FILE="$ISL2" bash "$ROOT/install.sh" 2>&1)"
  t_eq "installer: sensor default leaves settings alone" '{"model": "opus"}' "$(cat "$ISL2")"
  t_contains "installer: sensor hint when not registered" "setup-statusline" "$OUT"
  # a corrupt download must never replace a working install
  printf 'garbage' > "$ITMP/bad.tgz"
  OUT="$(CAR_TARBALL_URL="$ITMP/bad.tgz" CAR_INSTALL_DIR="$ITMP/app" bash "$ROOT/install.sh" --update 2>&1)"; URC=$?
  t_eq "installer: bad download fails the update" "1" "$URC"
  [ -x "$ITMP/app/bin/claude-standby" ] && ok "installer: bad download leaves install untouched" \
    || fail "installer: bad download leaves install untouched"
  # a VALID tarball that is missing a key engine file (truncated/partial) must
  # be rejected by the staging sanity check, not swapped in
  INCTMP="$(mktemp -d "${TMPDIR:-/tmp}/ar-inc-XXXXXX")"
  mkdir "$INCTMP/pkg"
  tar -xzf "$TARBALL" -C "$INCTMP/pkg" --strip-components 1
  rm -f "$INCTMP/pkg/plugin/scripts/daemon.sh"
  ( cd "$INCTMP" && tar -czf "$ITMP/incomplete.tgz" pkg )
  OUT="$(CAR_TARBALL_URL="$ITMP/incomplete.tgz" CAR_INSTALL_DIR="$ITMP/app" bash "$ROOT/install.sh" --update 2>&1)"; URC=$?
  t_eq "installer: incomplete download fails the update" "1" "$URC"
  t_contains "installer: incomplete download names the missing file" "incomplete" "$OUT"
  [ -s "$ITMP/app/plugin/scripts/daemon.sh" ] && ok "installer: incomplete download leaves install intact" \
    || fail "installer: incomplete download leaves install intact"
  rm -rf "$INCTMP"
  # the tarball has HEAD; test the working-tree CLI + scripts + installer
  # against the installed layout
  cp "$ROOT/bin/claude-standby" "$ITMP/app/bin/claude-standby"
  cp "$ROOT"/plugin/scripts/*.sh "$ITMP/app/plugin/scripts/"
  cp "$ROOT/install.sh" "$ITMP/app/install.sh"
  OUT="$(CAR_TARBALL_URL="$TARBALL" "$ITMP/bin/claude-standby" update 2>&1)"
  t_contains "cli: update swaps and reports the version" "Already up to date" "$OUT"
  if printf '%s' "$OUT" | grep -q "Fast-forward\|Unpacking objects"; then
    fail "cli: update shows no raw git output" "$OUT"
  else
    ok "cli: update shows no raw git output"
  fi
  [ ! -e "$ITMP/app/.git" ] && ok "cli: update leaves a plain tree" || fail "cli: update leaves a plain tree"
  # the swap reset the tree to HEAD — put the working-tree files back
  cp "$ROOT/bin/claude-standby" "$ITMP/app/bin/claude-standby"
  cp "$ROOT"/plugin/scripts/*.sh "$ITMP/app/plugin/scripts/"
  # a git checkout at an unmanaged path is a dev copy: update + uninstall refuse
  git -C "$ITMP/app" init -q 2>/dev/null
  echo junk > "$ITMP/app/JUNK"
  OUT="$("$ITMP/bin/claude-standby" update 2>&1)"; URC=$?
  t_eq "cli: update refuses a dev checkout" "1" "$URC"
  t_contains "cli: update points a dev checkout at git" "development checkout" "$OUT"
  OUT="$("$ITMP/bin/claude-standby" uninstall --yes 2>&1)"; URC=$?
  t_eq "cli: uninstall refuses a dirty dev checkout" "1" "$URC"
  t_contains "cli: uninstall names the guard" "development checkout" "$OUT"
  # regression: a CLEAN, committed dev checkout must ALSO be refused — the
  # old dirty-only guard silently rm -rf'd it
  git -C "$ITMP/app" add -A 2>/dev/null
  git -C "$ITMP/app" -c user.email=t@t -c user.name=t commit -qam clean 2>/dev/null
  OUT="$("$ITMP/bin/claude-standby" uninstall --yes 2>&1)"; URC=$?
  t_eq "cli: uninstall refuses a CLEAN dev checkout" "1" "$URC"
  [ -e "$ITMP/app/bin/claude-standby" ] && ok "cli: clean dev checkout survives uninstall" \
    || fail "cli: clean dev checkout survives uninstall"
  # re-dirty, then uninstall AS the installer-managed dir → proceeds, w/ note
  echo junk2 > "$ITMP/app/JUNK2"
  OUT="$(CAR_INSTALL_DIR="$ITMP/app" CLAUDE_PLUGINS_DIR="$ITMP/noplugins" CLAUDE_SETTINGS_FILE="$ITMP/nosettings.json" \
    "$ITMP/bin/claude-standby" uninstall --yes 2>&1)"
  t_contains "cli: managed uninstall notes local changes" "local changes" "$OUT"
  t_contains "cli: uninstall reports" "Removed" "$OUT"
  # the legacy-plugin hint (D33) only appears for users who still have it
  if printf '%s' "$OUT" | grep -q "/plugin uninstall"; then
    fail "cli: no legacy-plugin hint without the plugin" "$OUT"
  else
    ok "cli: no legacy-plugin hint without the plugin"
  fi
  [ ! -e "$ITMP/app" ] && [ ! -e "$ITMP/bin/claude-standby" ] && ok "cli: uninstall removes app and link" \
    || fail "cli: uninstall removes app and link" "$(ls "$ITMP" "$ITMP/bin" 2>/dev/null)"
  # reinstall, then the installer's own --uninstall path — with a trace of
  # the old plugin present, the hint appears
  CAR_TARBALL_URL="$TARBALL" CAR_INSTALL_DIR="$ITMP/app" CAR_BIN_DIR="$ITMP/bin" bash "$ROOT/install.sh" >/dev/null 2>&1
  mkdir -p "$ITMP/plugins"
  printf '{"repositories":{"x":"claude-standby"}}\n' > "$ITMP/plugins/config.json"
  OUT="$(CAR_INSTALL_DIR="$ITMP/app" CAR_BIN_DIR="$ITMP/bin" CLAUDE_PLUGINS_DIR="$ITMP/plugins" \
    CLAUDE_SETTINGS_FILE="$ITMP/nosettings.json" bash "$ROOT/install.sh" --uninstall 2>&1)"
  t_contains "installer: uninstall reports" "Removed" "$OUT"
  t_contains "installer: legacy-plugin hint when plugin present" "/plugin uninstall" "$OUT"
  [ ! -e "$ITMP/app" ] && [ ! -e "$ITMP/bin/claude-standby" ] && ok "installer: uninstall removes app and link" \
    || fail "installer: uninstall removes app and link" "$(ls "$ITMP" "$ITMP/bin" 2>/dev/null)"
  rm -rf "$ITMP"
else
  printf 'skip - installer suite needs git and a git checkout\n'
fi

# ---------------------------------------------------------------- summary --

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
