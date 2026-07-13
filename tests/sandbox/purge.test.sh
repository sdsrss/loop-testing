#!/usr/bin/env bash
# sandbox-clean.sh --purge (R62/NEW-4b): terminal-only full cleanup. Marker-gated,
# harvest-protected (a qa branch with fix commits needs --discard-fixes), never
# deletes a checked-out branch, and the default (no --purge) behavior is untouched.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

mark_terminal() { # repo — flip the seeded STATE.md to a terminal status
  sed -i 's/^status: RUNNING/status: CONVERGED/' "$1/docs/looptesting/STATE.md"
}

# --- A. non-terminal STATE: --purge refuses (exit 3) BEFORE doing anything ----
WS=$(mk_ws); trap 'rm -rf "$WS"' EXIT
REPO="$WS/proj"; WT="$WS/proj-qa-loop"
( cd "$REPO" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup for the non-terminal purge case"
( cd "$REPO" && bash "$CLEAN" --purge ) >/dev/null 2>&1
assert_eq "3" "$?" "--purge on a RUNNING state refuses with exit 3"
assert_exists "$WT" "refusal did not remove the worktree (precondition-first)"
assert_exists "$REPO/docs/looptesting/STATE.md" "refusal kept the evidence dir"
assert_ok "$( cd "$REPO" && git rev-parse -q --verify refs/tags/qa-baseline >/dev/null 2>&1; echo $? )" "refusal kept the baseline tag"

# --- B. terminal + fix commits, NO --discard-fixes: branch kept, rest purged --
( cd "$WT" && echo fix > fix.txt && git add fix.txt && git commit -qm "fix(qa): test fix" ) >/dev/null 2>&1
mark_terminal "$REPO"
( cd "$REPO" && bash "$CLEAN" --purge ) >/dev/null 2>&1
assert_ok $? "--purge on a terminal state exits 0"
assert_absent "$WT" "purge removed the worktree"
assert_absent "$REPO/docs/looptesting" "purge removed the evidence dir"
if ( cd "$REPO" && git rev-parse -q --verify refs/tags/qa-baseline >/dev/null 2>&1 ); then
  FAIL=$((FAIL+1)); echo "  FAIL: purge must delete the owned baseline tag" >&2
else PASS=$((PASS+1)); fi
if ( cd "$REPO" && git rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 ); then
  PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: branch with fix commits must be KEPT without --discard-fixes" >&2; fi

# --- C. purge again after purge: marker is gone -> refuse (exit 3), fail-closed
( cd "$REPO" && bash "$CLEAN" --purge ) >/dev/null 2>&1
assert_eq "3" "$?" "second --purge (marker gone) refuses with exit 3"

# --- D. terminal + fix commits + --discard-fixes: branch deleted too ----------
WS2=$(mk_ws); trap 'rm -rf "$WS" "$WS2"' EXIT
REPO2="$WS2/proj"; WT2="$WS2/proj-qa-loop"
( cd "$REPO2" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
( cd "$WT2" && echo fix > fix.txt && git add fix.txt && git commit -qm "fix(qa): test fix" ) >/dev/null 2>&1
mark_terminal "$REPO2"
( cd "$REPO2" && bash "$CLEAN" --purge --discard-fixes ) >/dev/null 2>&1
assert_ok $? "--purge --discard-fixes exits 0"
if ( cd "$REPO2" && git rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 ); then
  FAIL=$((FAIL+1)); echo "  FAIL: --discard-fixes must delete the qa branch" >&2
else PASS=$((PASS+1)); fi
assert_absent "$REPO2/docs/looptesting" "evidence dir removed (--discard-fixes case)"

# --- E. terminal + NO fix commits: branch deleted without --discard-fixes -----
WS3=$(mk_ws); trap 'rm -rf "$WS" "$WS2" "$WS3"' EXIT
REPO3="$WS3/proj"
( cd "$REPO3" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
mark_terminal "$REPO3"
( cd "$REPO3" && bash "$CLEAN" --purge ) >/dev/null 2>&1
assert_ok $? "--purge with a fix-less branch exits 0"
if ( cd "$REPO3" && git rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 ); then
  FAIL=$((FAIL+1)); echo "  FAIL: fix-less qa branch should be deleted by --purge" >&2
else PASS=$((PASS+1)); fi

# --- F. branch mode: the checked-out qa branch is never deleted ---------------
WS4=$(mk_ws); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4"' EXIT
REPO4="$WS4/proj"
( cd "$REPO4" && bash "$SETUP" --mode branch ) >/dev/null 2>&1
mark_terminal "$REPO4"
( cd "$REPO4" && bash "$CLEAN" --purge --discard-fixes ) >/dev/null 2>&1
assert_ok $? "branch-mode --purge exits 0"
if ( cd "$REPO4" && git rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 ); then
  PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: checked-out qa branch must never be deleted" >&2; fi
assert_absent "$REPO4/docs/looptesting" "branch-mode purge still removed the evidence dir"
assert_eq "qa/loop-testing" "$(cd "$REPO4" && git branch --show-current)" "purge did not move HEAD"

# --- G. no marker at all (never set up): --purge refuses, deletes nothing -----
WS5=$(mk_ws); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5"' EXIT
REPO5="$WS5/proj"
( cd "$REPO5" && bash "$CLEAN" --purge ) >/dev/null 2>&1
assert_eq "3" "$?" "--purge with no marker refuses with exit 3"
assert_exists "$REPO5/README.md" "no-marker purge touched nothing"

# --- H. usage errors ----------------------------------------------------------
( cd "$REPO5" && bash "$CLEAN" --bogus ) >/dev/null 2>&1
assert_eq "2" "$?" "unknown argument -> exit 2"
( cd "$REPO5" && bash "$CLEAN" --discard-fixes ) >/dev/null 2>&1
assert_eq "2" "$?" "--discard-fixes without --purge -> exit 2"

# --- I. R66(a): --purge invoked from INSIDE the qa worktree --------------------
# Locks the re-anchor + cd-out-before-remove behavior: the script must never rm
# the directory it is standing in; purge must complete as if run from the main tree.
WS6=$(mk_ws); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6"' EXIT
REPO6="$WS6/proj"; WT6="$WS6/proj-qa-loop"
( cd "$REPO6" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
mark_terminal "$REPO6"
MAIN_BR6="$(cd "$REPO6" && git branch --show-current)"
( cd "$WT6" && bash "$CLEAN" --purge ) >/dev/null 2>&1
assert_ok $? "--purge from inside the qa worktree exits 0 (re-anchored)"
assert_absent "$WT6" "purge-from-worktree removed the worktree it was invoked from"
assert_absent "$REPO6/docs/looptesting" "purge-from-worktree removed the evidence dir"
if ( cd "$REPO6" && git rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 ); then
  FAIL=$((FAIL+1)); echo "  FAIL: fix-less qa branch should be deleted (purge from worktree)" >&2
else PASS=$((PASS+1)); fi
if ( cd "$REPO6" && git rev-parse -q --verify refs/tags/qa-baseline >/dev/null 2>&1 ); then
  FAIL=$((FAIL+1)); echo "  FAIL: baseline tag should be deleted (purge from worktree)" >&2
else PASS=$((PASS+1)); fi
assert_eq "$MAIN_BR6" "$(cd "$REPO6" && git branch --show-current)" "main tree branch untouched (purge from worktree)"

# --- J. R66(b): --purge from an UNRELATED linked worktree of the same repo -----
# Re-anchor must land on the main tree; only the recorded qa worktree is removed,
# the unrelated worktree and its checked-out branch stay untouched.
WS7=$(mk_ws); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7"' EXIT
REPO7="$WS7/proj"; WT7="$WS7/proj-qa-loop"; OTHER7="$WS7/proj-other"
( cd "$REPO7" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
( cd "$REPO7" && git worktree add -b other "$OTHER7" ) >/dev/null 2>&1
mark_terminal "$REPO7"
( cd "$OTHER7" && bash "$CLEAN" --purge ) >/dev/null 2>&1
assert_ok $? "--purge from an unrelated linked worktree exits 0 (re-anchored)"
assert_absent "$WT7" "qa worktree removed (invoked from unrelated worktree)"
assert_absent "$REPO7/docs/looptesting" "evidence dir removed (unrelated-worktree case)"
assert_exists "$OTHER7/README.md" "unrelated worktree left intact"
assert_eq "other" "$(cd "$OTHER7" && git branch --show-current)" "unrelated worktree branch untouched"

# --- K. R66(c): --purge with the main repo on a DETACHED HEAD ------------------
# Detached HEAD is not a checkout of the qa branch: purge must still complete
# and must not move the user's HEAD.
WS8=$(mk_ws); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8"' EXIT
REPO8="$WS8/proj"; WT8="$WS8/proj-qa-loop"
( cd "$REPO8" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
mark_terminal "$REPO8"
( cd "$REPO8" && git checkout -q --detach ) >/dev/null 2>&1
HEAD8="$(cd "$REPO8" && git rev-parse HEAD)"
( cd "$REPO8" && bash "$CLEAN" --purge ) >/dev/null 2>&1
assert_ok $? "--purge with the main repo on a detached HEAD exits 0"
assert_absent "$WT8" "worktree removed (detached-HEAD case)"
assert_absent "$REPO8/docs/looptesting" "evidence dir removed (detached-HEAD case)"
if ( cd "$REPO8" && git rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 ); then
  FAIL=$((FAIL+1)); echo "  FAIL: qa branch should be deleted (detached HEAD is not a checkout of it)" >&2
else PASS=$((PASS+1)); fi
assert_eq "$HEAD8" "$(cd "$REPO8" && git rev-parse HEAD)" "purge did not move the detached HEAD"

report "purge.test.sh"
