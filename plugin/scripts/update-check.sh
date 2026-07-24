#!/usr/bin/env bash
# update-check.sh — best-effort release discovery for human-facing CLI commands.
#
# Modes:
#   auto    cached, quiet-on-failure notice for interactive `status`
#   doctor  cached health row for interactive `doctor`
#   force   fresh, user-requested `update --check` with actionable errors
#   seed    mark the installed version current after install/update
#
# This helper is NEVER called by the daemon or status-line sensor. It discovers
# releases only; installing remains an explicit `claude-standby update`.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh" || exit 0

MODE="${1:-auto}"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANAGED_DIR="${CAR_INSTALL_DIR:-$HOME/.claude-standby}"
CACHE_FILE="${CLAUDE_STANDBY_UPDATE_CACHE:-$AR_HOME/update-check}"
RELEASE_API="${CAR_UPDATE_API_URL:-https://api.github.com/repos/0xsaju/claude-standby/releases/latest}"
CURL_BIN="${CAR_UPDATE_CURL_BIN:-curl}"
INTERVAL="${CAR_UPDATE_CHECK_INTERVAL_SECS:-86400}"
INTERVAL="$(ar_uint "$INTERVAL" 86400 2592000)"
[ "$INTERVAL" -gt 0 ] || INTERVAL=86400

installed_version() {
  head -1 "$ROOT/VERSION" 2>/dev/null | tr -d '[:space:]'
}

normalize_version() {
  local v="${1#v}" major rest minor patch
  case "$v" in
    ''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
  esac
  major="${v%%.*}"
  rest="${v#*.}"
  [ "$rest" != "$v" ] || return 1
  minor="${rest%%.*}"
  patch="${rest#*.}"
  [ "$patch" != "$rest" ] || return 1
  case "$patch" in *.*|'') return 1 ;; esac
  [ "${#major}" -le 6 ] && [ "${#minor}" -le 6 ] && [ "${#patch}" -le 6 ] || return 1
  printf '%s.%s.%s\n' "$((10#$major))" "$((10#$minor))" "$((10#$patch))"
}

safe_timestamp() {
  local v="$1"
  # Epoch seconds through year 2100 fit in 10 digits. Bounding length before
  # arithmetic prevents a hand-edited cache from overflowing or tripping over
  # octal-looking values such as 0000000008.
  case "$v" in ''|*[!0-9]*|???????????*) echo 0; return ;; esac
  echo "$((10#$v))"
}

version_compare() {
  # Print 1 when $1 is newer, -1 when older, 0 when equal.
  local a b am an ap bm bn bp
  a="$(normalize_version "$1")" || return 1
  b="$(normalize_version "$2")" || return 1
  am="${a%%.*}"; a="${a#*.}"; an="${a%%.*}"; ap="${a#*.}"
  bm="${b%%.*}"; b="${b#*.}"; bn="${b%%.*}"; bp="${b#*.}"
  if [ "$am" -ne "$bm" ]; then [ "$am" -gt "$bm" ] && echo 1 || echo -1; return 0; fi
  if [ "$an" -ne "$bn" ]; then [ "$an" -gt "$bn" ] && echo 1 || echo -1; return 0; fi
  if [ "$ap" -ne "$bp" ]; then [ "$ap" -gt "$bp" ] && echo 1 || echo -1; return 0; fi
  echo 0
}

cache_get() {
  [ -f "$CACHE_FILE" ] || return 0
  awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1); exit }' \
    "$CACHE_FILE" 2>/dev/null
}

write_cache() {
  # Fixed, validated key/value data; never sourced as shell.
  local checked="$1" latest="$2" notified_at="$3" notified_version="$4" result="$5"
  local tmp="${CACHE_FILE}.tmp.$$"
  case "$checked" in ''|*[!0-9]*) checked=0 ;; esac
  case "$notified_at" in ''|*[!0-9]*) notified_at=0 ;; esac
  latest="$(normalize_version "$latest" 2>/dev/null || true)"
  notified_version="$(normalize_version "$notified_version" 2>/dev/null || true)"
  case "$result" in ok|error) ;; *) result=error ;; esac
  ar__ensure_private_dir "$(dirname "$CACHE_FILE")" || return 0
  if ( umask 077
       printf 'checked_at=%s\nlatest_version=%s\nnotified_at=%s\nnotified_version=%s\nresult=%s\n' \
         "$checked" "$latest" "$notified_at" "$notified_version" "$result" > "$tmp"
     ) 2>/dev/null; then
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$CACHE_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    chmod 600 "$CACHE_FILE" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null
  fi
}

doctor_row() {
  printf '  %-8s %-5s %s\n' "update" "$1" "$2"
}

case "$MODE" in
  auto|doctor|force|seed) ;;
  *) echo "update-check: unknown mode '$MODE'" >&2; exit 1 ;;
esac

INSTALLED="$(normalize_version "$(installed_version)")" || {
  [ "$MODE" = "force" ] && echo "Could not read the installed claude-standby version." >&2
  [ "$MODE" = "doctor" ] && doctor_row "BAD" "installed version is unreadable"
  [ "$MODE" = "force" ] && exit 1
  exit 0
}

if [ "$MODE" = "seed" ]; then
  write_cache "$(date +%s)" "$INSTALLED" 0 "" ok
  exit 0
fi

