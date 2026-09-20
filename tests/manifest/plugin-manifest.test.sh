#!/usr/bin/env bash
# plugin-manifest.test.sh — the install-time contract: manifests, hook wiring, and
# the shape Claude Code actually loads.
#
# WHY THIS EXISTS: nothing covered hooks/hooks.json or .claude-plugin/*.json, and
# the CI step that looks like it covers them does not. `claude plugin validate .`
# on this repo resolves to the MARKETPLACE manifest (both files live in
# .claude-plugin/, and the marketplace one wins), reports "contents": [] and exits
# 0 — it never reads plugin.json, the skill, or the hooks. Validating the plugin
# manifest explicitly is a separate target. These assertions are the local,
# CLI-free half of that gate: they run in the normal suite on every change.
#
# Everything here is checked against the FILES, not against a running Claude Code,
# so it stays honest without a network or a CLI install.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PJ="$REPO_ROOT/.claude-plugin/plugin.json"
MJ="$REPO_ROOT/.claude-plugin/marketplace.json"
HJ="$REPO_ROOT/hooks/hooks.json"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  ok: %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1" >&2; }
need_jq() { command -v jq >/dev/null 2>&1; }

if ! need_jq; then
  echo "plugin-manifest.test.sh: SKIP (jq not installed)"; exit 0
fi

# ── manifests parse ───────────────────────────────────────────────────────────
for f in "$PJ" "$MJ" "$HJ"; do
  if jq -e . "$f" >/dev/null 2>&1; then pass "${f##*/} is valid JSON"; else fail "${f##*/} is not valid JSON"; fi
done

# ── plugin.json identity ──────────────────────────────────────────────────────
name="$(jq -r '.name // empty' "$PJ")"
[ -n "$name" ] && pass "plugin.json has a name" || fail "plugin.json must have a name"
printf '%s' "$name" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$' \
  && pass "plugin name is kebab-case ($name)" || fail "plugin name must be kebab-case: $name"
jq -e '.description | strings | select(length > 0)' "$PJ" >/dev/null 2>&1 \
  && pass "plugin.json has a description" || fail "plugin.json must have a description"

# ── version sync (mirrors the CI gate, runnable locally) ──────────────────────
pv="$(jq -r '.version // empty' "$PJ")"
mv_meta="$(jq -r '.metadata.version // empty' "$MJ")"
mv_plugin="$(jq -r '.plugins[0].version // empty' "$MJ")"
printf '%s' "$pv" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
  && pass "plugin.json version is semver ($pv)" || fail "plugin.json version must be semver: $pv"
if [ "$pv" = "$mv_meta" ] && [ "$pv" = "$mv_plugin" ]; then
  pass "version is in sync across plugin.json + both marketplace.json fields"
else
  fail "version desync — plugin.json=$pv metadata=$mv_meta plugins[0]=$mv_plugin"
fi
[ "$(jq -r '.plugins[0].name // empty' "$MJ")" = "$name" ] \
  && pass "marketplace plugins[0].name matches plugin.json name" \
  || fail "marketplace plugins[0].name must match plugin.json name"

# ── hooks.json wiring ─────────────────────────────────────────────────────────
# The three events the README and the plugin's own description promise.
for ev in SessionStart Stop PreToolUse; do
  jq -e --arg e "$ev" '.hooks[$e] | arrays | select(length > 0)' "$HJ" >/dev/null 2>&1 \
    && pass "hooks.json declares $ev" || fail "hooks.json must declare $ev"
done

# Every hook command must go through ${CLAUDE_PLUGIN_ROOT}: a bare or relative
# path resolves against the session cwd, so it silently does nothing for any user
# whose project is not the plugin checkout.
bad_root=0; missing_script=0; checked=0
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  checked=$((checked+1))
  case "$cmd" in
    *'${CLAUDE_PLUGIN_ROOT}'*) : ;;
    *) bad_root=$((bad_root+1)); echo "    offending command: $cmd" >&2 ;;
  esac
  # resolve the referenced script against the repo root and confirm it ships
  script="$(printf '%s' "$cmd" | sed -n 's|.*\${CLAUDE_PLUGIN_ROOT}/\([^"]*\).*|\1|p')"
  if [ -n "$script" ] && [ ! -f "$REPO_ROOT/$script" ]; then
    missing_script=$((missing_script+1)); echo "    missing script: $script" >&2
  fi
done <<EOF
$(jq -r '.hooks | to_entries[] | .value[]? | .hooks[]? | .command // empty' "$HJ")
EOF
[ "$checked" -gt 0 ] && pass "hooks.json exposes $checked hook command(s)" || fail "hooks.json declares no hook commands"
[ "$bad_root" -eq 0 ] && pass "every hook command resolves via \${CLAUDE_PLUGIN_ROOT}" \
  || fail "$bad_root hook command(s) do not use \${CLAUDE_PLUGIN_ROOT}"
[ "$missing_script" -eq 0 ] && pass "every hook command points at a script that ships" \
  || fail "$missing_script hook command(s) reference a missing script"

# No absolute or parent-relative paths anywhere in the hook wiring — those break
# on every machine but the author's.
if grep -qE '"[^"]*(/home/|/Users/|/mnt/|\.\./)[^"]*"' "$HJ"; then
  fail "hooks.json contains an absolute or ../ path"
else
  pass "hooks.json has no absolute or ../ paths"
fi

# Each hook must declare a timeout: a Stop hook killed by the platform timeout is
# treated as "allow", so an unbounded gate is a gate that can silently fail open.
no_timeout="$(jq -r '[.hooks | to_entries[] | .value[]? | .hooks[]? | select(has("timeout") | not)] | length' "$HJ")"
[ "$no_timeout" = "0" ] && pass "every hook declares a timeout" \
  || fail "$no_timeout hook(s) declare no timeout"

# ── shipped components exist ──────────────────────────────────────────────────
[ -f "$REPO_ROOT/skills/loop-testing/SKILL.md" ] \
  && pass "skills/loop-testing/SKILL.md ships" || fail "skills/loop-testing/SKILL.md is missing"

echo "plugin-manifest.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
