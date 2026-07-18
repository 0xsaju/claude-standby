#!/usr/bin/env bash
# lib.sh — claude-auto-resume core helpers: state.json access, logging,
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

AR_STATE_FILE="${CLAUDE_AUTO_RESUME_STATE:-$HOME/.claude/auto-resume/state.json}"
AR_HOME="$(dirname "$AR_STATE_FILE")"
AR_LOG_DIR="${CLAUDE_AUTO_RESUME_LOG_DIR:-$AR_HOME/logs}"

# Optional user config (shell syntax, AR_CFG_* variables only — see
# docs/USER-GUIDE.md). Environment variables always win over config values
# because consumers read ${CLAUDE_AUTO_RESUME_X:-${AR_CFG_X:-default}}.
AR_CONFIG_FILE="${CLAUDE_AUTO_RESUME_CONFIG:-$AR_HOME/config}"
if [ -f "$AR_CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$AR_CONFIG_FILE" 2>/dev/null || true
fi

# Task fields stored as JSON numbers, not strings.
AR_NUMERIC_FIELDS=" resume_count max_resumes "

AR_DEFAULT_RESUME_PROMPT="Limit reset. Continue from where you stopped. Check PROGRESS.md first."

# Substring that identifies a limit message. MEASURED — cite:
# docs/HOOK-FINDINGS.md F1 ("You've hit your session limit · resets ...").
AR_LIMIT_PATTERN="hit your session limit"

# ------------------------------------------------------------ timestamps --

ar_now_iso() {
  # ISO-8601 with numeric timezone, no colon (round-trips through %z parsers)
  date '+%Y-%m-%dT%H:%M:%S%z'
}

ar_iso_to_epoch() {
  # $1: ISO-8601 like 2026-07-18T13:00:00+0600 (tolerates +06:00 too)
  local iso="$1" norm
  norm="$(printf '%s' "$iso" | sed 's/\([+-][0-9][0-9]\):\([0-9][0-9]\)$/\1\2/')"
  date -j -f '%Y-%m-%dT%H:%M:%S%z' "$norm" '+%s' 2>/dev/null && return 0  # BSD
  date -d "$iso" '+%s' 2>/dev/null && return 0                            # GNU
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,datetime; print(int(datetime.datetime.fromisoformat(sys.argv[1]).timestamp()))' \
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

# --------------------------------------------------------------- logging --

ar_log() {
  mkdir -p "$AR_LOG_DIR" 2>/dev/null || return 0
  printf '%s %s\n' "$(ar_now_iso)" "$*" >> "$AR_LOG_DIR/plugin.log" 2>/dev/null || true
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
  # $1 -> JSON string contents (no surrounding quotes)
  printf '%s' "$1" | awk '
    BEGIN { ORS = ""; first = 1 }
    {
      if (!first) printf "\\n"
      first = 0
      s = $0
      gsub(/\\/, "\\\\", s)
      gsub(/"/, "\\\"", s)
      gsub(/\t/, "\\t", s)
      gsub(/\r/, "\\r", s)
      printf "%s", s
    }'
}

ar_json_unescape() {
  # Best-effort inverse for the text tier (see DECISIONS D2 caveat).
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) printf "\n"
      s = $0
      gsub(/\\n/, "\n", s)
      gsub(/\\t/, "\t", s)
      gsub(/\\r/, "\r", s)
      gsub(/\\"/, "\"", s)
      gsub(/\\\\/, "\\", s)
      printf "%s", s
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

ar_state_write() {
  # stdin -> state file, atomically (temp file in same dir + mv).
  # Refuses to clobber state with empty content.
  mkdir -p "$(dirname "$AR_STATE_FILE")" 2>/dev/null
  local tmp="$AR_STATE_FILE.tmp.$$"
  if cat > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$AR_STATE_FILE"
  else
    rm -f "$tmp" 2>/dev/null
    ar_log "ERROR: state write failed (empty content or unwritable dir)"
    return 1
  fi
}

ar_state_init() {
  [ -f "$AR_STATE_FILE" ] && return 0
  ar_state_write <<'EOF'
{
  "version": 2,
  "tasks": {},
  "commands": []
}
EOF
}

# ------------------------------------------------------- state: jq engine --

ar__jq_upsert() {
  local ws="$1"; shift
  local prog='.tasks[$ws] = (.tasks[$ws] // {
    "session_id": "",
    "status": "running",
    "importance": "normal",
    "original_prompt": "",
    "resume_at": "",
    "resume_mode": "at",
    "resume_count": 0,
    "max_resumes": 3,
    "resume_prompt_template": $defprompt,
    "last_output_tail": "",
    "progress_file": "PROGRESS.md",
    "journal": []
  })'
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
    "max_resumes": 3, "resume_prompt_template": defprompt,
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
    ws, ts, event, detail = rest
    t = tasks.setdefault(ws, dict(DEFAULTS))
    t.setdefault("journal", []).append({"ts": ts, "event": event, "detail": detail})
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
  # stdin: state content; $1: ws, $2: field, $3: rendered JSON value
  AR_K="    \"$(ar_json_escape "$1")\": {" AR_F="$2" AR_V="$3" awk '
    BEGIN { key = ENVIRON["AR_K"]; f = ENVIRON["AR_F"]; nv = ENVIRON["AR_V"] }
    intask && !injournal && index($0, "      \"" f "\":") == 1 {
      comma = ($0 ~ /,$/) ? "," : ""
      print "      \"" f "\": " nv comma
      intask = 0
      next
    }
    intask && index($0, "      \"journal\":") == 1 { injournal = 1 }
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

ar__text_journal_append() {
  # $1: ws, $2: ts, $3: event, $4: detail -> new content on stdout
  local ws="$1" entry
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
  '
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
  # defaults if missing, then applies the pairs. Atomic write.
  local ws="$1"; shift
  ar_state_init || return 1
  local eng new
  eng="$(ar_json_engine)"
  case "$eng" in
    jq) new="$(ar__jq_upsert "$ws" "$@")" ;;
    python3) new="$(ar__py upsert "$ws" "$@")" ;;
    *) new="$(ar__text_upsert "$ws" "$@")" ;;
  esac
  if [ -z "$new" ]; then
    ar_log "ERROR: task upsert produced no output (engine=$eng ws=$ws)"
    return 1
  fi
  printf '%s\n' "$new" | ar_state_write
}

