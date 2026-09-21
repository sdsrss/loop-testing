#!/usr/bin/env bash
# sandbox-clean.sh --purge (R62/NEW-4b): terminal-only full cleanup. Marker-gated,
# harvest-protected (a qa branch with fix commits needs --discard-fixes), never
# deletes a checked-out branch, and the default (no --purge) behavior is untouched.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# Fixtures are registered the moment they are created, and the trap is set once.
# The retyped-list form this replaces had BOTH of its failure modes live here:
#
#   * the trap at the WSD site referenced $WSB and $WSC, whose first assignments
#     are 27 and 40 lines further down. Under `set -u` an early exit anywhere in
#     between killed the trap on its first unbound reference and nothing at all
#     was removed. Measured by injecting `exit 7` into that window: 11 leaked
#     workspaces before this change, 0 after it, with the injection diffed to
#     prove it landed and rc=7 confirming it executed;
#   * the two traps that follow it never listed WSD, so an early exit there
#     dropped that one workspace silently.
#
# That is audit T-10. The commit that claimed it changed a different file for a
# different defect, and this file — the one the finding names — was never touched.
#
# An array, not a delimited string. The eight suites still using the space-split
# form are unsafe for any $TMPDIR containing a space, a tab, a newline or a glob
# character; a newline-delimited string fixes three of those and still splits
# `/tmp/qa<newline>root` into `/tmp/qa` and `root/loop-testing-sb.XXXXXX`, and
# `set -f` does not close that. An array is the only form that is correct for
# every path and removes the need to reason about IFS at all.
#
# bash 3.2 under `set -u`: `${#A[@]}` on an empty array is safe, `"${A[@]}"` is
# the one that errors — so the count test has to short-circuit before it.
WS_ALL=()
track_ws() { WS_ALL+=("$1"); }
cleanup_all() {
  if [ "${#WS_ALL[@]}" -gt 0 ]; then rm -rf -- "${WS_ALL[@]}"; fi
}
trap cleanup_all EXIT

mark_terminal() { # repo — flip the seeded STATE.md to a terminal status
  sed -i 's/^status: RUNNING/status: CONVERGED/' "$1/docs/looptesting/STATE.md"
}

# --- A. non-terminal STATE: --purge refuses (exit 3) BEFORE doing anything ----
WS=$(mk_ws); track_ws "$WS"
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
# The branch is KEPT here (fix commits, no --discard-fixes), so the marker that the
# recommended follow-up needs is kept with it. This assertion used to demand the
# opposite and was the shape of the defect: the run named `--purge --discard-fixes`
# and deleted the only file that command can read.
assert_exists "$REPO/docs/looptesting/.sandbox/ownership.env" "a kept branch keeps the marker its follow-up needs"
# Nothing in the directory is removed while a ref is kept, deliberately: commits you
# have not harvested yet are exactly when the ledger and the round logs are worth
# reading. The directory goes in one piece once the ref does.
assert_exists "$REPO/docs/looptesting/ISSUES.md" "the evidence stays readable while the fix commits are unharvested"
if ( cd "$REPO" && git rev-parse -q --verify refs/tags/qa-baseline >/dev/null 2>&1 ); then
  FAIL=$((FAIL+1)); echo "  FAIL: purge must delete the owned baseline tag" >&2
else PASS=$((PASS+1)); fi
if ( cd "$REPO" && git rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 ); then
  PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: branch with fix commits must be KEPT without --discard-fixes" >&2; fi

# --- C. purge again while the branch is still kept: re-runnable, not stranded --
# The marker survived B, so this run can still identify what is ours. It reaches the
# same verdict rather than a fail-closed exit 3 — the route out stays open until the
# user harvests. (Exit 3 on a genuinely absent marker is covered by case G.)
OUT_C=$( cd "$REPO" && bash "$CLEAN" --purge 2>&1 ); rc_c=$?
assert_eq "0" "$rc_c" "second --purge is re-runnable while the branch is kept"
assert_exists "$REPO/docs/looptesting/.sandbox/ownership.env" "and the marker is still there"
OUT_C2=$( cd "$REPO" && bash "$CLEAN" --purge --discard-fixes 2>&1 ); rc_c2=$?
assert_eq "0" "$rc_c2" "the documented --discard-fixes follow-up completes"
assert_absent "$REPO/docs/looptesting" "and only then is the evidence dir removed"

