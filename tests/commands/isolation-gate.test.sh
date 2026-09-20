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
_pass=0
_failn=0
pass() { printf '  ok: %s\n' "$1"; _pass=$((_pass + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; _fails=1; _failn=$((_failn + 1)); }
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

# ── doc <-> script coherence, by RUNNING the script ──────────────────────────
# These were two greps over the source. They were a tautology: disabling the
# exit-9 block entirely left this suite fully green, still printing "actually
# exits 9 somewhere", because the string was still in the file. Direction (a),
# the doc says it, was verified; direction (b), the script does it, was not.
#
# Scope split, so neither half is orphaned: the eight assertions below prove the
# gate's PREMISE — that a 9 really happens and that the four state checks really
# cannot see it. tests/sandbox/setup-marker-integrity.test.sh owns the fuller
# behavioural surface of exit 9 (corrupt, truncated and blank-valued markers; no
# .active armed; no worktree created; the marker left unrewritten).
if ! command -v git >/dev/null 2>&1; then
  fail "git is required for the behavioural half of this suite"
else
  FIX=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-gate.XXXXXX")
  trap 'rm -rf "$FIX"' EXIT
  (
    cd "$FIX" && mkdir proj && cd proj && git init -q \
      && git config user.email t@t && git config user.name t \
      && echo x > README.md && git add README.md && git commit -qm init
  ) >/dev/null 2>&1
  REPO="$FIX/proj"
  MARKER="$REPO/docs/looptesting/.sandbox/ownership.env"
  ( cd "$REPO" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
  BR_BEFORE="$(cd "$REPO" && git symbolic-ref --short -q HEAD 2>/dev/null)"

  if [ -f "$MARKER" ]; then pass "fixture: a live sandbox exists"; else fail "fixture: setup did not produce a marker"; fi

  # Corrupt the marker the way a truncated write or a hand-edit does.
  sed -i.bak 's/^SANDBOX_VERSION=.*/SANDBOX_VERSION=/' "$MARKER" 2>/dev/null; rm -f "$MARKER.bak"

  ( cd "$REPO" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
  RC=$?
  if [ "$RC" -eq 9 ]; then
    pass "sandbox-setup.sh really returns 9 over an unreadable marker"
  else
    fail "sandbox-setup.sh returned $RC, not the documented 9, over an unreadable marker"
  fi

  # The premise of clause 1: after that 9, every state check in clause 2 passes.
  # If any of these four ever stops passing, the doc's justification is stale and
  # this test should be revisited rather than the clause quietly kept.
  [ -f "$MARKER" ] \
    && pass "after a 9 the marker is still present (state check 1 would pass)" \
    || fail "after a 9 the marker is gone — the gate's premise no longer holds"
  wt_n="$(cd "$REPO" && git worktree list --porcelain 2>/dev/null | grep -c '^worktree ')"
  [ "$wt_n" -ge 2 ] \
    && pass "after a 9 the old sibling checkout is still registered (state check 2 would pass)" \
    || fail "after a 9 only $wt_n worktree(s) registered — the gate's premise no longer holds"
  [ "$(cd "$REPO" && git symbolic-ref --short -q HEAD 2>/dev/null)" = "$BR_BEFORE" ] \
    && pass "after a 9 the main tree is on its original branch (state check 3 would pass)" \
    || fail "after a 9 the main tree moved off $BR_BEFORE — the gate's premise no longer holds"
  [ -f "$REPO/docs/looptesting/.active" ] \
    && pass "after a 9 the resume sentinel is still present (state check 4 would pass)" \
    || fail "after a 9 .active is gone — the gate's premise no longer holds"

  # The gate points the reader at --help for the code table; that has to be true
  # of the running script, not of a comment in it.
  if bash "$SETUP" --help 2>/dev/null | tr '[:space:]' ' ' | tr -s ' ' | grep -q '9 the ownership marker is present but unreadable'; then
    pass "--help really prints the exit-9 entry the gate sends the reader to"
  else
    fail "--help does not print an exit-9 entry, but the gate tells the reader to look there"
  fi
fi

# ── the gate must not tell the reader that the state checks are sufficient ───
hasnt "$ROUND0" "任一不满足＝隔离未成立：立即停止" \
  "the old four-check-only wording is gone (it made a 9 look like a pass)"

printf '%s: %d passed, %d failed\n' "${0##*/}" "$_pass" "$_failn"
exit "$_fails"
