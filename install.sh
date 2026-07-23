#!/usr/bin/env bash
# install.sh — one-command installer for claude-standby (D16, D36).
#
#   curl -fsSL https://raw.githubusercontent.com/0xsaju/claude-standby/main/install.sh | bash
#
# What it does (no root, no sudo):
#   1. Downloads a fresh copy into ~/.claude-standby (tarball; git is
#      only a download fallback — the install is a plain tree, never a
#      git checkout, D36)
#   2. Symlinks the CLI into ~/.local/bin/claude-standby
#
# Updates use the same download-validate-swap path (`--update`, also
# reached via `claude-standby update`): the new copy is staged and
# sanity-checked before the old one is replaced, so a failed download
# never leaves a broken install.
#
# Uninstall:
#   curl -fsSL .../install.sh | bash -s -- --uninstall
#
# Env overrides (mainly for tests): CAR_REPO_URL, CAR_TARBALL_URL (URL or
# local file path), CAR_INSTALL_DIR, CAR_BIN_DIR, CAR_REF
set -u

REPO_URL="${CAR_REPO_URL:-https://github.com/0xsaju/claude-standby.git}"
# Release asset (stable "latest" URL, always the newest published release).
# This is a real uploaded asset, so GitHub reports its download_count — the
# only reliable install/update counter (branch/tag archives are uncounted).
# The asset filename stays constant across releases so this URL never changes.
TARBALL_URL="${CAR_TARBALL_URL:-https://github.com/0xsaju/claude-standby/releases/latest/download/claude-standby.tar.gz}"
INSTALL_DIR="${CAR_INSTALL_DIR:-$HOME/.claude-standby}"
BIN_DIR="${CAR_BIN_DIR:-$HOME/.local/bin}"
LINK="$BIN_DIR/claude-standby"