# --- D. terminal + fix commits + --discard-fixes: branch deleted too ----------
WS2=$(mk_ws); track_ws "$WS2"
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
WS3=$(mk_ws); track_ws "$WS3"
REPO3="$WS3/proj"
( cd "$REPO3" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
mark_terminal "$REPO3"
( cd "$REPO3" && bash "$CLEAN" --purge ) >/dev/null 2>&1
assert_ok $? "--purge with a fix-less branch exits 0"
if ( cd "$REPO3" && git rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 ); then
  FAIL=$((FAIL+1)); echo "  FAIL: fix-less qa branch should be deleted by --purge" >&2
else PASS=$((PASS+1)); fi

# --- F. branch mode: the checked-out qa branch is never deleted ---------------
WS4=$(mk_ws); track_ws "$WS4"
REPO4="$WS4/proj"
( cd "$REPO4" && bash "$SETUP" --mode branch ) >/dev/null 2>&1
mark_terminal "$REPO4"
( cd "$REPO4" && bash "$CLEAN" --purge --discard-fixes ) >/dev/null 2>&1
assert_ok $? "branch-mode --purge exits 0"
if ( cd "$REPO4" && git rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 ); then
  PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: checked-out qa branch must never be deleted" >&2; fi
# Branch mode stands ON the qa branch, and git will not delete a checked-out branch
# whatever --discard-fixes says. Something we may own is still there, so the marker
# stays with it: switch away, delete the branch, purge again. Keeping the record is
# the difference between one more step and a directory nothing can identify.
assert_exists "$REPO4/docs/looptesting/.sandbox/ownership.env" "branch mode keeps the marker while the branch it names is checked out"
assert_eq "qa/loop-testing" "$(cd "$REPO4" && git branch --show-current)" "purge did not move HEAD"

# --- G. no marker at all (never set up): --purge refuses, deletes nothing -----
WS5=$(mk_ws); track_ws "$WS5"
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
WS6=$(mk_ws); track_ws "$WS6"
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
WS7=$(mk_ws); track_ws "$WS7"
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
WS8=$(mk_ws); track_ws "$WS8"
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

# --- L. ownership survives a plain clean -> re-setup (rebuild) cycle -----------
# sandbox-clean (no --purge) deliberately KEEPS the qa branch + baseline tag, and
# the resume path in sandbox-setup drops the marker and re-inits when the recorded
# worktree is gone. Re-deriving ownership from "does this ref exist now" then
# records NEITHER as ours, so --purge can no longer remove the artifacts this
# sandbox created — and the "branch holds fix commits" warning goes silent too.
WS9=$(mk_ws); track_ws "$WS9"
REPO9="$WS9/proj"
( cd "$REPO9" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
( cd "$REPO9" && bash "$CLEAN" ) >/dev/null 2>&1                    # keeps branch + tag
( cd "$REPO9" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1    # resume -> marker rebuilt
MARK9="$REPO9/docs/looptesting/.sandbox/ownership.env"
# ADOPTED, not CREATED: ownership is recorded by NAME only, and between the clean
# and this rebuild the user may have replaced the ref with one of their own. The
# rebuild re-uses a ref it cannot prove it created, so it records the fact without
# re-claiming deletion rights.
assert_file_contains "$MARK9" "ADOPTED_BRANCH=qa/loop-testing" "rebuilt marker adopts the branch"
assert_file_contains "$MARK9" "ADOPTED_TAG=qa-baseline" "rebuilt marker adopts the tag"
# The claim is that the value is EMPTY, so the predicate has to be about the
# value. `grep -F "CREATED_BRANCH="` matches `CREATED_BRANCH=qa/loop-testing`
# just as happily, and every marker carries the key — so it passed whether or not
# the rebuild re-claimed ownership, which is the one thing it exists to detect
# (audit T-05). Anchored, and the value side must be empty to the end of line.
if grep -qE '^CREATED_BRANCH=[[:space:]]*$' "$MARK9"; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: rebuilt marker re-claimed branch ownership — got: $(grep -a '^CREATED_BRANCH=' "$MARK9")" >&2; fi
mark_terminal "$REPO9"
OUT9=$( cd "$REPO9" && bash "$CLEAN" --purge 2>&1 )
assert_ok $? "--purge after a rebuild exits 0"
if ( cd "$REPO9" && git rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 ); then
  PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: purge must NOT delete a branch this run only re-used" >&2; fi
if ( cd "$REPO9" && git rev-parse -q --verify refs/tags/qa-baseline >/dev/null 2>&1 ); then
  PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: purge must NOT delete a tag this run only re-used" >&2; fi
# ...but it must SAY so, instead of a bare "purge done." that reads as "all clean".
case "$OUT9" in
  *"qa/loop-testing"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: purge must name the re-used branch it kept — got: $OUT9" >&2 ;;
esac

# --- M. the harvest warning survives the same rebuild cycle -------------------
# Fix commits live ONLY on the qa branch. After a rebuild, purge must still name
# the branch it is keeping — a silent "purge done." reads as "everything cleaned".
WSA=$(mk_ws); track_ws "$WSA"
REPOA="$WSA/proj"; WTA="$WSA/proj-qa-loop"
( cd "$REPOA" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
( cd "$REPOA" && bash "$CLEAN" ) >/dev/null 2>&1
( cd "$REPOA" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
( cd "$WTA" && echo fix > fix.txt && git add fix.txt && git commit -qm "fix(qa): test fix" ) >/dev/null 2>&1
mark_terminal "$REPOA"
OUTA=$( cd "$REPOA" && bash "$CLEAN" --purge 2>&1 )
case "$OUTA" in
  *"KEPT branch: qa/loop-testing"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: purge after a rebuild must report the KEPT branch holding fix commits — got: $OUTA" >&2 ;;
esac
case "$OUTA" in
  *"1 commit"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: the KEPT line must say how many commits are on it — got: $OUTA" >&2 ;;
esac
if ( cd "$REPOA" && git rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 ); then
  PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: branch with fix commits must survive purge after a rebuild" >&2; fi

# --- O. a ref the user REPLACED between lifecycles is never deleted -------------
# Ownership is recorded by name. If the user deletes the qa branch/tag and creates
# their own with the same name, a rebuild must not hand --purge the right to delete
# them — and with no commits beyond the recorded baseline the old code deleted both
# under a PLAIN --purge, printing nothing at all.
WSD=$(mk_ws); track_ws "$WSD"
REPOD="$WSD/proj"
( cd "$REPOD" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
( cd "$REPOD" && bash "$CLEAN" ) >/dev/null 2>&1
(
  cd "$REPOD"
  git branch -D qa/loop-testing >/dev/null 2>&1
  git tag -d qa-baseline >/dev/null 2>&1
  git branch qa/loop-testing            # the user's own ref, same name, at HEAD
  git tag qa-baseline                   # the user's own tag, same name
) >/dev/null 2>&1
( cd "$REPOD" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
mark_terminal "$REPOD"
( cd "$REPOD" && bash "$CLEAN" --purge ) >/dev/null 2>&1
assert_ok $? "--purge over user-replaced refs exits 0"
if ( cd "$REPOD" && git rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 ); then
  PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: purge deleted a same-named branch the user created (data loss)" >&2; fi
if ( cd "$REPOD" && git rev-parse -q --verify refs/tags/qa-baseline >/dev/null 2>&1 ); then
  PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: purge deleted a same-named tag the user created (data loss)" >&2; fi

# --- N. a harvested branch is reported as harvested, not as "harvest them first" -
# Merging does not move the qa tip, but it does make the tip reachable from the
# merging ref — so a completed harvest IS detectable. The branch is still KEPT
# (deleting commits stays the user's call); only the advice changes, so the user
# who just merged is not told to redo it.
WSB=$(mk_ws); track_ws "$WSB"
REPOB="$WSB/proj"; WTB="$WSB/proj-qa-loop"
( cd "$REPOB" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
( cd "$WTB" && echo fix > fix.txt && git add fix.txt && git commit -qm "fix(qa): test fix" ) >/dev/null 2>&1
mark_terminal "$REPOB"
# Not harvested yet -> the old "harvest them first" advice stands.
OUTB=$( cd "$REPOB" && bash "$CLEAN" --purge 2>&1 )
case "$OUTB" in
  *"harvest them first"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: an unharvested branch must still say 'harvest them first' — got: $OUTB" >&2 ;;
esac

# Same repo, harvested this time: set up again, commit a fix, merge it, then purge.
WSC=$(mk_ws); track_ws "$WSC"
REPOC="$WSC/proj"; WTC="$WSC/proj-qa-loop"
( cd "$REPOC" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
( cd "$WTC" && echo fix > fix.txt && git add fix.txt && git commit -qm "fix(qa): test fix" ) >/dev/null 2>&1
mark_terminal "$REPOC"
( cd "$REPOC" && git merge -q --no-ff qa/loop-testing -m "harvest qa fixes" ) >/dev/null 2>&1
OUTC=$( cd "$REPOC" && bash "$CLEAN" --purge 2>&1 )
case "$OUTC" in
  *"harvest them first"*) FAIL=$((FAIL+1)); echo "  FAIL: a merged (harvested) branch must not tell the user to harvest again — got: $OUTC" >&2 ;;
  *"also reachable from"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: a merged branch should be reported as harvested — got: $OUTC" >&2 ;;
esac
if ( cd "$REPOC" && git rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 ); then
  PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: a harvested branch must still be KEPT — deleting commits stays the user's call" >&2; fi

# --- P. a branch PUSHED as a backup is not a harvest ---------------------------
# `for-each-ref --contains` lists the branch's own remote-tracking mirror, so
# `git push origin qa/loop-testing` with nothing merged read as "already reachable
# from 'origin/qa/loop-testing' — harvest looks complete", inviting the user to
# --discard-fixes a branch whose commits exist nowhere else.
WSE=$(mk_ws); track_ws "$WSE"
REPOE="$WSE/proj"; WTE="$WSE/proj-qa-loop"
git init -q --bare "$WSE/remote.git" >/dev/null 2>&1
( cd "$REPOE" && git remote add origin "$WSE/remote.git" && git push -q origin HEAD ) >/dev/null 2>&1
( cd "$REPOE" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
( cd "$WTE" && echo fix > fix.txt && git add fix.txt && git commit -qm "fix(qa): test fix" ) >/dev/null 2>&1
( cd "$REPOE" && git push -q origin qa/loop-testing ) >/dev/null 2>&1   # backup push, nothing merged
mark_terminal "$REPOE"
OUTE=$( cd "$REPOE" && bash "$CLEAN" --purge 2>&1 )
case "$OUTE" in
  *"also reachable"*) FAIL=$((FAIL+1)); echo "  FAIL: a backup push must not read as a completed harvest — got: $OUTE" >&2 ;;
  *"harvest them first"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: expected the unharvested advice — got: $OUTE" >&2 ;;
esac
if ( cd "$REPOE" && git rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 ); then
  PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: the branch must survive a backup-push purge" >&2; fi

# Excluding the mirror must not blind the genuine signal: with BOTH a backup push
# and a real merge into the mainline, purge still reports the harvest — naming the
# mainline, never the branch's own mirror.
WSF=$(mk_ws); track_ws "$WSF"
REPOF="$WSF/proj"; WTF="$WSF/proj-qa-loop"
git init -q --bare "$WSF/remote.git" >/dev/null 2>&1
( cd "$REPOF" && git remote add origin "$WSF/remote.git" && git push -q origin HEAD ) >/dev/null 2>&1
( cd "$REPOF" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
( cd "$WTF" && echo fix > fix.txt && git add fix.txt && git commit -qm "fix(qa): test fix" ) >/dev/null 2>&1
( cd "$REPOF" && git push -q origin qa/loop-testing ) >/dev/null 2>&1      # mirror exists
( cd "$REPOF" && git merge -q --no-ff qa/loop-testing -m "harvest qa fixes" ) >/dev/null 2>&1
MAINF="$(cd "$REPOF" && git branch --show-current)"
mark_terminal "$REPOF"
OUTF=$( cd "$REPOF" && bash "$CLEAN" --purge 2>&1 )
case "$OUTF" in
  *"also reachable from '$MAINF'"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: a merged branch must still read as harvested, naming $MAINF — got: $OUTF" >&2 ;;
esac

# --- Q. adoption must survive a SECOND rebuild ---------------------------------
# The rebuild reads the prior marker's CREATED_* to decide what to adopt. Once the
# first rebuild has written CREATED_BRANCH= (empty) + ADOPTED_BRANCH=…, a second
# clean → setup cycle finds nothing to carry and purge falls silent again — the
# exact "bare purge done. while fix commits sit on an unmentioned branch" this
# release set out to remove.
WSG=$(mk_ws); track_ws "$WSG"
REPOG="$WSG/proj"; WTG="$WSG/proj-qa-loop"
( cd "$REPOG" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
( cd "$WTG" && echo fix > fix.txt && git add fix.txt && git commit -qm "fix(qa): test fix" ) >/dev/null 2>&1
( cd "$REPOG" && bash "$CLEAN" ) >/dev/null 2>&1
( cd "$REPOG" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1        # rebuild 1 -> adopted
( cd "$REPOG" && bash "$CLEAN" ) >/dev/null 2>&1
( cd "$REPOG" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1        # rebuild 2
assert_file_contains "$REPOG/docs/looptesting/.sandbox/ownership.env" "ADOPTED_BRANCH=qa/loop-testing" \
  "adoption carries across a second rebuild"
mark_terminal "$REPOG"
OUTG=$( cd "$REPOG" && bash "$CLEAN" --purge 2>&1 )
case "$OUTG" in
  *"qa/loop-testing"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: purge went silent after a second rebuild — got: $OUTG" >&2 ;;
esac
if ( cd "$REPOG" && git rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 ); then
  PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: the branch must survive purge after a second rebuild" >&2; fi

report "purge.test.sh"
