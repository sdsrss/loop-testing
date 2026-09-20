#!/usr/bin/env bash
# sandbox-clean.sh --purge (audit S-03): the baseline tag and the qa branch are
# deleted by IDENTITY, not by name. The marker records BASELINE_HEAD; purge used to
# read it and then `git tag -d "$P_TAG"` on nothing more than "a tag of that name
# exists" — so a user who re-tagged qa-baseline within the same lifecycle lost
# their tag, and a same-named user branch pointing at a baseline ANCESTOR counted
# as "0 fix commits" and was deleted.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

mark_terminal() { sed -i.bak 's/^status: RUNNING/status: CONVERGED/' "$1/docs/looptesting/STATE.md"; rm -f "$1/docs/looptesting/STATE.md.bak"; }
tag_exists()    { ( cd "$1" && git rev-parse -q --verify refs/tags/qa-baseline >/dev/null 2>&1 ); }
branch_exists() { ( cd "$1" && git rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 ); }

# --- A. tag re-pointed by the user within the lifecycle: KEPT, named ----------
WS=$(mk_ws); trap 'rm -rf "$WS"' EXIT
REPO="$WS/proj"
( cd "$REPO" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup (tag case)"
( cd "$REPO" && echo b >> README.md && git commit -qam second && git tag -f qa-baseline HEAD ) >/dev/null 2>&1
USER_TAG="$(cd "$REPO" && git rev-parse refs/tags/qa-baseline)"
mark_terminal "$REPO"
OUT=$( cd "$REPO" && bash "$CLEAN" --purge 2>&1 ); rc=$?
assert_eq "0" "$rc" "purge over a re-pointed tag still exits 0 (the tag is not an error, it is not ours)"
if tag_exists "$REPO"; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: purge deleted a tag the user re-pointed (S-03 data loss)" >&2; fi
assert_eq "$USER_TAG" "$(cd "$REPO" && git rev-parse -q --verify refs/tags/qa-baseline 2>/dev/null)" "the user's tag target is untouched"
case "$OUT" in
  *"kept tag qa-baseline"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: purge must SAY it kept the tag — got: $OUT" >&2 ;;
esac
case "$OUT" in
  *"deleted baseline tag"*) FAIL=$((FAIL+1)); echo "  FAIL: purge claimed to delete a tag it kept — got: $OUT" >&2 ;;
  *) PASS=$((PASS+1)) ;;
esac
assert_absent "$REPO/docs/looptesting" "the rest of the purge (evidence dir) still completes"

