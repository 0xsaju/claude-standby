#!/usr/bin/env bash
# setup-statusline.sh — register/remove the status-line SENSOR in
# ~/.claude/settings.json so the daemon can read the exact reset time from
# rate.json (HOOK-FINDINGS F4). Opt-in: it touches your status line, so it
# is never registered without consent — the installer and the cockpit's
# Setup screen OFFER it (D41), but only an explicit yes lands here.
#
# Usage: setup-statusline.sh install | remove | status
#
# Safety rules (settings.json edits, D20 discipline):
#   - CHAINS, never clobbers: if you already have a status line, its command
#     is saved to $AR_HOME/statusline-chain and run by our sensor with the
#     same stdin, so your display is unchanged. Registration is decided by
#     an EXACT parse of statusLine.command (resolved path, not a substring
#     match), so an unrelated command that merely mentions our path can
#     never be misclassified as ours (F28).
#   - timestamped backup before every modification; if the backup can't be
#     created, the modification is aborted rather than risking your
#     settings.json unrecoverably (F28).
#   - idempotent: installing twice does nothing
#   - requires python3 to edit JSON safely; otherwise prints manual steps
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh" || { echo "setup-statusline: cannot load lib.sh"; exit 1; }

SETTINGS="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
SENSOR="$SCRIPT_DIR/statusline.sh"
CHAIN_FILE="$AR_HOME/statusline-chain"
MODE="${1:-status}"

# Shared classifier: parses statusLine.command exactly (via python3 when
# available) and prints one of: current | stale | other | none.
#   current — points at THIS install's sensor path (byte-for-byte or
#             realpath-equal)
#   stale   — points at a DIFFERENT install's sensor (same
#             plugin/scripts/statusline.sh tail, different root) — refresh,
#             don't chain it
#   other   — a genuinely different command (never overwritten/deleted
#             without chaining it first)
#   none    — no statusLine configured
_classify_statusline() {
  [ -f "$SETTINGS" ] || { echo "none"; return; }
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$SETTINGS" "$SENSOR" <<'PY' 2>/dev/null
import json, os, sys, shlex

settings_path, sensor = sys.argv[1:3]
our_cmd = 'bash "%s"' % sensor

try:
    with open(settings_path) as fh:
        data = json.load(fh)
except Exception:
    print("none")
    sys.exit(0)

sl = data.get("statusLine")
if isinstance(sl, dict):
    cur = sl.get("command", "")
elif isinstance(sl, str):
    cur = sl
else:
    cur = ""

if not cur:
    print("none")
    sys.exit(0)


def target_path(cmd):
    if cmd.strip() == our_cmd.strip():
        return sensor
    try:
        parts = shlex.split(cmd)
    except ValueError:
        return None
    if not parts:
        return None
    prog_base = os.path.basename(parts[0])
    if prog_base in ("bash", "sh") and len(parts) >= 2:
        return parts[-1]
    if len(parts) == 1:
        return parts[0]
    return None


tgt = target_path(cur)
if tgt is None:
    print("other")
    sys.exit(0)

try:
    same_file = os.path.realpath(tgt) == os.path.realpath(sensor)
except Exception:
    same_file = tgt == sensor

if same_file:
    print("current")
    sys.exit(0)

norm = tgt.replace(os.sep, "/")
if norm == "plugin/scripts/statusline.sh" or norm.endswith("/plugin/scripts/statusline.sh"):
    print("stale")
else:
    print("other")
PY
  else
    # No python3: fall back to a conservative substring heuristic. Never
    # able to positively confirm "current" without exact parsing, so treat
    # any match as "stale" (refresh path) rather than risk misclassifying
    # a foreign command as current.
    if grep -qF "$SENSOR" "$SETTINGS" 2>/dev/null; then
      echo "stale"
    elif grep -q "plugin/scripts/statusline.sh" "$SETTINGS" 2>/dev/null; then
      echo "stale"
    else
      echo "none"
    fi
  fi
}

sensor_registered() {
  case "$(_classify_statusline)" in
    current|stale) return 0 ;;
    *) return 1 ;;
  esac
}

sensor_current() {
  [ "$(_classify_statusline)" = "current" ]
}

backup_settings() {
  # No existing file means nothing to lose — fine to proceed. If a file
  # DOES exist, the backup must succeed or the caller must abort (F28).
  if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$SETTINGS.car-backup-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || return 1
  fi
  return 0
}

