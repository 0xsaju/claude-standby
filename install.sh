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
say() { printf '%s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

# Resolve a path (which may not exist yet) to an absolute, symlink-free form
# so overrides like CAR_INSTALL_DIR can be checked against real broad
# directories rather than a relative/symlinked alias of one (F12). Portable:
# prefers python3's realpath, else walks up to the nearest existing ancestor
# with plain cd/pwd -P and reattaches the missing tail — no GNU-only
# `realpath`/`readlink -f` required (C2).
canon_path() {
  case "$1" in
    /*) set -- "$1" ;;
    *) set -- "$PWD/$1" ;;
  esac
  if command -v python3 >/dev/null 2>&1; then
    RESOLVED="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null)"
    if [ -n "$RESOLVED" ]; then
      printf '%s\n' "$RESOLVED"
      return 0
    fi
  fi
  P="$1"; SUFFIX=""
  while [ ! -d "$P" ] && [ "$P" != "/" ]; do
    SUFFIX="/$(basename "$P")$SUFFIX"
    P="$(dirname "$P")"
  done
  if [ -d "$P" ]; then
    P="$(cd "$P" && pwd -P)"
  fi
  printf '%s%s\n' "$P" "$SUFFIX"
}

# Reject a canonicalized path that is empty, "/", $HOME itself, or another
# unmistakably-broad directory — a mistaken CAR_INSTALL_DIR must not be able
# to make `rm -rf` erase a home or system directory (F12).
reject_broad_path() {
  P="$1"; LABEL="$2"
  case "$P" in
    ""|"/") die "$LABEL resolves to '$P' — refusing to operate on it" ;;
  esac
  HOME_CANON="$(canon_path "$HOME")"
  case "$P" in
    "$HOME_CANON")
      die "$LABEL resolves to your home directory ($P) — refusing to operate on it" ;;
  esac
  case "$P" in
    "/root"|"/home"|"/Users"|"/usr"|"/usr/local"|"/etc"|"/var"|"/bin"|"/sbin"|"/opt"|"/System"|"/Library"|"$PWD")
      die "$LABEL resolves to a broad path ($P) — refusing to operate on it" ;;
  esac
}

INSTALL_DIR="$(canon_path "${CAR_INSTALL_DIR:-$HOME/.claude-standby}")"
BIN_DIR="$(canon_path "${CAR_BIN_DIR:-$HOME/.local/bin}")"
LINK="$BIN_DIR/claude-standby"
reject_broad_path "$INSTALL_DIR" "CAR_INSTALL_DIR"
reject_broad_path "$BIN_DIR" "CAR_BIN_DIR"

# Marker that stamps a directory as "ours" so a stray CAR_INSTALL_DIR
# pointed at some unrelated non-empty directory can't be wiped and replaced
# (F12). Written into staging before the atomic move, so a freshly-placed
# install always carries it; already-installed trees from before this
# sentinel existed are still recognized by their known file layout.
INSTALL_SENTINEL="$INSTALL_DIR/.claude-standby-install"
looks_like_our_install() {
  [ -f "$INSTALL_DIR/bin/claude-standby" ] && [ -f "$INSTALL_DIR/VERSION" ] \
    && [ -f "$INSTALL_DIR/plugin/scripts/lib.sh" ]
}
require_known_install_dir() {
  [ -e "$INSTALL_DIR" ] || return 0
  if [ -d "$INSTALL_DIR" ] && [ -z "$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
    return 0
  fi
  [ -e "$INSTALL_SENTINEL" ] && return 0
  looks_like_our_install && return 0
  die "$INSTALL_DIR exists and doesn't look like a claude-standby install — refusing to touch it. Point CAR_INSTALL_DIR at an empty or unused path."
}

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
# copy must pass a sanity check in staging before the old one is touched,
# and the swap itself renames the old tree aside as a backup rather than
# deleting it, so an interruption or a failed move rolls back cleanly
# instead of leaving a gap (F26).
install_tree() {
  require_known_install_dir
  STAGE="$(mktemp -d "$INSTALL_DIR.new-XXXXXX")" || die "cannot create a staging directory next to $INSTALL_DIR"
  BACKUP="$INSTALL_DIR.bak-$$"
  # Clean up staging (and an in-flight backup) on interrupt as well as on
  # early failure — not just the happy path.
  trap 'rm -rf "$STAGE" "$BACKUP" 2>/dev/null' EXIT INT TERM HUP

  if ! fetch_tree "$STAGE"; then
    rm -rf "$STAGE"
    die "download failed — check your network, or grab it from https://github.com/0xsaju/claude-standby"
  fi
  # Installs are ALWAYS plain trees (D36) — strip any .git a tarball happened to
  # carry, so the installed copy is never misread as a development git checkout
  # (which uninstall/update rightly refuse to touch).
  rm -rf "$STAGE/.git"
  # Assert the key files exist and are non-empty, so a truncated-but-parseable
  # download can't replace a working install with an incomplete tree.
  for req in bin/claude-standby VERSION plugin/scripts/lib.sh \
             plugin/scripts/daemon.sh plugin/scripts/statusline.sh \
             plugin/scripts/update-check.sh; do
    if [ ! -s "$STAGE/$req" ]; then
      rm -rf "$STAGE"
      die "downloaded copy is incomplete ($req missing) — install left untouched"
    fi
  done
  # Sanity-check every shell entry point (not just lib.sh) and, where node
  # is available, every JS entry point, so a broken download can't replace
  # a working install (F26).
  for sh in "$STAGE"/bin/claude-standby "$STAGE"/plugin/scripts"/"*.sh; do
    [ -f "$sh" ] || continue
    if ! bash -n "$sh" 2>/dev/null; then
      rm -rf "$STAGE"
      die "downloaded copy failed a sanity check ($sh) — install left untouched"
    fi
  done
  if command -v node >/dev/null 2>&1; then
    for js in "$STAGE"/vscode-extension"/"*.js; do
      [ -f "$js" ] || continue
      if ! node --check "$js" 2>/dev/null; then
        rm -rf "$STAGE"
        die "downloaded copy failed a sanity check ($js) — install left untouched"
      fi
    done
  fi
  chmod +x "$STAGE"/bin/claude-standby "$STAGE"/plugin/scripts/*.sh "$STAGE"/test/*.sh 2>/dev/null || true
  # Sentinel (F12): stamp every install we place so a later update/uninstall
  # can tell this directory is genuinely ours.
  : > "$STAGE/.claude-standby-install" 2>/dev/null || true

  if [ -e "$INSTALL_DIR" ]; then
    rm -rf "$BACKUP" 2>/dev/null
    if ! mv "$INSTALL_DIR" "$BACKUP"; then
      rm -rf "$STAGE"
      die "could not move the existing install aside — install left untouched"
    fi
  fi
  if ! mv "$STAGE" "$INSTALL_DIR"; then
    # Roll back: put the previous install back so we never leave a gap.
    rm -rf "$INSTALL_DIR" 2>/dev/null
    [ -e "$BACKUP" ] && mv "$BACKUP" "$INSTALL_DIR"
    rm -rf "$STAGE" 2>/dev/null
    die "could not place the new install — rolled back to the previous version"
  fi
  rm -rf "$BACKUP" 2>/dev/null
  trap - EXIT INT TERM HUP
}

car_installed_version() {
  head -1 "$INSTALL_DIR/VERSION" 2>/dev/null | tr -d '[:space:]'
}

# Stop every ownership-plausible daemon under $1/daemons/*.pid before the
# caller removes files out from under it (F18). Ownership check: the pid
# must be a live process whose command line actually mentions daemon.sh —
# never signal a PID that was merely reused for something unrelated.
stop_workspace_daemons() {
  DIR="$1/daemons"
  PS_BIN="${CAR_PS_BIN:-ps}"
  [ -d "$DIR" ] || return 0
  STOPPED=0; FAILED=0
  for p in "$DIR"/*.pid; do
    [ -e "$p" ] || break
    pid="$(cat "$p" 2>/dev/null | tr -dc '0-9')"
    if [ -z "$pid" ] || [ "$pid" -le 1 ] 2>/dev/null; then
      rm -f "$p"
      continue
    fi
    if kill -0 "$pid" 2>/dev/null; then
      cmd="$("$PS_BIN" -p "$pid" -o command= 2>/dev/null || "$PS_BIN" -p "$pid" -o args= 2>/dev/null)"
      case "$cmd" in
        *daemon.sh*)
          kill "$pid" 2>/dev/null
          tries=0
          while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 5 ]; do
            sleep 1
            tries=$((tries + 1))
          done
          if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null
            sleep 1
          fi
          if kill -0 "$pid" 2>/dev/null; then
            say "warning: could not stop daemon pid $pid ($(basename "$p" .pid))"
            FAILED=$((FAILED + 1))
          else
            STOPPED=$((STOPPED + 1))
          fi
          ;;
      esac
    fi
    rm -f "$p"
  done
  [ "$STOPPED" -gt 0 ] && say "Stopped $STOPPED daemon(s)."
  [ "$FAILED" -eq 0 ]
}

# --- status-line sensor offer (D41/D42) -------------------------------------
# The sensor gives exact reset times (HOOK-FINDINGS F4) but edits Claude
# Code's own settings.json, so it is OFFERED, never imposed (C4 spirit).
# CAR_SETUP_STATUSLINE=yes|no|ask (default ask; "ask" needs a terminal).
# Called with "always" on a fresh install (an explicit user action may
# re-ask) and "once" on --update: a marker file remembers that the question
# was ever asked, so updates never nag someone who already declined.
SETTINGS_FILE="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
AR_DATA="$(dirname "${CLAUDE_STANDBY_STATE:-$HOME/.claude/auto-resume/state.json}")"
SENSOR_MARKER="$AR_DATA/statusline-offered"
UPDATE_CACHE="${CLAUDE_STANDBY_UPDATE_CACHE:-$AR_DATA/update-check}"
sensor_on() { grep -qs "plugin/scripts/statusline.sh" "$SETTINGS_FILE"; }
mark_offered() { mkdir -p "$AR_DATA" 2>/dev/null && : > "$SENSOR_MARKER"; }
seed_update_cache() {
  # A successful install/update already knows this local version is the latest
  # artifact it fetched. Seed the discovery cache so the next interactive
  # `status` does not immediately make a redundant GitHub request.
  CACHE_VER="$1"
  case "$CACHE_VER" in ''|*[!0-9.]*) return 0 ;; esac
  CACHE_TMP="${UPDATE_CACHE}.tmp.$$"
  ( umask 077
    mkdir -p "$(dirname "$UPDATE_CACHE")" 2>/dev/null || exit 0
    chmod 700 "$(dirname "$UPDATE_CACHE")" 2>/dev/null || true
    printf 'checked_at=%s\nlatest_version=%s\nnotified_at=0\nnotified_version=\nresult=ok\n' \
      "$(date +%s)" "$CACHE_VER" > "$CACHE_TMP"
    chmod 600 "$CACHE_TMP" 2>/dev/null || true
    mv "$CACHE_TMP" "$UPDATE_CACHE" 2>/dev/null || rm -f "$CACHE_TMP" 2>/dev/null
    chmod 600 "$UPDATE_CACHE" 2>/dev/null || true
  ) 2>/dev/null || true
}
offer_sensor() {
  SENSOR_MODE="${CAR_SETUP_STATUSLINE:-ask}"
  [ "$SENSOR_MODE" = "no" ] && return 0
  if sensor_on; then
    # Already opted in — quietly refresh in case the path went stale (D35).
    bash "$INSTALL_DIR/plugin/scripts/setup-statusline.sh" install >/dev/null 2>&1 || true
    return 0
  fi
  if [ "$SENSOR_MODE" = "yes" ]; then
    mark_offered
    bash "$INSTALL_DIR/plugin/scripts/setup-statusline.sh" install || true
    return 0
  fi
  [ "$1" = "once" ] && [ -f "$SENSOR_MARKER" ] && return 0
  [ -r /dev/tty ] || return 0
  say ""
  say "  Optional: enable the status-line sensor? It reads the exact"
  say "  limit-reset time Claude Code already streams locally, so resumes"
  say "  fire right at your reset — no probing, zero tokens. Any status"
  say "  line you have keeps working (chained), and it's removable any"
  say "  time with: claude-standby remove-statusline"
  printf '  Enable it? [Y/n] '
  # Only honor the [Y]-on-Enter default when the read ACTUALLY succeeds (a human
  # typed a line). `[ -r /dev/tty ]` can pass in non-interactive environments
  # (CI/containers) where the read then hits EOF — treating that empty reply as
  # "yes" would edit Claude Code's settings.json without consent. So: read
  # failure / no tty -> skip silently, never install.
  if IFS= read -r SENSOR_REPLY < /dev/tty 2>/dev/null; then
    mark_offered
    case "$SENSOR_REPLY" in
      [Nn]*) ;;
      *) bash "$INSTALL_DIR/plugin/scripts/setup-statusline.sh" install || true ;;
    esac
  fi
}

if [ "${1:-}" = "--uninstall" ]; then
  if ! stop_workspace_daemons "$AR_DATA"; then
    die "a daemon is still running — retry once it stops, or kill it manually before uninstalling"
  fi
  if [ -f "$INSTALL_DIR/plugin/scripts/setup-statusline.sh" ]; then
    SENSOR_OUT="$(bash "$INSTALL_DIR/plugin/scripts/setup-statusline.sh" remove 2>&1)"
    SENSOR_RC=$?
    printf '%s\n' "$SENSOR_OUT" | grep -v "nothing to remove" || true
    if [ "$SENSOR_RC" -ne 0 ]; then
      die "could not remove the status-line sensor — aborting uninstall so settings.json isn't left referencing a deleted script"
    fi
  fi
  require_known_install_dir
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
  seed_update_cache "$NEW_VER"
  # Updates reach users the fresh installer never sees (D42): refresh a
  # registered sensor, or offer it ONE time — never nag on every update.
  offer_sensor once
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
# Link-target care (F12): never clobber something at $LINK that isn't
# already our own symlink — an unrelated real file there is a sign
# CAR_BIN_DIR points somewhere it shouldn't.
if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
  die "$LINK already exists and is not a symlink — refusing to overwrite it. Remove it manually or point CAR_BIN_DIR elsewhere."
fi
ln -sf "$INSTALL_DIR/bin/claude-standby" "$LINK"
VER="$(car_installed_version)"
seed_update_cache "$VER"

# "Linked" line kept for scripts/tests that look for it; kept terse.
say "Linked → $LINK"

offer_sensor always

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
