#!/usr/bin/env bash
# isolation-gate.test.sh — the round-0 isolation gate must read sandbox-setup's
# EXIT STATUS, not just the state it left behind.
#
# Why this is a test and not a comment: no script reads the gate. Neither
# unattended driver executes sandbox-setup.sh — the agent is the only thing that
# runs it, so the gate in references/round-0.md IS the enforcement. A clause that
# is missing there is a hole nothing else covers.
#
# The specific hole: sandbox-setup.sh exit 9 (ownership marker present but
# unreadable) can only be emitted when the marker file EXISTS, which is the
# gate's own first condition. With a prior sandbox standing, all four state
# checks the gate used to list pass after a 9 — marker present, sibling checkout
# registered, main tree on its original branch, .active present — while this run
# established no isolation at all. The exit status is the only signal that
# separates the two, and a 9 must land in the gate's BLOCKED path.
#
# Teardown from that state does not save the user either: plain clean exits 0
# ("deleting nothing"), --purge exits 3, and both worktrees, the tag and the
# branch remain.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROUND0="$REPO_ROOT/skills/loop-testing/references/round-0.md"
SETUP="$REPO_ROOT/skills/loop-testing/scripts/sandbox-setup.sh"

_fails=0
pass() { printf '  ok: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; _fails=1; }
# Markdown wraps phrases across lines: flatten whitespace before matching.
flat() { tr '[:space:]' ' ' < "$1" | tr -s ' '; }
has()  { if flat "$1" | grep -qF "$2"; then pass "$3"; else fail "$3 (missing '$2' in ${1##*/})"; fi; }
hasnt() { if flat "$1" | grep -qF "$2"; then fail "$3 (unexpected '$2' in ${1##*/})"; else pass "$3"; fi; }

[ -f "$ROUND0" ] && pass "references/round-0.md exists" || { fail "round-0.md missing"; exit 1; }
[ -f "$SETUP" ]  && pass "sandbox-setup.sh exists"      || { fail "sandbox-setup.sh missing"; exit 1; }

# ── the gate reads the exit status, first ────────────────────────────────────
has "$ROUND0" "退出码" "the gate talks about sandbox-setup's exit code"
has "$ROUND0" "必须为 0" "the gate requires a zero exit status"

# ── and names the code that defeats every state check ────────────────────────
has "$ROUND0" "exit 9" "the gate names exit 9 specifically"
has "$ROUND0" "ownership marker" "the gate says what exit 9 means"

# ── a non-zero status lands in BLOCKED, like every other gate failure ────────
has "$ROUND0" "BLOCKED" "the gate's failure path is BLOCKED"

# The four state checks must still be there — the exit-status clause is an
# addition, not a replacement: a zero exit with a missing marker is still a
# failure (an older setup, a partially upgraded install).
has "$ROUND0" "ownership.env" "the gate still verifies the marker exists"
has "$ROUND0" "git worktree list" "the gate still verifies the sibling checkout"
has "$ROUND0" "git branch --show-current" "the gate still verifies the main tree's branch"
has "$ROUND0" ".active" "the gate still verifies the resume sentinel"

# ── doc <-> script coherence: a code the gate names must be one the script emits
if grep -qE '^# .*· 9 the$|^# .*· 9 ' "$SETUP" || grep -q '· 9 the' "$SETUP"; then
  pass "sandbox-setup.sh documents exit 9 in its header"
else
  fail "sandbox-setup.sh header does not document exit 9, but the gate names it"
fi
if grep -qE '" 9$|" 9;' "$SETUP"; then
  pass "sandbox-setup.sh actually exits 9 somewhere"
else
  fail "sandbox-setup.sh never exits 9, but its header and the gate both name it"
fi

# ── the gate must not tell the reader that the state checks are sufficient ───
hasnt "$ROUND0" "任一不满足＝隔离未成立：立即停止" \
  "the old four-check-only wording is gone (it made a 9 look like a pass)"

printf '%s: %s\n' "${0##*/}" "$([ "$_fails" -eq 0 ] && echo 'ok' || echo 'FAILED')"
exit "$_fails"
