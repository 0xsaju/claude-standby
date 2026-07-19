#!/usr/bin/env bash
# install.sh — one-command installer for claude-auto-resume (D16).
#
#   curl -fsSL https://raw.githubusercontent.com/0xsaju/claude-auto-resume/main/install.sh | bash
#
# What it does (no root, no sudo):
#   1. Clones (or updates) the repo into ~/.claude-auto-resume
#   2. Symlinks the CLI into ~/.local/bin/claude-auto-resume
#
# Uninstall:
#   curl -fsSL .../install.sh | bash -s -- --uninstall
#
# Env overrides (mainly for tests): CAR_REPO_URL, CAR_TARBALL_URL,
# CAR_INSTALL_DIR, CAR_BIN_DIR, CAR_REF
set -u

REPO_URL="${CAR_REPO_URL:-https://github.com/0xsaju/claude-auto-resume.git}"
TARBALL_URL="${CAR_TARBALL_URL:-https://github.com/0xsaju/claude-auto-resume/archive/refs/heads/main.tar.gz}"
INSTALL_DIR="${CAR_INSTALL_DIR:-$HOME/.claude-auto-resume}"
BIN_DIR="${CAR_BIN_DIR:-$HOME/.local/bin}"
LINK="$BIN_DIR/claude-auto-resume"

say() { printf '%s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

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
  say "Had the old Claude Code plugin? Remove it inside a session (it no longer ships):"
  say "  /plugin uninstall claude-auto-resume@auto-resume"
  exit 0
fi

case "$(uname -s)" in
  Darwin|Linux) ;;
  MINGW*|MSYS*|CYGWIN*)
    say "note: Windows via Git Bash/WSL is best-effort for now (see README)." ;;
  *)
    say "note: untested platform '$(uname -s)' — continuing anyway." ;;
esac

if command -v git >/dev/null 2>&1; then
  if [ -d "$INSTALL_DIR/.git" ]; then
    say "Updating existing install …"
    git -C "$INSTALL_DIR" pull --ff-only >/dev/null 2>&1 || die "git pull failed in $INSTALL_DIR"
  else
    [ -e "$INSTALL_DIR" ] && die "$INSTALL_DIR exists but is not a git clone — move it aside first"
    say "Downloading claude-auto-resume …"
    # shellcheck disable=SC2086
    git clone --quiet --depth 1 ${CAR_REF:+--branch "$CAR_REF"} "$REPO_URL" "$INSTALL_DIR" 2>/dev/null \
      || die "download failed — check your network, or grab it from https://github.com/0xsaju/claude-auto-resume"
  fi
elif command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
  say "git not found — downloading tarball ..."
  rm -rf "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  curl -fsSL "$TARBALL_URL" | tar -xz -C "$INSTALL_DIR" --strip-components 1 || die "tarball download failed"
else
  die "need either git, or curl + tar"
fi

chmod +x "$INSTALL_DIR"/bin/claude-auto-resume "$INSTALL_DIR"/plugin/scripts/*.sh "$INSTALL_DIR"/test/*.sh 2>/dev/null || true
bash -n "$INSTALL_DIR/plugin/scripts/lib.sh" || die "installed scripts failed a syntax check — bad download?"

mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/bin/claude-auto-resume" "$LINK"
VER="$(head -1 "$INSTALL_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"

# "Linked" line kept for scripts/tests that look for it; kept terse.
say "Linked → $LINK"

say ""
say "  ✓  claude-auto-resume ${VER:+v$VER} is ready"
say ""
say "     Survive Claude Code usage limits: it waits for the reset and"
say "     resumes your exact conversation. Zero tokens — it even runs"
say "     while you're limited."
say ""
say "  When you hit a limit, from your project directory:"
say ""
say "     claude-auto-resume resume-at reset    resume at your 5-hour reset"
say "     claude-auto-resume resume-at auto     or: watch and resume for me"
say ""
say "  Anytime:  status  ·  doctor  ·  watch  ·  cancel  ·  help"
say ""
say "  Optional GUI — search \"Claude Auto-Resume\" in your editor's"
say "  Extensions view (VS Code Marketplace or Open VSX)."
say ""
say "  Docs:  https://github.com/0xsaju/claude-auto-resume"

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
