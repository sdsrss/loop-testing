#!/usr/bin/env bash
# Regression guard for the sandbox-isolation fix (product bug found in the
# 2026-07-12 ubuntu-sec smoke run): under headless `claude -p`/`codex exec` the
# agent skipped sandbox-setup.sh and switched the user's MAIN worktree to the qa
# branch in place (branch-mode), defeating worktree isolation and blocking the
# user from working. The drivers' RESUME_PROMPT now mandates worktree-mode
# isolation via sandbox-setup.sh and forbids any manual branch switch of the
# user's tree. Both drivers must carry this clause identically (CLAUDE.md: keep
# the two drivers structurally identical). This asserts the clause is present in
# BOTH prompts and never silently drops out of one.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
CODEX_DRIVER="$REPO_ROOT/skills/loop-testing/scripts/unattended-codex.sh"

for drv in "$DRIVER" "$CODEX_DRIVER"; do
  name="$(basename "$drv")"
  assert_file_contains "$drv" "worktree 模式隔离" "$name RESUME_PROMPT mandates worktree-mode isolation"
  assert_file_contains "$drv" "禁止手动 git switch/checkout/branch" "$name RESUME_PROMPT forbids manual branch switch of the user tree"
  assert_file_contains "$drv" ".sandbox/ownership.env" "$name RESUME_PROMPT requires the isolation proof marker before editing"
done

report "prompt-isolation.test.sh"
