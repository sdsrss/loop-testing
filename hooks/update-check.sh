#!/usr/bin/env bash
# update-check.sh — SessionStart hook: NOTIFY-ONLY plugin update check.
#
# Prints a one-line "update available" notice (as SessionStart additionalContext)
# when a newer git tag exists on GitHub than the installed version. It NEVER
# downloads or installs anything, NEVER blocks or slows session start (it fails fast
# and silent on any problem), and hits the network at most once per 24h (cached).
#
# This repo ships annotated git tags (no GitHub Releases), so the check queries the
# tags API and picks the highest semver. Opt out: LOOP_TESTING_DISABLE_UPDATE_CHECK=1.
#
# Test/override env: LOOP_TESTING_UPDATE_CACHE (cache dir), LOOP_TESTING_UPDATE_TTL
# (throttle seconds), LOOP_TESTING_UPDATE_TAGS_URL (fetch URL; file:// works),
# LOOP_TESTING_UPDATE_TIMEOUT (curl max-time), LOOP_TESTING_UPDATE_SELFTEST_LATEST
# (inject the latest version, skip network), LOOP_TESTING_UPDATE_FORCE=1 (bypass the
# dev-mode skip so a non-installed checkout can exercise the logic).
set -u

[ "${LOOP_TESTING_DISABLE_UPDATE_CHECK:-0}" = "1" ] && exit 0

ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$ROOT" ] || exit 0

# Dev-mode skip: only notify when installed under Claude Code's plugin-managed dirs.
# A local `--plugin-dir` dev load lives elsewhere → skip (don't nag the developer,
# whose working tree is the source of truth and can't be "updated" via the store).
case "$ROOT" in
  */plugins/marketplaces/*|*/plugins/cache/*) : ;;
  *) [ "${LOOP_TESTING_UPDATE_FORCE:-0}" = "1" ] || exit 0 ;;
esac

PJ="$ROOT/.claude-plugin/plugin.json"
[ -f "$PJ" ] || exit 0
cur=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$PJ" 2>/dev/null \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
[ -n "$cur" ] || exit 0

now=$(date +%s 2>/dev/null) || exit 0
case "$now" in ''|*[!0-9]*) exit 0 ;; esac

CACHE_DIR="${LOOP_TESTING_UPDATE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/loop-testing}"
CACHE_FILE="$CACHE_DIR/latest-tag"
TTL="${LOOP_TESTING_UPDATE_TTL:-86400}"
case "$TTL" in ''|*[!0-9]*) TTL=86400 ;; esac

latest=""
fetch_now=1
# Within the throttle window, reuse the cached value and never touch the network.
if [ -f "$CACHE_FILE" ]; then
  mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null)
  case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
  if [ "$((now - mtime))" -lt "$TTL" ]; then
    fetch_now=0
    read -r latest < "$CACHE_FILE" 2>/dev/null || latest=""
  fi
fi

if [ "$fetch_now" = 1 ]; then
  if [ -n "${LOOP_TESTING_UPDATE_SELFTEST_LATEST:-}" ]; then
    latest="$LOOP_TESTING_UPDATE_SELFTEST_LATEST"   # test injection — no network
  elif command -v curl >/dev/null 2>&1; then
    latest=$(curl -fsS --max-time "${LOOP_TESTING_UPDATE_TIMEOUT:-3}" \
      -H 'Accept: application/vnd.github+json' -H 'User-Agent: loop-testing-update-check' \
      "${LOOP_TESTING_UPDATE_TAGS_URL:-https://api.github.com/repos/sdsrss/loop-testing/tags}" 2>/dev/null \
      | grep -oE '"name"[[:space:]]*:[[:space:]]*"v?[0-9]+\.[0-9]+\.[0-9]+"' \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)
  fi
  latest=$(printf '%s' "${latest:-}" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
  # Cache the result (even an empty one) so a failed/rate-limited fetch also throttles
  # the next check — a missed notice for <=TTL is fine; slowing every session is not.
  mkdir -p "$CACHE_DIR" 2>/dev/null && printf '%s\n' "$latest" > "$CACHE_FILE" 2>/dev/null
fi

latest=$(printf '%s' "${latest:-}" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
[ -n "$latest" ] || exit 0     # offline / rate-limited / no curl / junk → silent

# Notify only when the latest tag is strictly greater than the installed version
# (never when the local checkout is ahead of the published tag).
newest=$(printf '%s\n%s\n' "$cur" "$latest" | sort -V | tail -1)
if [ "$latest" != "$cur" ] && [ "$newest" = "$latest" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"loop-testing update available: %s -> %s. Run: claude plugin update loop-testing (silence with LOOP_TESTING_DISABLE_UPDATE_CHECK=1)."}}\n' "$cur" "$latest"
fi
exit 0
