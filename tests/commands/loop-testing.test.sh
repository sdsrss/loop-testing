#!/usr/bin/env bash
# loop-testing.test.sh — structural + parity guard for the /loop-testing slash command.
# These are PROMPT files (Claude commands/loop-testing.md + Codex prompts/loop-testing.md);
# behavior can only be fully exercised by running the agent. This test locks the pieces
# that CAN be checked statically and that drift silently: the Claude frontmatter, the
# three-mode dispatch (empty=start/resume · status · report), the two safety guards
# ("do NOT start a run" for status/report, "do NOT reset the round" on resume), skill
# reference, and Claude<->Codex parity so the two files can't diverge unnoticed.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CMD="$REPO_ROOT/commands/loop-testing.md"
PROMPT="$REPO_ROOT/prompts/loop-testing.md"

_fails=0
_name="${0##*/}"
pass() { printf '  ok: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; _fails=1; }
# whitespace-flattened substring match: markdown wraps phrases across lines, so
# collapse all runs of whitespace to a single space before matching.
has()  { if tr '[:space:]' ' ' < "$1" | tr -s ' ' | grep -qF "$2"; then pass "$3"; else fail "$3 (missing '$2' in ${1##*/})"; fi; }

# ── both files exist ───────────────────────────────────────────────────────────
[ -f "$CMD" ]    && pass "claude command file exists" || fail "commands/loop-testing.md missing"
[ -f "$PROMPT" ] && pass "codex prompt file exists"   || fail "prompts/loop-testing.md missing"

# ── Claude command: YAML frontmatter (name must match dir/file for discovery) ───
if [ "$(head -1 "$CMD")" = "---" ]; then pass "claude command opens with YAML frontmatter"
else fail "claude command must open with '---' frontmatter (line 1)"; fi
fm="$(awk 'NR>1 && /^---[[:space:]]*$/{exit} NR>1{print}' "$CMD")"
printf '%s' "$fm" | grep -qE '^name:[[:space:]]*loop-testing[[:space:]]*$' \
  && pass "frontmatter name: loop-testing" || fail "frontmatter must set name: loop-testing"
printf '%s' "$fm" | grep -qE '^description:[[:space:]]*.+' \
  && pass "frontmatter has a description" || fail "frontmatter must have a description"

# ── three-mode dispatch documented in BOTH files ───────────────────────────────
for f in "$CMD" "$PROMPT"; do
  n="${f##*/}"
  has "$f" '$ARGUMENTS'   "$n dispatches on \$ARGUMENTS"
  has "$f" 'status'       "$n documents the status mode"
  has "$f" 'report'       "$n documents the report mode"
  has "$f" 'resume'       "$n documents empty -> start/resume"
  # safety guard 1: status/report are read-only, must not kick off a run
  has "$f" 'do NOT start a run'        "$n: status/report must not start a run"
  # safety guard 2: resume must not clobber prior progress
  has "$f" 'do NOT reset the round'    "$n: resume must not reset the round count"
  # must route through the skill, not improvise the loop
  has "$f" 'loop-testing` skill'       "$n references the loop-testing skill"
done

# ── R50: guards anchored to their OWN mode block, not just present anywhere ─────
# A reordering edit that keeps every token but moves "do NOT start a run" out of
# the status/report blocks (so `status` could start a run) used to pass the
# global greps above. Extract each top-level bullet block and assert the guard
# lives INSIDE the right block.
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
for f in "$CMD" "$PROMPT"; do
  n="${f##*/}"
  block_has "$f" '^- \*\*.*status' 'do NOT start a run' "$n: no-run guard sits INSIDE the status block"
  block_has "$f" '^- \*\*.*report' 'do NOT start a run' "$n: no-run guard sits INSIDE the report block"
  block_has "$f" '^- \*\*.*(empty|start)' 'do NOT reset the round' "$n: no-reset guard sits INSIDE the start/resume block"
  block_has "$f" '^- \*\*.*(empty|start)' 'skill' "$n: skill routing sits INSIDE the start/resume block"
done

finish() {
  if [ "$_fails" -eq 0 ]; then printf '%s: PASS\n' "$_name"; exit 0
  else printf '%s: FAIL\n' "$_name"; exit 1; fi
}
finish