# --- B. same-named user branch at a baseline ANCESTOR: KEPT ------------------
# rev-list --count BASE..branch is 0 for an ancestor, which the old code read as
# "no fix commits, safe to delete".
WS2=$(mk_ws); trap 'rm -rf "$WS" "$WS2"' EXIT
REPO2="$WS2/proj"; WT2="$WS2/proj-qa-loop"
( cd "$REPO2" && echo b >> README.md && git commit -qam second ) >/dev/null 2>&1
( cd "$REPO2" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup (branch case)"
( cd "$REPO2" && git worktree remove --force "$WT2" && git branch -D qa/loop-testing && git branch qa/loop-testing HEAD~1 ) >/dev/null 2>&1
USER_BR="$(cd "$REPO2" && git rev-parse refs/heads/qa/loop-testing)"
mark_terminal "$REPO2"
OUT2=$( cd "$REPO2" && bash "$CLEAN" --purge 2>&1 ); rc=$?
assert_eq "0" "$rc" "purge over a replaced branch exits 0"
if branch_exists "$REPO2"; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: purge deleted a same-named branch that does not descend from the baseline (S-03 data loss)" >&2; fi
assert_eq "$USER_BR" "$(cd "$REPO2" && git rev-parse -q --verify refs/heads/qa/loop-testing 2>/dev/null)" "the user's branch tip is untouched"
case "$OUT2" in
  *"KEPT branch: qa/loop-testing"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: purge must name the branch it kept — got: $OUT2" >&2 ;;
esac

# --- C. --discard-fixes does not override identity ----------------------------
# Waiving fix commits is a statement about OUR branch's commits; it is not a
# licence to delete a branch that is not ours.
WS3=$(mk_ws); trap 'rm -rf "$WS" "$WS2" "$WS3"' EXIT
REPO3="$WS3/proj"; WT3="$WS3/proj-qa-loop"
( cd "$REPO3" && echo b >> README.md && git commit -qam second ) >/dev/null 2>&1
( cd "$REPO3" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
( cd "$REPO3" && git worktree remove --force "$WT3" && git branch -D qa/loop-testing && git branch qa/loop-testing HEAD~1 ) >/dev/null 2>&1
mark_terminal "$REPO3"
( cd "$REPO3" && bash "$CLEAN" --purge --discard-fixes ) >/dev/null 2>&1
assert_eq "0" "$?" "--purge --discard-fixes over a replaced branch exits 0"
if branch_exists "$REPO3"; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: --discard-fixes must not delete a branch that is not this sandbox's" >&2; fi

# --- D. control: untouched tag + fix-less branch are still deleted ------------
# Identity checks must not turn the normal purge into a keep-everything.
WS4=$(mk_ws); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4"' EXIT
REPO4="$WS4/proj"
( cd "$REPO4" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
mark_terminal "$REPO4"
OUT4=$( cd "$REPO4" && bash "$CLEAN" --purge 2>&1 )
assert_eq "0" "$?" "control purge exits 0"
if tag_exists "$REPO4"; then FAIL=$((FAIL+1)); echo "  FAIL: control — the tag we created at the recorded baseline must still be deleted" >&2
else PASS=$((PASS+1)); fi
if branch_exists "$REPO4"; then FAIL=$((FAIL+1)); echo "  FAIL: control — a fix-less branch at the recorded baseline must still be deleted" >&2
else PASS=$((PASS+1)); fi
case "$OUT4" in *"deleted baseline tag qa-baseline"*"deleted branch qa/loop-testing"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: control — expected both deletions reported — got: $OUT4" >&2 ;; esac

# --- E. control: a branch WITH fix commits (descends from baseline) is still
# deleted under --discard-fixes — identity holds, the waiver applies.
WS5=$(mk_ws); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5"' EXIT
REPO5="$WS5/proj"; WT5="$WS5/proj-qa-loop"
( cd "$REPO5" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
( cd "$WT5" && echo fix > fix.txt && git add fix.txt && git commit -qm "fix(qa): test fix" ) >/dev/null 2>&1
mark_terminal "$REPO5"
( cd "$REPO5" && bash "$CLEAN" --purge --discard-fixes ) >/dev/null 2>&1
assert_eq "0" "$?" "control --discard-fixes exits 0"
if branch_exists "$REPO5"; then FAIL=$((FAIL+1)); echo "  FAIL: control — our branch with fixes must be deleted under --discard-fixes" >&2
else PASS=$((PASS+1)); fi

# --- F. marker with no BASELINE_HEAD: nothing can be identified -> both kept ---
WS6=$(mk_ws); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6"' EXIT
REPO6="$WS6/proj"
( cd "$REPO6" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
sed -i.bak '/^BASELINE_HEAD=/d' "$REPO6/docs/looptesting/.sandbox/ownership.env"; rm -f "$REPO6/docs/looptesting/.sandbox/ownership.env.bak"
mark_terminal "$REPO6"
OUT6=$( cd "$REPO6" && bash "$CLEAN" --purge --discard-fixes 2>&1 )
assert_eq "0" "$?" "purge without a recorded baseline exits 0"
if tag_exists "$REPO6"; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: with no recorded baseline the tag cannot be identified and must be kept" >&2; fi
if branch_exists "$REPO6"; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: with no recorded baseline the branch cannot be identified and must be kept, even under --discard-fixes" >&2; fi
case "$OUT6" in *"kept tag qa-baseline"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: purge must say why the tag was kept — got: $OUT6" >&2 ;; esac

report "purge-ref-identity.test.sh"
