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

# ── H-02 (audit 2026-09-20): the prompt file is claimed by identity, not by name.
#    Install used to `cp` over a user's own ~/.codex/prompts/loop-testing.md and
#    uninstall `rm -f`'d it by basename — no marker, no backup. ──

# 5. A pre-existing FOREIGN prompt (the user's own file at that name): install
#    leaves it byte-for-byte intact, still installs the skill, exits 0, and says so.
SB4=$(make_sandbox); trap 'rm -rf "$SB" "$SB2" "$SB3" "$SB4"' EXIT
mkdir -p "$SB4/codex/prompts"
printf 'MY OWN PROMPT - do not touch\n' > "$SB4/codex/prompts/loop-testing.md"
out=$(CODEX_HOME="$SB4/codex" bash "$INSTALLER" 2>&1); rc=$?
assert_eq "$rc" "0" "H-02: install with a foreign prompt present still exits 0 (skill installed)"
assert_path "$SB4/codex/skills/loop-testing/SKILL.md" "H-02: skill installed alongside a foreign prompt"
assert_eq "$(cat "$SB4/codex/prompts/loop-testing.md")" "MY OWN PROMPT - do not touch" "H-02: foreign prompt NOT overwritten"
assert_contains "$out" "not installed by loop-testing" "H-02: install names the foreign prompt it refused to replace"
assert_no_path "$SB4/codex/prompts/loop-testing.md.bak" "H-02: no .bak of a file we do not own"

# 6. Uninstall with that foreign prompt present: the skill goes, the prompt stays.
out=$(CODEX_HOME="$SB4/codex" bash "$INSTALLER" --uninstall 2>&1); rc=$?
assert_eq "$rc" "0" "H-02: uninstall exits 0 with a foreign prompt present"
assert_no_path "$SB4/codex/skills/loop-testing" "H-02: skill removed"
assert_path "$SB4/codex/prompts/loop-testing.md" "H-02: foreign prompt NOT deleted on uninstall"
assert_contains "$out" "not installed by loop-testing" "H-02: uninstall names the prompt it kept"

# 7. Our prompt, edited by the user after install: it is theirs now — reinstall
#    refuses to overwrite it and uninstall keeps it.
SB5=$(make_sandbox); trap 'rm -rf "$SB" "$SB2" "$SB3" "$SB4" "$SB5"' EXIT
CODEX_HOME="$SB5/codex" bash "$INSTALLER" >/dev/null 2>&1
assert_contains "$(cat "$SB5/codex/skills/loop-testing/.loop-testing-codex-install")" "prompt_cksum=" "H-02: marker records the installed prompt's checksum"
printf '\n# my local tweak\n' >> "$SB5/codex/prompts/loop-testing.md"
edited=$(cat "$SB5/codex/prompts/loop-testing.md")
CODEX_HOME="$SB5/codex" bash "$INSTALLER" >/dev/null 2>&1
assert_eq "$(cat "$SB5/codex/prompts/loop-testing.md")" "$edited" "H-02: user-edited prompt survives a reinstall"
CODEX_HOME="$SB5/codex" bash "$INSTALLER" --uninstall >/dev/null 2>&1
assert_path "$SB5/codex/prompts/loop-testing.md" "H-02: user-edited prompt survives uninstall"

# 8. Legacy install (marker predates the prompt record) whose prompt is the
#    unmodified shipped file: still recognised as ours and removed on uninstall.
SB6=$(make_sandbox); trap 'rm -rf "$SB" "$SB2" "$SB3" "$SB4" "$SB5" "$SB6"' EXIT
CODEX_HOME="$SB6/codex" bash "$INSTALLER" >/dev/null 2>&1
grep -v '^prompt' "$SB6/codex/skills/loop-testing/.loop-testing-codex-install" > "$SB6/m" \
  && cat "$SB6/m" > "$SB6/codex/skills/loop-testing/.loop-testing-codex-install"
CODEX_HOME="$SB6/codex" bash "$INSTALLER" --uninstall >/dev/null 2>&1
assert_no_path "$SB6/codex/prompts/loop-testing.md" "H-02: legacy-marker install with the shipped prompt -> prompt removed"

