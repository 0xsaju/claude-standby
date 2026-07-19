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

for f in "$PLUGIN"/scripts/*.sh "$HERE"/fake-claude.sh "$HERE"/run-tests.sh "$HERE"/../bin/claude-auto-resume "$HERE"/../install.sh; do
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
export CLAUDE_AUTO_RESUME_STATE="$DTMP/state.json"
export CLAUDE_AUTO_RESUME_LOG_DIR="$DTMP/logs"
export CLAUDE_AUTO_RESUME_CLAUDE_BIN="$HERE/fake-claude.sh"
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

# auto mode: announced reset time is read from the limit message (F1)
WS10="$DTMP/ws-auto-parse"; mkdir -p "$WS10"
printf 'limit' > "$MODEFILE"
export FAKE_CLAUDE_RESET_DISPLAY="4:10pm (Asia/Dhaka)"
(cd "$WS10" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" auto >/dev/null)
bash "$PLUGIN/scripts/daemon.sh" "$WS10" &
DPID=$!
sleep 3
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
sleep 1
ar_task_set "$WS12" status cancelled
wait "$DPID" 2>/dev/null
t_eq "daemon: cancel during in-flight resume preserved" "cancelled" "$(ar_task_get "$WS12" status)"
t_contains "daemon: in-flight cancel journaled" "resume-finished" "$(ar_journal_show "$WS12" 5)"

# cancel kills the daemon (and any children) immediately, not next tick
WS13="$DTMP/ws-cancel-kills"; mkdir -p "$WS13"
(cd "$WS13" && AR_NO_DAEMON=1 bash "$PLUGIN/scripts/task-resume-at.sh" 45m >/dev/null)
AR_DAEMON_TICK_SECS=600 bash "$PLUGIN/scripts/daemon.sh" "$WS13" &
DPID=$!
sleep 1
(cd "$WS13" && bash "$PLUGIN/scripts/task-cancel.sh" >/dev/null)
sleep 1
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

unset CLAUDE_AUTO_RESUME_CLAUDE_BIN FAKE_CLAUDE_TRANSCRIPT_DIR FAKE_CLAUDE_MODE
rm -rf "$DTMP"

# ------------------------------------------------------ session selection --
# Session discovery + pinning against a fixture store in the MEASURED
# layout (HOOK-FINDINGS F2): projects/<encoded-ws>/<uuid>.jsonl

SETMP="$(mktemp -d "${TMPDIR:-/tmp}/ar-test-XXXXXX")"
SETMP="$(cd "$SETMP" && pwd)"
export CLAUDE_AUTO_RESUME_STATE="$SETMP/state.json"
export CLAUDE_AUTO_RESUME_LOG_DIR="$SETMP/logs"
export CLAUDE_PROJECTS_DIR="$SETMP/projects"
export CLAUDE_AUTO_RESUME_CLAUDE_BIN="$HERE/fake-claude.sh"
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

unset CLAUDE_AUTO_RESUME_CLAUDE_BIN CLAUDE_PROJECTS_DIR FAKE_CLAUDE_TRANSCRIPT_DIR FAKE_CLAUDE_MODE
rm -rf "$SETMP"

# -------------------------------------------------------------- cli wrapper --

CTMP="$(mktemp -d "${TMPDIR:-/tmp}/ar-test-XXXXXX")"
CTMP="$(cd "$CTMP" && pwd)"
export CLAUDE_AUTO_RESUME_STATE="$CTMP/state.json"
export CLAUDE_AUTO_RESUME_LOG_DIR="$CTMP/logs"
export AR_NOTIFY_SILENT=1
unset AR_JSON_ENGINE
. "$PLUGIN/scripts/lib.sh"
CLI="$HERE/../bin/claude-auto-resume"
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
# hook setup/removal against an isolated settings file
export CLAUDE_SETTINGS_FILE="$CTMP/settings.json"
export CLAUDE_AUTO_RESUME_PLUGIN_SCAN="$CTMP/no-plugins"
if command -v python3 >/dev/null 2>&1; then
  OUT="$(bash "$CLI" setup-hooks)"
  t_contains "hooks: fresh setup registers" "Hooks registered" "$OUT"
  t_eq "hooks: one entry per event" "2" "$(grep -c "on-stop.sh" "$CLAUDE_SETTINGS_FILE")"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CLAUDE_SETTINGS_FILE" \
    && ok "hooks: settings file valid JSON" || fail "hooks: settings file valid JSON"
  OUT="$(bash "$CLI" setup-hooks)"
  t_contains "hooks: idempotent" "already registered" "$OUT"
  t_eq "hooks: no duplicates after re-run" "2" "$(grep -c "on-stop.sh" "$CLAUDE_SETTINGS_FILE")"

  # merging preserves unrelated settings and other people's hooks
  cat > "$CTMP/settings2.json" <<'JSON'
{
  "model": "opus",
  "hooks": {
    "Stop": [ { "hooks": [ { "type": "command", "command": "echo mine" } ] } ],
    "PostToolUse": [ { "hooks": [ { "type": "command", "command": "echo other" } ] } ]
  }
}
JSON
  CLAUDE_SETTINGS_FILE="$CTMP/settings2.json" bash "$CLI" setup-hooks >/dev/null
  S2="$(cat "$CTMP/settings2.json")"
  t_contains "hooks: preserves unrelated keys" '"model": "opus"' "$S2"
  t_contains "hooks: preserves foreign Stop hook" "echo mine" "$S2"
  t_contains "hooks: preserves foreign event" "echo other" "$S2"
  t_eq "hooks: ours added alongside" "2" "$(grep -c "on-stop.sh" "$CTMP/settings2.json")"
  ls "$CTMP"/settings2.json.car-backup-* >/dev/null 2>&1 \
    && ok "hooks: backup created before edit" || fail "hooks: backup created before edit"
  CLAUDE_SETTINGS_FILE="$CTMP/settings2.json" bash "$CLI" remove-hooks >/dev/null
  S2="$(cat "$CTMP/settings2.json")"
  t_eq "hooks: removal strips only ours" "0" "$(grep -c "on-stop.sh" "$CTMP/settings2.json" || true)"
  t_contains "hooks: removal keeps foreign Stop hook" "echo mine" "$S2"
  t_contains "hooks: removal keeps unrelated keys" '"model": "opus"' "$S2"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CTMP/settings2.json" \
    && ok "hooks: file valid after removal" || fail "hooks: file valid after removal"

  # plugin conflict: refuses to double-register
  mkdir -p "$CTMP/fake-plugins/cache/claude-auto-resume"
  OUT="$(CLAUDE_SETTINGS_FILE="$CTMP/settings3.json" CLAUDE_AUTO_RESUME_PLUGIN_SCAN="$CTMP/fake-plugins" bash "$CLI" setup-hooks)"
  t_contains "hooks: plugin conflict detected" "plugin" "$OUT"
  [ ! -f "$CTMP/settings3.json" ] && ok "hooks: conflict skips registration" \
    || fail "hooks: conflict skips registration" "$(cat "$CTMP/settings3.json")"

  # doctor reports hook status (settings route, plugin route)
  t_contains "hooks: doctor shows registered" "registered in settings.json" \
    "$(CLAUDE_AUTO_RESUME_CLAUDE_BIN="$HERE/fake-claude.sh" bash "$CLI" doctor)"
  t_contains "hooks: doctor shows plugin-provided" "provided by the Claude Code plugin" \
    "$(CLAUDE_SETTINGS_FILE="$CTMP/settings3.json" CLAUDE_AUTO_RESUME_PLUGIN_SCAN="$CTMP/fake-plugins" \
       CLAUDE_AUTO_RESUME_CLAUDE_BIN="$HERE/fake-claude.sh" bash "$CLI" doctor)"
else
  printf 'skip - hook setup tests need python3\n'
fi

# version comes from the plugin manifest — read it, don't hardcode it
MANIFEST_VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HERE/../plugin/.claude-plugin/plugin.json" | head -1)"
t_contains "cli: version" "claude-auto-resume $MANIFEST_VER" "$(bash "$CLI" version)"
t_contains "cli: --version flag" "claude-auto-resume $MANIFEST_VER" "$(bash "$CLI" --version)"
DOUT="$(CLAUDE_AUTO_RESUME_CLAUDE_BIN="$HERE/fake-claude.sh" bash "$CLI" doctor)"
DRC=$?
t_eq "cli: doctor exits 0 when healthy" "0" "$DRC"
t_contains "cli: doctor reports claude" "claude" "$DOUT"
t_contains "cli: doctor reports json engine" "engine:" "$DOUT"
t_contains "cli: doctor reports daemons" "daemons" "$DOUT"
DOUT="$(CLAUDE_AUTO_RESUME_CLAUDE_BIN="/nonexistent-claude" bash "$CLI" doctor)"
DRC=$?
t_eq "cli: doctor exits 1 when claude missing" "1" "$DRC"
t_contains "cli: doctor flags missing claude" "MISS" "$DOUT"
rm -rf "$CTMP"

# --------------------------------------------------------------- installer --
# Offline: installs by cloning the local repo itself.

ROOT="$(cd "$HERE/.." && pwd)"
if command -v git >/dev/null 2>&1 && [ -d "$ROOT/.git" ]; then
  ITMP="$(mktemp -d "${TMPDIR:-/tmp}/ar-test-XXXXXX")"
  ITMP="$(cd "$ITMP" && pwd)"
  # isolate hook registration away from the real ~/.claude/settings.json
  export CLAUDE_SETTINGS_FILE="$ITMP/settings.json"
  export CLAUDE_AUTO_RESUME_PLUGIN_SCAN="$ITMP/no-plugins"
  OUT="$(CAR_REPO_URL="$ROOT" CAR_INSTALL_DIR="$ITMP/app" CAR_BIN_DIR="$ITMP/bin" bash "$ROOT/install.sh" 2>&1)"
  t_contains "installer: links the CLI" "Linked" "$OUT"
  [ -x "$ITMP/bin/claude-auto-resume" ] && ok "installer: CLI link executable" || fail "installer: CLI link executable"
  IWS="$ITMP/ws"; mkdir -p "$IWS"
  OUT="$(cd "$IWS" && CLAUDE_AUTO_RESUME_STATE="$ITMP/state.json" CLAUDE_AUTO_RESUME_LOG_DIR="$ITMP/logs" "$ITMP/bin/claude-auto-resume" status)"
  t_contains "installer: installed CLI runs through symlink" "No tracked task" "$OUT"
  OUT="$(CAR_REPO_URL="$ROOT" CAR_INSTALL_DIR="$ITMP/app" CAR_BIN_DIR="$ITMP/bin" bash "$ROOT/install.sh" 2>&1)"
  t_contains "installer: re-run updates in place" "Updating existing install" "$OUT"
  # the clone has the last committed CLI; test the working-tree CLI +
  # scripts against the installed layout (committed in the clone so
  # uninstall's dirty-checkout guard doesn't trip)
  cp "$ROOT/bin/claude-auto-resume" "$ITMP/app/bin/claude-auto-resume"
  cp "$ROOT"/plugin/scripts/*.sh "$ITMP/app/plugin/scripts/"
  git -C "$ITMP/app" add -A 2>/dev/null
  git -C "$ITMP/app" -c user.email=test@test -c user.name=test commit -qam "test cli" 2>/dev/null
  if command -v python3 >/dev/null 2>&1; then
    "$ITMP/bin/claude-auto-resume" setup-hooks >/dev/null 2>&1
    t_contains "installer: hooks registered post-install" "on-stop.sh" "$(cat "$ITMP/settings.json" 2>/dev/null)"
  fi
  OUT="$("$ITMP/bin/claude-auto-resume" uninstall --yes 2>&1)"
  if command -v python3 >/dev/null 2>&1; then
    HOOKS_LEFT="$(grep -c "on-stop.sh" "$ITMP/settings.json" 2>/dev/null || true)"
    t_eq "installer: uninstall removes hooks too" "0" "${HOOKS_LEFT:-0}"
  fi
  t_contains "cli: uninstall reports" "Removed" "$OUT"
  [ ! -e "$ITMP/app" ] && [ ! -e "$ITMP/bin/claude-auto-resume" ] && ok "cli: uninstall removes app and link" \
    || fail "cli: uninstall removes app and link" "$(ls "$ITMP" "$ITMP/bin" 2>/dev/null)"
  # reinstall, then the installer's own --uninstall path
  CAR_REPO_URL="$ROOT" CAR_INSTALL_DIR="$ITMP/app" CAR_BIN_DIR="$ITMP/bin" bash "$ROOT/install.sh" >/dev/null 2>&1
  OUT="$(CAR_INSTALL_DIR="$ITMP/app" CAR_BIN_DIR="$ITMP/bin" bash "$ROOT/install.sh" --uninstall 2>&1)"
  t_contains "installer: uninstall reports" "Removed" "$OUT"
  [ ! -e "$ITMP/app" ] && [ ! -e "$ITMP/bin/claude-auto-resume" ] && ok "installer: uninstall removes app and link" \
    || fail "installer: uninstall removes app and link" "$(ls "$ITMP" "$ITMP/bin" 2>/dev/null)"
  rm -rf "$ITMP"
else
  printf 'skip - installer suite needs git and a git checkout\n'
fi

# ---------------------------------------------------------- on-stop smoke --

STMP="$(mktemp -d "${TMPDIR:-/tmp}/ar-test-XXXXXX")"
export CLAUDE_AUTO_RESUME_STATE="$STMP/state.json"
export CLAUDE_AUTO_RESUME_LOG_DIR="$STMP/logs"
ERR="$(echo '{"session_id":"abc","transcript_path":"/nonexistent"}' | bash "$PLUGIN/scripts/on-stop.sh" Stop 2>&1 >/dev/null)"
RC=$?
t_eq "on-stop: always exits 0" "0" "$RC"
t_eq "on-stop: no stderr noise" "" "$ERR"
t_contains "on-stop: logged the event" "event=Stop" "$(cat "$STMP/logs/plugin.log" 2>/dev/null)"
t_contains "on-stop: payload captured for findings" '"session_id":"abc"' "$(cat "$STMP/logs/hook-payloads.log" 2>/dev/null)"
ERR="$(printf '' | bash "$PLUGIN/scripts/on-stop.sh" SessionEnd 2>&1 >/dev/null)"
RC=$?
t_eq "on-stop: empty payload still exits 0" "0" "$RC"
rm -rf "$STMP"

# ---------------------------------------------------------------- summary --

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