say() { printf '%s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

# The old plugin packaging (removed 2026-07-19, D33) lives in Claude Code's
# own plugin store — deleting our files can't remove it. True only for
# pre-removal users who still have a trace of it.
had_legacy_plugin() {
  P="${CLAUDE_PLUGINS_DIR:-$HOME/.claude/plugins}"
  grep -qs "claude-standby" "$P/config.json" 2>/dev/null && return 0
  grep -qs "claude-auto-resume@auto-resume" "${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}" 2>/dev/null && return 0
  [ -n "$(find "$P" -maxdepth 3 -name 'claude-standby*' -print 2>/dev/null | head -1)" ]
}

# Extract a fresh copy of the repo into $1 (an empty directory).
# Prefers the tarball; an explicit CAR_REPO_URL (tests, forks) or a
# machine without curl+tar uses git — as a downloader only, the .git
# directory is stripped so the install is always a plain tree.
fetch_tree() {
  DEST="$1"
  SRC="$TARBALL_URL"
  case "$SRC" in file://*) SRC="${SRC#file://}" ;; esac
  if [ -f "$SRC" ]; then
    tar -xzf "$SRC" -C "$DEST" --strip-components 1
    return $?
  fi
  if [ -n "${CAR_REPO_URL:-}" ] && [ -z "${CAR_TARBALL_URL:-}" ] \
     && command -v git >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    git clone --quiet --depth 1 ${CAR_REF:+--branch "$CAR_REF"} "$REPO_URL" "$DEST" 2>/dev/null || return 1
    rm -rf "$DEST/.git"
    return 0
  fi
  if command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
    # pipefail so a truncated curl (dies mid-stream, feeds tar a partial but
    # parseable tarball) is caught here instead of passing as tar's exit 0.
    ( set -o pipefail; curl -fsSL "$TARBALL_URL" | tar -xz -C "$DEST" --strip-components 1 )
    return $?
  fi
  if command -v git >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    git clone --quiet --depth 1 ${CAR_REF:+--branch "$CAR_REF"} "$REPO_URL" "$DEST" 2>/dev/null || return 1
    rm -rf "$DEST/.git"
    return 0
  fi
  die "need either curl + tar, or git"
}

# Download → validate → swap. Never leaves a half-updated install: the new
# copy must pass a sanity check in staging before the old one is removed.
install_tree() {
  STAGE="$(mktemp -d "$INSTALL_DIR.new-XXXXXX")" || die "cannot create a staging directory next to $INSTALL_DIR"
  if ! fetch_tree "$STAGE"; then
    rm -rf "$STAGE"
    die "download failed — check your network, or grab it from https://github.com/0xsaju/claude-standby"
  fi
  # Assert the key files exist and are non-empty, so a truncated-but-parseable
  # download can't replace a working install with an incomplete tree.
  for req in bin/claude-standby VERSION plugin/scripts/lib.sh \
             plugin/scripts/daemon.sh plugin/scripts/statusline.sh; do
    if [ ! -s "$STAGE/$req" ]; then
      rm -rf "$STAGE"
      die "downloaded copy is incomplete ($req missing) — install left untouched"
    fi
  done
  if ! bash -n "$STAGE/plugin/scripts/lib.sh" 2>/dev/null; then
    rm -rf "$STAGE"
    die "downloaded copy failed a sanity check — install left untouched"
  fi
  chmod +x "$STAGE"/bin/claude-standby "$STAGE"/plugin/scripts/*.sh "$STAGE"/test/*.sh 2>/dev/null || true
  rm -rf "$INSTALL_DIR"
  mv "$STAGE" "$INSTALL_DIR"
}

car_installed_version() {
  head -1 "$INSTALL_DIR/VERSION" 2>/dev/null | tr -d '[:space:]'
}

if [ "${1:-}" = "--uninstall" ]; then
  if [ -f "$INSTALL_DIR/plugin/scripts/setup-statusline.sh" ]; then
    bash "$INSTALL_DIR/plugin/scripts/setup-statusline.sh" remove 2>/dev/null | grep -v "nothing to remove" || true
  fi
  rm -f "$LINK"
  rm -rf "$INSTALL_DIR"
  say "Removed $INSTALL_DIR and $LINK."
  say ""
  say "Kept your runtime data (tasks, logs). To remove that too:"
  say "  rm -rf ~/.claude/auto-resume"
  if had_legacy_plugin; then
    say "You still have the old Claude Code plugin. Remove it inside a session (it no longer ships):"
    say "  /plugin uninstall claude-auto-resume@auto-resume"
  fi
  exit 0
fi

# Quiet in-place update — what `claude-standby update` runs. The CLI
# link keeps pointing at the same path, so no relink is needed.
if [ "${1:-}" = "--update" ]; then
  OLD_VER="$(car_installed_version)"
  say "Updating $INSTALL_DIR ..."
  install_tree
  NEW_VER="$(car_installed_version)"
  if [ "$NEW_VER" = "$OLD_VER" ]; then
    say "Already up to date — ${NEW_VER:-?}."
  else
    say "Updated ${OLD_VER:-?} → ${NEW_VER:-?}."
  fi
  exit 0
fi

case "$(uname -s)" in
  Darwin|Linux) ;;
  MINGW*|MSYS*|CYGWIN*)
    say "note: Windows via Git Bash/WSL is best-effort for now (see README)." ;;
  *)
    say "note: untested platform '$(uname -s)' — continuing anyway." ;;
esac

if [ -e "$INSTALL_DIR" ]; then
  say "Updating existing install …"
else
  say "Downloading claude-standby …"
fi
install_tree

mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/bin/claude-standby" "$LINK"
VER="$(car_installed_version)"

# "Linked" line kept for scripts/tests that look for it; kept terse.
say "Linked → $LINK"

# Offer the status-line SENSOR (exact reset times, HOOK-FINDINGS F4). Still
# opt-in — it edits Claude Code's own settings.json, which we never touch
# without consent (C4 spirit) — but offered here because without it the
# tool falls back to probing and the cockpit's "At reset" stays locked.
# CAR_SETUP_STATUSLINE=yes|no|ask (default ask; "ask" needs a terminal —
# a scripted install without one just gets the hint below).
SETTINGS_FILE="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
sensor_on() { grep -qs "plugin/scripts/statusline.sh" "$SETTINGS_FILE"; }
SENSOR_MODE="${CAR_SETUP_STATUSLINE:-ask}"
if [ "$SENSOR_MODE" != "no" ]; then
  if sensor_on; then
    # Already opted in — quietly refresh in case the path went stale (D35).
    bash "$INSTALL_DIR/plugin/scripts/setup-statusline.sh" install >/dev/null 2>&1 || true
  elif [ "$SENSOR_MODE" = "yes" ]; then
    bash "$INSTALL_DIR/plugin/scripts/setup-statusline.sh" install || true
  elif [ -r /dev/tty ]; then
    say ""
    say "  Optional: enable the status-line sensor? It reads the exact"
    say "  limit-reset time Claude Code already streams locally, so resumes"
    say "  fire right at your reset — no probing, zero tokens. Any status"
    say "  line you have keeps working (chained), and it's removable any"
    say "  time with: claude-standby remove-statusline"
    printf '  Enable it? [Y/n] '
    IFS= read -r SENSOR_REPLY < /dev/tty || SENSOR_REPLY=""
    case "$SENSOR_REPLY" in
      [Nn]*) ;;
      *) bash "$INSTALL_DIR/plugin/scripts/setup-statusline.sh" install || true ;;
    esac
  fi
fi

say ""
say "  ✓  claude-standby ${VER:+v$VER} is ready"
say ""
say "     Survive Claude Code usage limits: it waits for the reset and"
say "     resumes your exact conversation. Zero tokens — it even runs"
say "     while you're limited."
say ""
say "  When you hit a limit, from your project directory:"
say ""
say "     claude-standby resume-at reset    resume at your 5-hour reset"
say "     claude-standby resume-at auto     or: watch and resume for me"
say ""
say "  Anytime:  status  ·  doctor  ·  watch  ·  cancel  ·  help"
say ""
if ! sensor_on; then
  say "  Recommended:  claude-standby setup-statusline"
  say "     resume at your exact reset time (local data, zero tokens)"
  say ""
fi
say "  Optional GUI — search \"Claude Standby\" in your editor's"
say "  Extensions view (VS Code Marketplace or Open VSX)."
say ""
say "  Docs:  https://github.com/0xsaju/claude-standby"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    say ""
    say "  ⚠  $BIN_DIR is not on your PATH. Add this to your shell rc,"
    say "     then restart your shell:"
    say "       export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac
say ""
