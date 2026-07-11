#!/usr/bin/env bash
# sandbox-setup.sh: git guard, refuse-dirty, branch/tag creation, template
# seeding, ownership marker, idempotency.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# --- non-git dir is refused ---------------------------------------------------
WS1=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-nongit.XXXXXX"); trap 'rm -rf "$WS1"' EXIT
( cd "$WS1" && bash "$SETUP" --mode branch ) >/dev/null 2>&1
assert_nonzero $? "non-git dir refused"

# --- clean repo, branch mode: creates sandbox --------------------------------
WS=$(mk_ws); trap 'rm -rf "$WS1" "$WS"' EXIT
REPO="$WS/proj"
( cd "$REPO" && bash "$SETUP" --mode branch ) >/dev/null 2>&1
assert_ok $? "branch-mode setup succeeds on clean repo"

assert_eq "qa/loop-testing" "$(cd "$REPO" && git rev-parse --abbrev-ref HEAD)" "switched to qa branch"
assert_ok "$( cd "$REPO" && git rev-parse -q --verify refs/tags/qa-baseline >/dev/null 2>&1; echo $? )" "qa-baseline tag created"
assert_exists "$REPO/docs/looptesting/STATE.md" "STATE.md seeded"
assert_exists "$REPO/docs/looptesting/ISSUES.md" "ISSUES.md seeded"
assert_eq "0" "$(grep -acE '^### ISSUE-' "$REPO/docs/looptesting/ISSUES.md" 2>/dev/null || true)" "fresh ISSUES.md counts 0 issues (placeholder is commented/indented, C2)"
assert_exists "$REPO/docs/looptesting/FEATURE_MATRIX.md" "FEATURE_MATRIX.md seeded"
assert_exists "$REPO/docs/looptesting/.sandbox/ownership.env" "ownership marker written"
assert_file_contains "$REPO/docs/looptesting/STATE.md" "converged_streak:" "STATE has machine field"
assert_exists "$REPO/docs/looptesting/.active" "stop-gate sentinel armed by setup"
if [ -f "$REPO/docs/looptesting/FINAL_REPORT.md" ]; then
  FAIL=$((FAIL+1)); echo "  FAIL: FINAL_REPORT.md must NOT be seeded at setup (exit-time only)" >&2
else PASS=$((PASS+1)); echo "  ok: FINAL_REPORT.md not pre-seeded"; fi

# --- idempotent: second run does not error, does not reset ------------------
echo "USER EDIT" >> "$REPO/docs/looptesting/STATE.md"
( cd "$REPO" && bash "$SETUP" --mode branch ) >/dev/null 2>&1
assert_ok $? "second setup run is idempotent (exit 0)"
assert_file_contains "$REPO/docs/looptesting/STATE.md" "USER EDIT" "idempotent run did not overwrite existing state file"

# --- dirty tree in branch mode is refused (no marker yet) --------------------
WS2=$(mk_ws); trap 'rm -rf "$WS1" "$WS" "$WS2"' EXIT
REPO2="$WS2/proj"
echo "uncommitted work" > "$REPO2/user-wip.txt"
( cd "$REPO2" && bash "$SETUP" --mode branch ) >/dev/null 2>&1
assert_nonzero $? "branch-mode setup refuses dirty tree"
# ensure branch was NOT created on refusal
if ( cd "$REPO2" && git rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 ); then
  FAIL=$((FAIL+1)); echo "  FAIL: dirty refusal must not create branch" >&2
else PASS=$((PASS+1)); fi

# --- value-taking flag as the LAST token must fail-closed, never hang --------
# Regression guard: `shift 2` on a 1-arg tail is a no-op -> infinite loop
# (same class as the driver da16858 fix, which missed this script). Run from a
# throwaway NON-git dir so nothing real is touched even if a flag proceeds.
WS3=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-trail.XXXXXX"); trap 'rm -rf "$WS1" "$WS" "$WS2" "$WS3"' EXIT
( cd "$WS3" && timeout 10 bash "$SETUP" --mode ) >/dev/null 2>&1
rc=$?
assert_eq "2" "$rc" "trailing --mode -> exit 2 (mode validation), not a hang"
for flag in --branch --worktree-path --baseline-tag; do
  ( cd "$WS3" && timeout 10 bash "$SETUP" "$flag" ) >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 124 ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: trailing $flag hung (exit 124)" >&2; fi
done

# --- worktree rebuild after clean removed it (audit B2) ----------------------
# setup(worktree) -> clean (removes worktree, keeps marker) -> setup(worktree)
# must REBUILD the isolated worktree, not phantom-short-circuit on the stale
# marker (which would leave the loop running against the main tree).
WS4=$(mk_ws); trap 'rm -rf "$WS1" "$WS" "$WS2" "$WS3" "$WS4"' EXIT
REPO4="$WS4/proj"
WT4="$WS4/proj-qa-loop"
( cd "$REPO4" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "worktree-mode setup succeeds"
assert_exists "$WT4" "worktree created by first setup"
( cd "$REPO4" && bash "$CLEAN" ) >/dev/null 2>&1
assert_absent "$WT4" "clean removed the worktree"
assert_exists "$REPO4/docs/looptesting/.sandbox/ownership.env" "clean kept the marker"
( cd "$REPO4" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "second worktree-mode setup succeeds after clean"
assert_exists "$WT4" "worktree REBUILT by second setup (not phantom short-circuit)"
if ( cd "$REPO4" && git worktree list --porcelain | grep -qxF "worktree $WT4" ); then
  PASS=$((PASS+1)); echo "  ok: rebuilt worktree is a registered git worktree"
else FAIL=$((FAIL+1)); echo "  FAIL: rebuilt worktree not in git worktree list" >&2; fi

report "setup.test.sh"
