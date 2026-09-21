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

# Every workspace registers itself the moment it is created, and the EXIT trap
# removes whatever is registered. The previous form re-declared the trap at each
# creation with a literal list of every variable so far, which is a list that has
# to be right every time it is retyped — and at the last one it was not: it read
# `"$WS" "$WS8"`, so the six workspaces in between were never removed and every
# run of this suite left six directories in $TMPDIR (audit T-10). Registering at
# creation cannot skip an entry, because there is no list to retype.
#
# Word-split on purpose, like the other suites here; mk_ws paths contain no
# whitespace unless $TMPDIR does.
WS_ALL=()
track_ws() { WS_ALL+=("$1"); }
cleanup_all() { if [ "${#WS_ALL[@]}" -gt 0 ]; then rm -rf -- "${WS_ALL[@]}"; fi; }
trap cleanup_all EXIT

# --- A. tag re-pointed by the user within the lifecycle: KEPT, named ----------
WS=$(mk_ws); track_ws "$WS"
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
# A kept ref KEEPS the marker. This assertion used to read `assert_absent` — it
# encoded the defect: purge named a recovery route ("remove it by hand", or
# `--purge --discard-fixes`) in the same breath as deleting the only file that
# route needs, so the follow-up answered exit 3. Two stages each learned to stop
# short; only the leftover-files one was protecting the marker.
assert_exists "$REPO/docs/looptesting/.sandbox/ownership.env" "a kept ref keeps the marker its own recovery route needs"
case "$OUT" in
  *"kept evidence dir"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: purge must say why it kept the evidence dir — got: $OUT" >&2 ;;
esac
# ...and the route works: drop the user's tag, purge again, everything goes.
( cd "$REPO" && git tag -d qa-baseline ) >/dev/null 2>&1
OUT_A2=$( cd "$REPO" && bash "$CLEAN" --purge 2>&1 ); rc_a2=$?
assert_eq "0" "$rc_a2" "after the kept ref is gone, a second purge completes"
assert_absent "$REPO/docs/looptesting" "the second purge removes the evidence dir"

# --- B. same-named user branch at a baseline ANCESTOR: KEPT ------------------
# rev-list --count BASE..branch is 0 for an ancestor, which the old code read as
# "no fix commits, safe to delete".
WS2=$(mk_ws); track_ws "$WS2"
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
WS3=$(mk_ws); track_ws "$WS3"
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
WS4=$(mk_ws); track_ws "$WS4"
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
WS5=$(mk_ws); track_ws "$WS5"
REPO5="$WS5/proj"; WT5="$WS5/proj-qa-loop"
( cd "$REPO5" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
( cd "$WT5" && echo fix > fix.txt && git add fix.txt && git commit -qm "fix(qa): test fix" ) >/dev/null 2>&1
mark_terminal "$REPO5"
( cd "$REPO5" && bash "$CLEAN" --purge --discard-fixes ) >/dev/null 2>&1
assert_eq "0" "$?" "control --discard-fixes exits 0"
if branch_exists "$REPO5"; then FAIL=$((FAIL+1)); echo "  FAIL: control — our branch with fixes must be deleted under --discard-fixes" >&2
else PASS=$((PASS+1)); fi

# --- F. marker with no BASELINE_HEAD: nothing can be identified -> both kept ---
WS6=$(mk_ws); track_ws "$WS6"
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

# --- G. an ANNOTATED tag at the baseline is not ours --------------------------
# `rev-parse refs/tags/X^{commit}` peels an annotated tag to the commit it points
# at, so a user's annotated qa-baseline sitting on the recorded commit satisfied
# a commit-only identity check. sandbox-setup only ever writes a LIGHTWEIGHT tag
# (`git tag <name>`, no -a/-m/-s), so an annotated object of that name was made by
# someone else — the tag object itself is the evidence, and it carries the user's
# message and signature.
WS7=$(mk_ws); track_ws "$WS7"
REPO7="$WS7/proj"
( cd "$REPO7" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup (annotated-tag case)"
# Replace the sandbox's lightweight tag with the user's annotated one, same name,
# same commit — identical to a commit-only check, distinguishable by object type.
( cd "$REPO7" && git tag -d qa-baseline && git tag -a qa-baseline -m "my release baseline" ) >/dev/null 2>&1
assert_eq "tag" "$(cd "$REPO7" && git cat-file -t refs/tags/qa-baseline)" "fixture: the tag really is annotated"
mark_terminal "$REPO7"
OUT7=$( cd "$REPO7" && bash "$CLEAN" --purge 2>&1 )
assert_eq "0" "$?" "purge over an annotated same-name tag exits 0"
if tag_exists "$REPO7"; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: purge deleted a user's ANNOTATED tag at the baseline commit (data loss)" >&2; fi
assert_eq "my release baseline" "$(cd "$REPO7" && git tag -l --format='%(contents:subject)' qa-baseline 2>/dev/null)" "the annotated tag's own object survived intact"
case "$OUT7" in
  *"kept tag qa-baseline"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: purge must say it kept the annotated tag — got: $OUT7" >&2 ;;
esac
case "$OUT7" in
  *"deleted baseline tag"*) FAIL=$((FAIL+1)); echo "  FAIL: purge claimed to delete a tag it kept — got: $OUT7" >&2 ;;
  *) PASS=$((PASS+1)) ;;
