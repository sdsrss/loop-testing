#!/usr/bin/env bash
# update-check.test.sh — SessionStart notify-only update check.
# Covers: notify (real curl+parse via file:// tags), up-to-date/ahead silence,
# opt-out, dev-mode skip, 24h throttle (cache reuse, no network), offline/junk
# silence. NO real network: the GitHub tags API is stubbed with file:// fixtures.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
UPDATE="$REPO_ROOT/hooks/update-check.sh"

WS=$(mktemp -d "${TMPDIR:-/tmp}/lt-upd.XXXXXX"); trap 'rm -rf "$WS"' EXIT

# an "installed" plugin root under a plugin-managed path (dev-skip does NOT fire here)
mkroot() { local root="$WS/$2/plugins/marketplaces/loop-testing"
  mkdir -p "$root/.claude-plugin"
  printf '{"name":"loop-testing","version":"%s"}\n' "$1" > "$root/.claude-plugin/plugin.json"
  echo "$root"; }
# a dev checkout root (NOT under plugins/…) — dev-skip SHOULD fire
mkroot_dev() { local root="$WS/$2/dev/loop-testing"
  mkdir -p "$root/.claude-plugin"
  printf '{"name":"loop-testing","version":"%s"}\n' "$1" > "$root/.claude-plugin/plugin.json"
  echo "$root"; }
# a GitHub /tags-shaped json (array of {"name":"vX.Y.Z"}); echoes its path
mktags() { local name="$1"; shift; local f="$WS/$name.tags.json" first=1
  { printf '['; for v in "$@"; do [ "$first" = 1 ] || printf ','; printf '{"name":"v%s"}' "$v"; first=0; done; printf ']'; } > "$f"
  echo "$f"; }