# Managed installs are updated by the release asset. A source checkout belongs
# to git, so automatic notices must not point developers at a command that will
# intentionally refuse to run.
if [ -d "$ROOT/.git" ] && [ "$ROOT" != "$MANAGED_DIR" ] \
   && [ "${CAR_UPDATE_ALLOW_DEV:-0}" != "1" ]; then
  if [ "$MODE" = "force" ]; then
    echo "This is a development checkout — check/update it with git:"
    echo "  git -C \"$ROOT\" pull"
    exit 1
  fi
  [ "$MODE" = "doctor" ] && doctor_row "--" "development checkout — use git"
  exit 0
fi

# Automatic checks are for people looking at a terminal. Preserve stable output
# for scripts, command substitutions, and pipes. Tests can opt into the exact
# interactive path without depending on a platform-specific pseudo-TTY tool.
if [ "$MODE" != "force" ] && [ "${CAR_UPDATE_CHECK_INTERACTIVE:-0}" != "1" ] \
   && [ ! -t 1 ]; then
  exit 0
fi

ENABLED="${CLAUDE_STANDBY_UPDATE_CHECK:-${AR_CFG_UPDATE_CHECK:-1}}"
case "$ENABLED" in
  0|false|FALSE|no|NO|off|OFF)
    if [ "$MODE" != "force" ]; then
      [ "$MODE" = "doctor" ] && doctor_row "OFF" "automatic checks disabled"
      exit 0
    fi
    ;;
esac

NOW="$(date +%s)"
CHECKED="$(cache_get checked_at)"
LATEST="$(cache_get latest_version)"
NOTIFIED_AT="$(cache_get notified_at)"
NOTIFIED_VERSION="$(cache_get notified_version)"
RESULT="$(cache_get result)"
CHECKED="$(safe_timestamp "$CHECKED")"
NOTIFIED_AT="$(safe_timestamp "$NOTIFIED_AT")"
LATEST="$(normalize_version "$LATEST" 2>/dev/null || true)"
NOTIFIED_VERSION="$(normalize_version "$NOTIFIED_VERSION" 2>/dev/null || true)"
case "$RESULT" in ok|error) ;; *) RESULT=error ;; esac

REFRESH=0
[ "$MODE" = "force" ] && REFRESH=1
[ $((NOW - CHECKED)) -ge "$INTERVAL" ] 2>/dev/null && REFRESH=1
[ "$CHECKED" -gt "$NOW" ] 2>/dev/null && REFRESH=1

if [ "$REFRESH" -eq 1 ]; then
  if ! command -v "$CURL_BIN" >/dev/null 2>&1; then
    RESULT=error
    CHECKED="$NOW"
    write_cache "$CHECKED" "$LATEST" "$NOTIFIED_AT" "$NOTIFIED_VERSION" "$RESULT"
    if [ "$MODE" = "force" ]; then
      echo "Could not check for updates: curl is not installed." >&2
      exit 1
    fi
  else
    BODY="$("$CURL_BIN" -fsS --connect-timeout 1 --max-time 2 \
      -H 'Accept: application/vnd.github+json' \
      -H 'User-Agent: claude-standby-cli' "$RELEASE_API" 2>/dev/null)"
    CURL_RC=$?
    TAG=""
    if [ "$CURL_RC" -eq 0 ]; then
      TAG="$(printf '%s' "$BODY" | tr '\n' ' ' | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      TAG="$(normalize_version "$TAG" 2>/dev/null || true)"
    fi
    CHECKED="$NOW"
    if [ -n "$TAG" ]; then
      LATEST="$TAG"
      RESULT=ok
    else
      RESULT=error
    fi
    write_cache "$CHECKED" "$LATEST" "$NOTIFIED_AT" "$NOTIFIED_VERSION" "$RESULT"
    if [ "$MODE" = "force" ] && [ "$RESULT" != "ok" ]; then
      echo "Could not check for updates (offline, GitHub unavailable, or invalid release response)." >&2
      exit 1
    fi
  fi
fi

CMP=0
[ -n "$LATEST" ] && CMP="$(version_compare "$LATEST" "$INSTALLED" 2>/dev/null || echo 0)"

case "$MODE" in
  force)
    if [ "$CMP" -gt 0 ]; then
      echo "Update available: $LATEST (installed: $INSTALLED). Run: claude-standby update"
    else
      echo "Already up to date — $INSTALLED."
    fi
    ;;
  auto)
    # Never turn an offline/failed check into noise. A successful forced check
    # may have filled the cache without notifying, so a later status can still
    # surface it once.
    if [ "$RESULT" = "ok" ] && [ "$CMP" -gt 0 ]; then
      if [ "$NOTIFIED_VERSION" != "$LATEST" ] \
         || [ $((NOW - NOTIFIED_AT)) -ge "$INTERVAL" ] 2>/dev/null; then
        echo ""
        echo "Update available: $LATEST (installed: $INSTALLED). Run: claude-standby update"
        NOTIFIED_AT="$NOW"
        NOTIFIED_VERSION="$LATEST"
        write_cache "$CHECKED" "$LATEST" "$NOTIFIED_AT" "$NOTIFIED_VERSION" "$RESULT"
      fi
    fi
    ;;
  doctor)
    if [ "$CMP" -gt 0 ]; then
      if [ "$RESULT" = "ok" ]; then
        doctor_row "NEW" "$LATEST available (installed: $INSTALLED) — run: claude-standby update"
      else
        doctor_row "NEW" "$LATEST available (cached; latest check unavailable)"
      fi
    elif [ "$RESULT" = "ok" ]; then
      doctor_row "ok" "$INSTALLED is current"
    else
      doctor_row "--" "check unavailable (offline, GitHub unavailable, or curl missing)"
    fi
    ;;
esac

exit 0
