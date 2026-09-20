#!/usr/bin/env bash
# loop-testing.test.sh — structural + parity guard for the /loop-testing entry point.
#
# These are PROMPT files (Claude skills/loop-testing/SKILL.md + Codex
# prompts/loop-testing.md); behavior can only be fully exercised by running the
# agent. This test locks the pieces that CAN be checked statically and that drift
# silently: the Claude frontmatter, the three-mode dispatch (empty=start/resume ·
# status · report), the two safety guards ("don't start a run" for status/report,
# "don't reset the round" on resume), and Claude<->Codex parity so the two files
# can't diverge unnoticed.
#
# WHY THE DISPATCH LIVES IN SKILL.md: it used to live in commands/loop-testing.md.
# Claude Code registers commands/*.md as flat SKILLS, in the same namespace as
# skills/*/SKILL.md — so `commands/loop-testing.md` (frontmatter name:
# loop-testing) and `skills/loop-testing/` BOTH claimed the name `loop-testing`,
# the commands/ copy won, and SKILL.md became unreachable through the slash
# command AND the trigger phrases. The command's own body said "invoke the
# `loop-testing` skill", which resolved back to itself. The two files are now one.
# `component_names_unique` below is the regression guard for the collision itself.
#
# The two files are deliberately written in DIFFERENT languages (SKILL.md is the
# Chinese product voice, the Codex prompt is English), so parity is asserted over
# the semantic elements each must carry, in its own spelling — not over identical
# English strings.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$REPO_ROOT/skills/loop-testing/SKILL.md"
PROMPT="$REPO_ROOT/prompts/loop-testing.md"