# 9. Reinstall over our own unmodified prompt still refreshes it (no false refusal).
SB7=$(make_sandbox); trap 'rm -rf "$SB" "$SB2" "$SB3" "$SB4" "$SB5" "$SB6" "$SB7"' EXIT
CODEX_HOME="$SB7/codex" bash "$INSTALLER" >/dev/null 2>&1
out=$(CODEX_HOME="$SB7/codex" bash "$INSTALLER" 2>&1)
assert_contains "$out" "slash command: /loop-testing" "H-02: reinstall over our own prompt refreshes it"
assert_eq "$(cat "$SB7/codex/prompts/loop-testing.md")" "$(cat "$REPO_ROOT/prompts/loop-testing.md")" "H-02: refreshed prompt equals the shipped file"

# ── A SYMLINK at the prompt path is never ours. GNU cp refuses to write through a
#    dangling symlink; BSD cp (macOS, a supported Codex platform) follows it and
#    creates the target — a write outside the resolved target, which this
#    installer's header promises never happens. Same for a live symlink: `cp`
#    would overwrite whatever it points at. ──

# 10. Dangling symlink: nothing is created at the far end, the link is untouched.
SB8=$(make_sandbox); trap 'rm -rf "$SB" "$SB2" "$SB3" "$SB4" "$SB5" "$SB6" "$SB7" "$SB8"' EXIT
mkdir -p "$SB8/codex/prompts" "$SB8/outside"
ln -s "$SB8/outside/victim.md" "$SB8/codex/prompts/loop-testing.md"
out=$(CODEX_HOME="$SB8/codex" bash "$INSTALLER" 2>&1); rc=$?
assert_eq "$rc" "0" "symlink: install still exits 0"
assert_path "$SB8/codex/skills/loop-testing/SKILL.md" "symlink: skill still installed"
assert_no_path "$SB8/outside/victim.md" "symlink: nothing written through the dangling link"
assert_contains "$out" "not installed by loop-testing" "symlink: install names the link it left alone"
if [ -L "$SB8/codex/prompts/loop-testing.md" ]; then pass "symlink: the link itself is untouched"
else fail "symlink: the link was replaced"; fi

# 11. Live symlink pointing at a foreign file: the target is not overwritten, and
#     uninstall removes neither the link nor what it points at.
SB9=$(make_sandbox); trap 'rm -rf "$SB" "$SB2" "$SB3" "$SB4" "$SB5" "$SB6" "$SB7" "$SB8" "$SB9"' EXIT
mkdir -p "$SB9/codex/prompts" "$SB9/outside"
printf 'THEIR FILE\n' > "$SB9/outside/real.md"
ln -s "$SB9/outside/real.md" "$SB9/codex/prompts/loop-testing.md"
CODEX_HOME="$SB9/codex" bash "$INSTALLER" >/dev/null 2>&1
assert_eq "$(cat "$SB9/outside/real.md")" "THEIR FILE" "symlink: linked-to file not overwritten"
CODEX_HOME="$SB9/codex" bash "$INSTALLER" --uninstall >/dev/null 2>&1
assert_path "$SB9/outside/real.md" "symlink: linked-to file survives uninstall"
if [ -L "$SB9/codex/prompts/loop-testing.md" ]; then pass "symlink: link survives uninstall"
else fail "symlink: uninstall removed a link it did not create"; fi

# 12. A symlink whose target holds OUR exact bytes is still not ours: we never
#     created a link there, and removing it would be claiming it by path.
SB10=$(make_sandbox); trap 'rm -rf "$SB" "$SB2" "$SB3" "$SB4" "$SB5" "$SB6" "$SB7" "$SB8" "$SB9" "$SB10"' EXIT
mkdir -p "$SB10/codex/prompts" "$SB10/outside"
cp "$REPO_ROOT/prompts/loop-testing.md" "$SB10/outside/ours.md"
ln -s "$SB10/outside/ours.md" "$SB10/codex/prompts/loop-testing.md"
CODEX_HOME="$SB10/codex" bash "$INSTALLER" >/dev/null 2>&1
CODEX_HOME="$SB10/codex" bash "$INSTALLER" --uninstall >/dev/null 2>&1
assert_path "$SB10/outside/ours.md" "symlink: content-identical target survives uninstall"
if [ -L "$SB10/codex/prompts/loop-testing.md" ]; then pass "symlink: content-identical link survives uninstall"
else fail "symlink: uninstall removed a link it did not create"; fi

finish