assert_has()   { if printf '%s' "$1" | grep -qF "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $3 — output lacked [$2]; got [$1]" >&2; fi; }
assert_empty() { if [ -z "$1" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $2 — expected no output, got [$1]" >&2; fi; }

# 1. Newer tag exists -> notify (exercises the real curl + grep + sort -V pipeline
#    via a file:// tags fixture; picks the highest semver, not the first listed).
r=$(mkroot 0.2.6 c1); t=$(mktags c1 0.2.5 0.3.0 0.2.6)
out=$(CLAUDE_PLUGIN_ROOT="$r" LOOP_TESTING_UPDATE_FORCE=1 LOOP_TESTING_UPDATE_CACHE="$WS/cache1" \
      LOOP_TESTING_UPDATE_TAGS_URL="file://$t" bash "$UPDATE" 2>/dev/null)
assert_has "$out" '"hookEventName":"SessionStart"' "newer tag -> emits SessionStart output"
assert_has "$out" '0.2.6 -> 0.3.0' "newer tag -> names current -> latest (highest semver)"

# 2. Latest tag == installed -> silent.
r=$(mkroot 0.2.6 c2); t=$(mktags c2 0.2.6 0.2.5)
out=$(CLAUDE_PLUGIN_ROOT="$r" LOOP_TESTING_UPDATE_FORCE=1 LOOP_TESTING_UPDATE_CACHE="$WS/cache2" \
      LOOP_TESTING_UPDATE_TAGS_URL="file://$t" bash "$UPDATE" 2>/dev/null)
assert_empty "$out" "up-to-date -> no notice"

# 3. Installed version AHEAD of the latest tag -> silent (never downgrade-nag).
r=$(mkroot 0.9.0 c3); t=$(mktags c3 0.2.6 0.3.0)
out=$(CLAUDE_PLUGIN_ROOT="$r" LOOP_TESTING_UPDATE_FORCE=1 LOOP_TESTING_UPDATE_CACHE="$WS/cache3" \
      LOOP_TESTING_UPDATE_TAGS_URL="file://$t" bash "$UPDATE" 2>/dev/null)
assert_empty "$out" "installed ahead of latest -> no notice"

# 4. Opt-out env silences even when an update exists.
r=$(mkroot 0.2.6 c4)
out=$(CLAUDE_PLUGIN_ROOT="$r" LOOP_TESTING_UPDATE_FORCE=1 LOOP_TESTING_UPDATE_CACHE="$WS/cache4" \
      LOOP_TESTING_DISABLE_UPDATE_CHECK=1 LOOP_TESTING_UPDATE_SELFTEST_LATEST=9.9.9 bash "$UPDATE" 2>/dev/null)
assert_empty "$out" "LOOP_TESTING_DISABLE_UPDATE_CHECK=1 -> no notice"

# 5. Dev-mode (root not under plugins/…) is skipped even with an update available.
r=$(mkroot_dev 0.2.6 c5)
out=$(CLAUDE_PLUGIN_ROOT="$r" LOOP_TESTING_UPDATE_CACHE="$WS/cache5" \
      LOOP_TESTING_UPDATE_SELFTEST_LATEST=9.9.9 bash "$UPDATE" 2>/dev/null)
assert_empty "$out" "dev-mode checkout (no FORCE) -> skipped, no notice"

# 6a. Throttle: first run caches the latest; a second run within TTL reuses the cache
#     and does NOT hit the network (tags URL points at a NONEXISTENT file — if it
#     fetched it would get nothing and stay silent; a notice proves the cache was used).
r=$(mkroot 0.2.6 c6); cache6="$WS/cache6"
CLAUDE_PLUGIN_ROOT="$r" LOOP_TESTING_UPDATE_FORCE=1 LOOP_TESTING_UPDATE_CACHE="$cache6" \
  LOOP_TESTING_UPDATE_TTL=99999 LOOP_TESTING_UPDATE_SELFTEST_LATEST=0.3.0 bash "$UPDATE" >/dev/null 2>&1
out=$(CLAUDE_PLUGIN_ROOT="$r" LOOP_TESTING_UPDATE_FORCE=1 LOOP_TESTING_UPDATE_CACHE="$cache6" \
      LOOP_TESTING_UPDATE_TTL=99999 LOOP_TESTING_UPDATE_TAGS_URL="file://$WS/does-not-exist.json" bash "$UPDATE" 2>/dev/null)
assert_has "$out" '0.2.6 -> 0.3.0' "within TTL -> reuses cached latest, no network"

# 6b. Throttle with an up-to-date cache -> silent, no network.
r=$(mkroot 0.2.6 c6b); cache6b="$WS/cache6b"; mkdir -p "$cache6b"; printf '0.2.6\n' > "$cache6b/latest-tag"
out=$(CLAUDE_PLUGIN_ROOT="$r" LOOP_TESTING_UPDATE_FORCE=1 LOOP_TESTING_UPDATE_CACHE="$cache6b" \
      LOOP_TESTING_UPDATE_TTL=99999 LOOP_TESTING_UPDATE_TAGS_URL="file://$WS/does-not-exist.json" bash "$UPDATE" 2>/dev/null)
assert_empty "$out" "fresh cache == installed -> no notice, no network"

# 7. Offline / junk response -> silent (curl on an empty file yields no version).
r=$(mkroot 0.2.6 c7); printf 'not json at all' > "$WS/junk.json"
out=$(CLAUDE_PLUGIN_ROOT="$r" LOOP_TESTING_UPDATE_FORCE=1 LOOP_TESTING_UPDATE_CACHE="$WS/cache7" \
      LOOP_TESTING_UPDATE_TAGS_URL="file://$WS/junk.json" bash "$UPDATE" 2>/dev/null)
assert_empty "$out" "unparseable/offline response -> no notice"

# 8. Missing CLAUDE_PLUGIN_ROOT -> silent, no crash.
out=$(LOOP_TESTING_UPDATE_FORCE=1 bash "$UPDATE" 2>/dev/null)
assert_empty "$out" "no CLAUDE_PLUGIN_ROOT -> silent"

# 9. No curl on PATH -> silent exit 0 (the previously-untested no-curl branch).
#    PATH is a symlink farm of the real bins minus curl.
r=$(mkroot 0.2.6 c8); BINF="$WS/nobin"; mkdir -p "$BINF"
for p in /bin/* /usr/bin/*; do [ -x "$p" ] && ln -sf "$p" "$BINF/${p##*/}" 2>/dev/null; done
rm -f "$BINF/curl"
out=$(CLAUDE_PLUGIN_ROOT="$r" LOOP_TESTING_UPDATE_FORCE=1 LOOP_TESTING_UPDATE_CACHE="$WS/cache8" \
      PATH="$BINF" bash "$UPDATE" 2>/dev/null); rc=$?
assert_empty "$out" "no curl on PATH -> silent"
if [ "$rc" -eq 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: no-curl branch must exit 0, got $rc" >&2; fi

report "update-check.test.sh"