_fails=0
_name="${0##*/}"
pass() { printf '  ok: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; _fails=1; }
# whitespace-flattened substring match: markdown wraps phrases across lines, so
# collapse all runs of whitespace to a single space before matching.
has()  { if tr '[:space:]' ' ' < "$1" | tr -s ' ' | grep -qF "$2"; then pass "$3"; else fail "$3 (missing '$2' in ${1##*/})"; fi; }

# ── both files exist ───────────────────────────────────────────────────────────
[ -f "$SKILL" ]  && pass "claude skill file exists"  || fail "skills/loop-testing/SKILL.md missing"
[ -f "$PROMPT" ] && pass "codex prompt file exists"  || fail "prompts/loop-testing.md missing"

# ── the collision must not come back ──────────────────────────────────────────
# Every component Claude Code registers as a skill: skills/*/SKILL.md (name from
# the directory) and commands/*.md (name from the file). Two sharing a name means
# one silently shadows the other — the exact defect this file documents above.
component_names_unique() {
  local names="" n dup
  for d in "$REPO_ROOT"/skills/*/; do
    [ -f "$d/SKILL.md" ] || continue
    n="$(basename "$d")"; names="$names$n\n"
  done
  for f in "$REPO_ROOT"/commands/*.md; do
    [ -f "$f" ] || continue
    n="$(basename "$f" .md)"; names="$names$n\n"
  done
  dup="$(printf "$names" | sort | uniq -d)"
  if [ -n "$dup" ]; then
    fail "two plugin components register the same skill name: $dup — one will shadow the other"
  else
    pass "no two plugin components share a skill name"
  fi
}
component_names_unique

# the file that lost the collision must stay gone
if [ -e "$REPO_ROOT/commands/loop-testing.md" ]; then
  fail "commands/loop-testing.md is back — it re-collides with skills/loop-testing/"
else
  pass "commands/loop-testing.md stays removed (its dispatch lives in SKILL.md)"
fi

# ── Claude skill: YAML frontmatter (name must match the dir for discovery) ─────
if [ "$(head -1 "$SKILL")" = "---" ]; then pass "claude skill opens with YAML frontmatter"
else fail "claude skill must open with '---' frontmatter (line 1)"; fi
fm="$(awk 'NR>1 && /^---[[:space:]]*$/{exit} NR>1{print}' "$SKILL")"
printf '%s' "$fm" | grep -qE '^name:[[:space:]]*loop-testing[[:space:]]*$' \
  && pass "frontmatter name: loop-testing" || fail "frontmatter must set name: loop-testing"
printf '%s' "$fm" | grep -qE '^description:[[:space:]]*.+' \
  && pass "frontmatter has a description" || fail "frontmatter must have a description"

# ── three-mode dispatch present in BOTH files ─────────────────────────────────
for f in "$SKILL" "$PROMPT"; do
  n="${f##*/}"
  has "$f" '$ARGUMENTS' "$n dispatches on \$ARGUMENTS"
  has "$f" 'status'     "$n documents the status mode"
  has "$f" 'report'     "$n documents the report mode"
done
# resume / no-run / no-reset guards, each in the file's own language
has "$PROMPT" 'resume'                "prompt documents empty -> start/resume"
has "$PROMPT" 'do NOT start a run'    "prompt: status/report must not start a run"
has "$PROMPT" 'do NOT reset the round' "prompt: resume must not reset the round count"
has "$PROMPT" 'loop-testing` skill'   "prompt routes through the loop-testing skill"
has "$SKILL"  '续跑'                   "SKILL documents empty -> start/resume"
has "$SKILL"  '禁止开跑'                "SKILL: status/report must not start a run"
has "$SKILL"  '禁止重置轮数'             "SKILL: resume must not reset the round count"

# ── guards anchored to their OWN mode block, not just present anywhere (R50) ────
# A reordering edit that keeps every token but moves the no-run guard out of the
# status/report blocks (so `status` could start a run) used to pass the global
# greps above. Extract each top-level bullet block and assert the guard lives
# INSIDE the right block.
block() { # file start-regex -> the bullet block from the matching '- ' line to the next '- '
  awk -v s="$2" '
    !inb && $0 ~ s { inb=1; print; next }
    inb && /^- /   { exit }
    inb            { print }
  ' "$1"
}
block_has() { # file start-regex needle label
  if block "$1" "$2" | tr '[:space:]' ' ' | tr -s ' ' | grep -qF "$3"; then pass "$4"
  else fail "$4 (block '$2' in ${1##*/} lacks '$3')"; fi
}
block_has "$PROMPT" '^- \*\*.*status' 'do NOT start a run' "prompt: no-run guard sits INSIDE the status block"
block_has "$PROMPT" '^- \*\*.*report' 'do NOT start a run' "prompt: no-run guard sits INSIDE the report block"
block_has "$PROMPT" '^- \*\*.*(empty|start)' 'do NOT reset the round' "prompt: no-reset guard sits INSIDE the start/resume block"
block_has "$PROMPT" '^- \*\*.*(empty|start)' 'skill' "prompt: skill routing sits INSIDE the start/resume block"
block_has "$PROMPT" '^- \*\*.*(empty|start)' 'start from round 0' "prompt: default (empty arg) still starts a full loop from round 0"
block_has "$SKILL" '^- \*\*.*`status`' '禁止开跑' "SKILL: no-run guard sits INSIDE the status block"
block_has "$SKILL" '^- \*\*.*`report`' '禁止开跑' "SKILL: no-run guard sits INSIDE the report block"
block_has "$SKILL" '^- \*\*.*空参数' '禁止重置轮数' "SKILL: no-reset guard sits INSIDE the start/resume block"
block_has "$SKILL" '^- \*\*.*空参数' '第 0 轮开始' "SKILL: default (empty arg) still starts a full loop from round 0"

# ── optional scope hints: focus + round cap (additive; must not change default) ──
for f in "$SKILL" "$PROMPT"; do
  n="${f##*/}"
  has "$f" 'focus'         "$n documents the optional focus/scope hint"
  has "$f" '最多 3 轮'      "$n gives the round-cap usage example"
  has "$f" 'max_rounds: N' "$n round-cap hint writes max_rounds into STATE.md"
done

finish() {
  if [ "$_fails" -eq 0 ]; then printf '%s: PASS\n' "$_name"; exit 0
  else printf '%s: FAIL\n' "$_name"; exit 1; fi
}
finish