edit_settings() {
  # $1: install | remove. Manages both settings.json and the chain file.
  python3 - "$SETTINGS" "$SENSOR" "$CHAIN_FILE" "$1" <<'PY'
import json, os, sys, tempfile, shlex

settings_path, sensor, chain_file, op = sys.argv[1:5]
our_cmd = 'bash "%s"' % sensor

data = {}
if os.path.exists(settings_path):
    with open(settings_path) as fh:
        data = json.load(fh)

sl = data.get("statusLine")
# statusLine is normally {type, command, ...}, but tolerate a bare string
# command form so we never drop someone's existing status line.
if isinstance(sl, dict):
    cur_cmd = sl.get("command", "")
elif isinstance(sl, str):
    cur_cmd = sl
else:
    cur_cmd = ""


def is_ours(cmd):
    # EXACT classification, mirroring _classify_statusline's "current" or
    # "stale" outcome: true only if the parsed command resolves to a
    # plugin/scripts/statusline.sh path (this install or a prior one).
    # Never a loose substring match (F28) — a command that merely mentions
    # our path (e.g. "printf plugin/scripts/statusline.sh-custom") must
    # come back False so it gets chained, not overwritten/deleted.
    if not cmd:
        return False
    if cmd.strip() == our_cmd.strip():
        return True
    try:
        parts = shlex.split(cmd)
    except ValueError:
        return False
    if not parts:
        return False
    prog_base = os.path.basename(parts[0])
    if prog_base in ("bash", "sh") and len(parts) >= 2:
        target = parts[-1]
    elif len(parts) == 1:
        target = parts[0]
    else:
        return False
    try:
        if os.path.realpath(target) == os.path.realpath(sensor):
            return True
    except Exception:
        if target == sensor:
            return True
    norm = target.replace(os.sep, "/")
    return norm == "plugin/scripts/statusline.sh" or norm.endswith("/plugin/scripts/statusline.sh")


is_ours_flag = is_ours(cur_cmd)


def write_chain(value):
    os.makedirs(os.path.dirname(chain_file) or ".", exist_ok=True)
    if value:
        with open(chain_file, "w") as fh:
            fh.write(value)
    elif os.path.exists(chain_file):
        os.remove(chain_file)


if op == "install":
    if cur_cmd != our_cmd:
        if not is_ours_flag:
            # A genuinely different, non-identical command: always chain
            # it before we overwrite (F28 — never silently drop it).
            write_chain(cur_cmd if cur_cmd else "")
        base = dict(sl) if isinstance(sl, dict) else {}
        base["type"] = "command"
        base["command"] = our_cmd
        data["statusLine"] = base
elif op == "remove":
    if is_ours_flag:
        restored = ""
        if os.path.exists(chain_file):
            with open(chain_file) as fh:
                restored = fh.read().strip()
        if restored:
            base = dict(sl) if isinstance(sl, dict) else {}
            base["command"] = restored
            data["statusLine"] = base
        elif "statusLine" in data:
            del data["statusLine"]
        write_chain("")  # drop the chain file

d = os.path.dirname(settings_path) or "."
os.makedirs(d, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings-tmp-")
with os.fdopen(fd, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
os.replace(tmp, settings_path)
PY
}

case "$MODE" in
  status)
    if sensor_registered; then
      echo "statusline sensor: registered in $SETTINGS"
      sensor_current || echo "  WARNING: points at an old install path — run setup-statusline to refresh"
      [ -f "$CHAIN_FILE" ] && echo "  chaining your previous status line"
    else
      echo "statusline sensor: not registered"
    fi
    exit 0
    ;;

  install)
    if sensor_current; then
      echo "Status-line sensor already registered in $SETTINGS."
      exit 0
    fi
    STALE=0
    if sensor_registered; then STALE=1; fi
    if ! command -v python3 >/dev/null 2>&1; then
      echo "python3 is required to edit $SETTINGS safely — not found."
      echo "Set statusLine.command to: bash \"$SENSOR\" (save your old command first)."
      exit 1
    fi
    if ! backup_settings; then
      echo "Could not back up $SETTINGS — aborting without making changes."
      exit 1
    fi
    if ! edit_settings install; then
      echo "Could not edit $SETTINGS (invalid JSON?). Fix it and retry."
      exit 1
    fi
    if [ "$STALE" -eq 1 ]; then
      ar_log "setup-statusline: refreshed stale sensor path in $SETTINGS"
      echo "Status-line sensor was pointing at an old install — path refreshed."
    else
      ar_log "setup-statusline: registered in $SETTINGS"
      echo "Status-line sensor registered — auto-detect can now use the exact"
      echo "reset time (no polling). Takes effect for new Claude Code sessions."
    fi
    [ -f "$CHAIN_FILE" ] && echo "Your existing status line is preserved (chained)."
    exit 0
    ;;

  remove)
    if ! sensor_registered; then
      echo "Status-line sensor not registered — nothing to remove."
      exit 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
      echo "python3 is required to edit $SETTINGS safely — not found."
      exit 1
    fi
    if ! backup_settings; then
      echo "Could not back up $SETTINGS — aborting without making changes."
      exit 1
    fi
    if ! edit_settings remove; then
      echo "Could not edit $SETTINGS (invalid JSON?). Fix it by hand."
      exit 1
    fi
    ar_log "setup-statusline: removed from $SETTINGS"
    echo "Status-line sensor removed from $SETTINGS (your previous status line restored)."
    exit 0
    ;;

  *)
    echo "Usage: setup-statusline.sh install | remove | status"
    exit 1
    ;;
esac