esac

# --- H. the headline path: a branch holding fix commits ----------------------
# This is what a successful QA loop leaves behind — it fixed something, so the qa
# branch has commits the user has not harvested. Purge keeps the branch and tells
# them to re-run with --discard-fixes once they have. That follow-up reads the
# marker, so deleting the marker here breaks the only documented route out
# (README cleanup section) on the tool's NORMAL successful outcome.
WS8=$(mk_ws); track_ws "$WS8"
REPO8="$WS8/proj"
( cd "$REPO8" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup (fix-commits case)"
QA_WT8="$(cd "$REPO8" && git worktree list --porcelain \
  | awk '/^worktree /{p=$2} /^branch refs\/heads\/qa\/loop-testing/{print p}')"
( cd "$QA_WT8" && echo fix > fix.txt && git add -A && git commit -qm "fix: a real one" ) >/dev/null 2>&1
assert_ok $? "the qa branch holds a fix commit"
mark_terminal "$REPO8"
OUT8=$( cd "$REPO8" && bash "$CLEAN" --purge 2>&1 ); rc8=$?
assert_eq "0" "$rc8" "purge with unharvested fix commits exits 0 (documented happy route)"
if branch_exists "$REPO8"; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: purge deleted a branch holding unharvested fix commits" >&2; fi
case "$OUT8" in
  *"--discard-fixes"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: purge must name the --discard-fixes follow-up — got: $OUT8" >&2 ;;
esac
assert_exists "$REPO8/docs/looptesting/.sandbox/ownership.env" \
  "the marker that follow-up needs survives the run that recommends it"
# The follow-up must actually work. This is the assertion that would have caught
# the defect: exit 3 here means the tool destroyed the route it just named.
OUT9=$( cd "$REPO8" && bash "$CLEAN" --purge --discard-fixes 2>&1 ); rc9=$?
assert_eq "0" "$rc9" "--purge --discard-fixes completes after the run that recommended it"
case "$OUT9" in
  *"no ownership marker"*) FAIL=$((FAIL+1)); echo "  FAIL: the follow-up hit fail-closed exit 3 — the marker was orphaned: $OUT9" >&2 ;;
  *) PASS=$((PASS+1)) ;;
esac
if branch_exists "$REPO8"; then
  FAIL=$((FAIL+1)); echo "  FAIL: --discard-fixes did not drop the branch" >&2; else PASS=$((PASS+1)); fi
assert_absent "$REPO8/docs/looptesting" "and the evidence dir goes with it"

report "purge-ref-identity.test.sh"
