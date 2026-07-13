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

# --- R53: trailing value-flags fail-closed (exit 2), no silent default -------
# Old behavior: a dangling --worktree-path/--branch/--baseline-tag silently fell
# back to the computed default and PROCEEDED (built a worktree at the default
# sibling path) — inconsistent with the drivers' fail-closed arg handling.
WS5=$(mk_ws); trap 'rm -rf "$WS1" "$WS" "$WS2" "$WS3" "$WS4" "$WS5"' EXIT
REPO5="$WS5/proj"
for flag in --branch --worktree-path --baseline-tag; do
  ( cd "$REPO5" && timeout 10 bash "$SETUP" --mode worktree "$flag" ) >/dev/null 2>&1
  assert_eq "2" "$?" "trailing $flag -> exit 2 (fail-closed, no silent default)"
done
assert_absent "$WS5/proj-qa-loop" "no worktree built from a dangling flag"
assert_absent "$REPO5/docs/looptesting/.sandbox/ownership.env" "no marker written from a dangling flag"

# --- R52 (DR-9): branch-mode short-circuit re-verifies the current branch ----
# setup(branch) -> user switches away -> setup(branch) again must REFUSE (the
# loop would run/commit on the wrong branch), not report "already initialized";
# switching back to the qa branch makes the short-circuit succeed again.
WS6=$(mk_ws); trap 'rm -rf "$WS1" "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6"' EXIT
REPO6="$WS6/proj"
orig_branch="$(cd "$REPO6" && git branch --show-current)"
( cd "$REPO6" && bash "$SETUP" --mode branch ) >/dev/null 2>&1
assert_ok $? "branch-mode setup for the re-verify case"
( cd "$REPO6" && git switch -q "$orig_branch" )
( cd "$REPO6" && bash "$SETUP" --mode branch ) >/dev/null 2>&1
assert_eq "7" "$?" "short-circuit on the wrong branch -> refuse (exit 7), no phantom sandbox"
assert_eq "$orig_branch" "$(cd "$REPO6" && git branch --show-current)" "refusal leaves the user's branch untouched"
( cd "$REPO6" && git switch -q qa/loop-testing )
( cd "$REPO6" && bash "$SETUP" --mode branch ) >/dev/null 2>&1
assert_ok $? "back on the qa branch -> short-circuit succeeds again"

# --- R52 legacy marker: a pre-SANDBOX_BRANCH marker must NOT be refused --------
# A branch-mode sandbox from before this change has no SANDBOX_BRANCH field; the
# recorded branch is unknown, so the re-verify must SKIP (not guess the invocation
# default and refuse a valid, correctly-positioned sandbox with wrong advice).
WS7=$(mk_ws); trap 'rm -rf "$WS1" "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7"' EXIT
REPO7="$WS7/proj"
( cd "$REPO7" && bash "$SETUP" --mode branch --branch qa/custom ) >/dev/null 2>&1
assert_ok $? "setup on a custom branch for the legacy case"
# Strip SANDBOX_BRANCH to simulate a marker written by the previous version.
MK="$REPO7/docs/looptesting/.sandbox/ownership.env"
grep -v '^SANDBOX_BRANCH=' "$MK" > "$MK.tmp" && mv "$MK.tmp" "$MK"
# Tree correctly on qa/custom; resume with DEFAULT flags (branch would guess qa/loop-testing).
( cd "$REPO7" && bash "$SETUP" --mode branch ) >/dev/null 2>&1
assert_ok $? "legacy marker (no SANDBOX_BRANCH) -> short-circuit, not a wrong-branch refusal"
assert_eq "qa/custom" "$(cd "$REPO7" && git branch --show-current)" "legacy re-verify left the user's branch untouched"

# --- R57 (NEW-1): invoked from INSIDE the qa worktree must re-anchor ----------
# From the worktree cwd, `git rev-parse --show-toplevel` is the WORKTREE, so the
# old code missed the main repo's marker, fell through to full init, and tried
# to nest a second `<wt>-qa-loop` worktree (dying exit 6 with misleading advice).
# The fix re-anchors TOP to the main tree -> idempotent short-circuit (exit 0).
WS8=$(mk_ws); trap 'rm -rf "$WS1" "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8"' EXIT
REPO8="$WS8/proj"
WT8="$WS8/proj-qa-loop"
( cd "$REPO8" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup for the worktree-cwd case"
( cd "$WT8" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_eq "0" "$?" "setup from inside the worktree -> re-anchored short-circuit (exit 0, R57)"
assert_absent "$WS8/proj-qa-loop-qa-loop" "no nested worktree path created (R57)"
assert_absent "$WT8/docs/looptesting/.sandbox" "no second marker written inside the worktree (R57)"
assert_exists "$REPO8/docs/looptesting/.sandbox/ownership.env" "main-tree marker untouched (R57)"

report "setup.test.sh"
