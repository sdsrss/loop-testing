#!/usr/bin/env bash
# prompt.test.sh: the /loop-testing slash-command prompt is installed to the Codex
# prompts dir (CODEX_HOME/prompts) on install and removed on uninstall; an explicit
# --target skills dir installs the skill but NO prompt (unknown prompts location — it
# must never resolve outside the target and pollute $TMPDIR); dry-run creates nothing.
# Fully isolated via CODEX_HOME / --target; never touches the real ~/.codex.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# 1. CODEX_HOME layout -> skill + prompt both installed.
SB=$(make_sandbox); trap 'rm -rf "$SB"' EXIT
CODEX_HOME="$SB/codex" bash "$INSTALLER" >/dev/null 2>&1
assert_path "$SB/codex/skills/loop-testing/SKILL.md" "skill installed under CODEX_HOME"
assert_path "$SB/codex/prompts/loop-testing.md" "slash-command prompt installed under CODEX_HOME/prompts"

# 2. Uninstall removes both the skill and the prompt.
CODEX_HOME="$SB/codex" bash "$INSTALLER" --uninstall >/dev/null 2>&1
assert_no_path "$SB/codex/skills/loop-testing" "skill removed on uninstall"
assert_no_path "$SB/codex/prompts/loop-testing.md" "prompt removed on uninstall"

# 3. --target (custom skills dir) installs the skill but NOT a prompt, and must NOT
#    write a prompt into the target's parent ($TMPDIR) — the sibling-resolution trap.
SB2=$(make_sandbox); trap 'rm -rf "$SB" "$SB2"' EXIT
bash "$INSTALLER" --target "$SB2/skills" >/dev/null 2>&1
assert_path "$SB2/skills/loop-testing/SKILL.md" "skill installed at --target"
assert_no_path "$SB2/prompts/loop-testing.md" "--target does not create a sibling prompt"
assert_no_path "$(dirname "$SB2")/prompts/loop-testing.md" "--target must not write a prompt into TMPDIR"

# 4. dry-run creates nothing.
SB3=$(make_sandbox); trap 'rm -rf "$SB" "$SB2" "$SB3"' EXIT
CODEX_HOME="$SB3/codex" bash "$INSTALLER" --dry-run >/dev/null 2>&1
assert_no_path "$SB3/codex/prompts/loop-testing.md" "dry-run installs no prompt"
assert_no_path "$SB3/codex/skills/loop-testing" "dry-run installs no skill"

finish