ar_task_set() {
  # $1: workspace, $2: field, $3: value
  ar_task_upsert "$1" "$2=$3"
}

ar_journal_append() {
  # $1: workspace, $2: event, $3: detail
  local ws="$1" event="$2" detail="${3:-}" ts eng new
  ts="$(ar_now_iso)"
  ar_state_init || return 1
  eng="$(ar_json_engine)"
  case "$eng" in
    jq)
      new="$(jq --arg ws "$ws" --arg ts "$ts" --arg e "$event" --arg d "$detail" \
        '(.tasks[$ws].journal) |= ((. // []) + [{"ts": $ts, "event": $e, "detail": $d}])' \
        "$AR_STATE_FILE" 2>/dev/null)"
      ;;
    python3) new="$(ar__py journal "$ws" "$ts" "$event" "$detail")" ;;
    *) new="$(ar__text_journal_append "$ws" "$ts" "$event" "$detail")" ;;
  esac
  if [ -z "$new" ]; then
    ar_log "ERROR: journal append produced no output (engine=$eng ws=$ws)"
    return 1
  fi
  printf '%s\n' "$new" | ar_state_write
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

ar_daemon_pidfile() {
  # $1: workspace -> the pidfile path its daemon uses (D11)
  printf '%s/daemons/%s.pid\n' "$AR_HOME" "$(printf '%s' "$1" | cksum | awk '{print $1}')"
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
