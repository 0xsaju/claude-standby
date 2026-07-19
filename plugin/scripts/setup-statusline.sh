#!/usr/bin/env bash
# setup-statusline.sh — register/remove the status-line SENSOR in
# ~/.claude/settings.json so the daemon can read the exact reset time from
# rate.json (HOOK-FINDINGS F4). Opt-in: it touches your status line, so it is
# never auto-registered on install.
#
# Usage: setup-statusline.sh install | remove | status
#
# Safety rules (settings.json edits, D20 discipline):
#   - CHAINS, never clobbers: if you already have a status line, its command
#     is saved to $AR_HOME/statusline-chain and run by our sensor with the
#     same stdin, so your display is unchanged.
#   - timestamped backup before every modification
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

sensor_registered() {
  [ -f "$SETTINGS" ] && grep -q "statusline.sh" "$SETTINGS" 2>/dev/null
}

backup_settings() {
  [ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.car-backup-$(date +%Y%m%d-%H%M%S)"
  return 0
}

edit_settings() {
  # $1: install | remove. Manages both settings.json and the chain file.
  python3 - "$SETTINGS" "$SENSOR" "$CHAIN_FILE" "$1" <<'PY'
import json, os, sys, tempfile

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
is_ours = "statusline.sh" in str(cur_cmd)

def write_chain(value):
    os.makedirs(os.path.dirname(chain_file) or ".", exist_ok=True)
    if value:
        with open(chain_file, "w") as fh:
            fh.write(value)
    elif os.path.exists(chain_file):
        os.remove(chain_file)

if op == "install":
    if not is_ours:
        # Preserve any existing status line by chaining it.
        write_chain(cur_cmd if cur_cmd else "")
        base = dict(sl) if isinstance(sl, dict) else {}
        base["type"] = "command"
        base["command"] = our_cmd
        data["statusLine"] = base
elif op == "remove":
    if is_ours:
        restored = ""
        if os.path.exists(chain_file):
            with open(chain_file) as fh:
                restored = fh.read().strip()
        if restored:
            base = dict(sl)
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
      [ -f "$CHAIN_FILE" ] && echo "  chaining your previous status line"
    else
      echo "statusline sensor: not registered"
    fi
    exit 0
    ;;

  install)
    if sensor_registered; then
      echo "Status-line sensor already registered in $SETTINGS."
      exit 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
      echo "python3 is required to edit $SETTINGS safely — not found."
      echo "Set statusLine.command to: bash \"$SENSOR\" (save your old command first)."
      exit 1
    fi
    backup_settings
    if ! edit_settings install; then
      echo "Could not edit $SETTINGS (invalid JSON?). Fix it and retry."
      exit 1
    fi
    ar_log "setup-statusline: registered in $SETTINGS"
    echo "Status-line sensor registered — auto-detect can now use the exact"
    echo "reset time (no polling). Takes effect for new Claude Code sessions."
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
    backup_settings
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
