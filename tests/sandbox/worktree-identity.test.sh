#!/usr/bin/env bash
# Worktree ownership must be claimed by IDENTITY (the recorded sandbox branch),
# not by path alone.
#
# The marker records CREATED_WORKTREE=<path>, and both scripts only ask "is
# *something* registered at that path?". After a clean the path is free, so a
# user who reuses it — plausible when they passed --worktree-path pointing at
# their usual scratch location — gets:
#   * setup reporting "already initialized" over THEIR worktree, so the loop runs
#     and commits onto THEIR branch, with no isolation at all (the audit-B2
#     phantom-isolation class, fixed for the missing-worktree case but not for
#     the replaced one); and
#   * clean force-deleting that worktree, taking uncommitted and untracked work
#     with it.
#
# sandbox-setup.sh's own comment asserted "Worktree mode needs no check — its
# isolation is the worktree itself, verified above", which is the assumption
# under test: what was verified above is the path, not the isolation.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WS_ALL=()
track_ws() { WS_ALL+=("$1"); }
cleanup_all() { if [ "${#WS_ALL[@]}" -gt 0 ]; then rm -rf -- "${WS_ALL[@]}"; fi; }
trap cleanup_all EXIT

# A repo whose sandbox was set up at a user-chosen worktree path and then
# cleaned, leaving the path free and the marker still recording it.
# Sets FOREIGN_WS rather than echoing it — see the NEW_WS note in
# purge-adopted-dir.test.sh: a $( ) caller would lose the WS_ALL registration to
# the subshell and the EXIT trap would leak every fixture.
FOREIGN_WS=""
foreign_worktree_repo() {   # user worktree left standing at $FOREIGN_WS/shared-wt
  local ws
  ws=$(mk_ws); track_ws "$ws"
  ( cd "$ws/proj" && bash "$SETUP" --mode worktree --worktree-path "$ws/shared-wt" ) >/dev/null 2>&1 || return 1
  ( cd "$ws/proj" && bash "$CLEAN" ) >/dev/null 2>&1 || return 1
  ( cd "$ws/proj" && git worktree add -q -b my-feature "$ws/shared-wt" ) >/dev/null 2>&1 || return 1
  echo "my uncommitted feature work" > "$ws/shared-wt/feature.txt"
  FOREIGN_WS="$ws"
}

# --- case 1: clean must not force-delete a worktree that is not the sandbox's --
foreign_worktree_repo; assert_ok $? "fixture: user worktree standing at the recorded path"; WS="$FOREIGN_WS"
( cd "$WS/proj" && bash "$CLEAN" ) > "$WS/clean.out" 2>&1
assert_ok $? "clean still exits 0 with a foreign worktree at the recorded path"
assert_exists "$WS/shared-wt" "the user's worktree is NOT removed"
assert_exists "$WS/shared-wt/feature.txt" "the user's untracked work survives"
assert_file_contains "$WS/clean.out" "not this sandbox's" "clean says why it left the worktree alone"
if ( cd "$WS/proj" && git worktree list --porcelain | grep -qxF "worktree $WS/shared-wt" ); then
  PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: the user's worktree was deregistered" >&2; fi

# --- case 2: setup must not hand back "already initialized" over that worktree -
foreign_worktree_repo; assert_ok $? "fixture 2: user worktree standing at the recorded path"; WS2="$FOREIGN_WS"
( cd "$WS2/proj" && bash "$SETUP" --mode worktree --worktree-path "$WS2/shared-wt" ) > "$WS2/setup.out" 2>&1
setup_rc=$?
assert_eq "6" "$setup_rc" "setup refuses a foreign worktree with the documented exit 6, not merely non-zero"
if grep -qF "already initialized" "$WS2/setup.out"; then
  FAIL=$((FAIL+1)); echo "  FAIL: setup called a foreign worktree an initialized sandbox" >&2
else PASS=$((PASS+1)); fi
assert_file_contains "$WS2/setup.out" "not this sandbox's" "setup says why it will not adopt that worktree"
# and it must point at something that actually works (see case 8)
assert_file_contains "$WS2/setup.out" "--worktree-path" "setup names a route out"
# and it must not have quietly left the user's tree looking like a sandbox
if ( cd "$WS2/shared-wt" && [ "$(git branch --show-current)" = "my-feature" ] ); then
  PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: the user's worktree no longer sits on their branch" >&2; fi

# --- case 3 (mutation guard): the sandbox's OWN worktree is still cleaned -----
# A fix that simply stopped removing worktrees would pass cases 1-2 and break the
# actual job. Same for setup: a live, genuine sandbox must still short-circuit.
WS3=$(mk_ws); track_ws "$WS3"
( cd "$WS3/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "genuine sandbox setup"
( cd "$WS3/proj" && bash "$SETUP" --mode worktree ) > "$WS3/setup2.out" 2>&1
assert_ok $? "a live genuine sandbox still short-circuits"
assert_file_contains "$WS3/setup2.out" "already initialized" "genuine re-setup still reports already initialized"
( cd "$WS3/proj" && bash "$CLEAN" ) >/dev/null 2>&1
assert_ok $? "clean of a genuine sandbox exits 0"
assert_absent "$WS3/proj-qa-loop" "the sandbox's own worktree is still removed"

# --- case 4: a legacy marker with no recorded branch keeps working ------------
# Mirrors the branch-mode precedent: with no SANDBOX_BRANCH recorded the
# sandbox's identity is unknown, so guessing and refusing would break a valid
# custom-branch sandbox. Unknown identity must not become a new refusal.
WS4=$(mk_ws); track_ws "$WS4"
( cd "$WS4/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup for the legacy-marker case"
MK="$WS4/proj/docs/looptesting/.sandbox/ownership.env"
grep -v '^SANDBOX_BRANCH=' "$MK" > "$MK.tmp" && mv "$MK.tmp" "$MK"
( cd "$WS4/proj" && bash "$CLEAN" ) > "$WS4/clean4.out" 2>&1
assert_ok $? "clean of a legacy marker exits 0"
assert_absent "$WS4/proj-qa-loop" "legacy marker (no recorded branch) still cleans its worktree"

# --- case 5: OUR OWN worktree with a detached HEAD is still ours --------------
# A conflicted rebase, a `git bisect`, or a plain `git checkout <sha>` inside the
# sandbox detaches HEAD. Identity must not be "the branch name matches" — our own
# worktree stops matching that the moment the loop rebases, and abandoning it
# leaves an orphan the tool can no longer clean up.
WS5=$(mk_ws); track_ws "$WS5"; WT5="$WS5/proj-qa-loop"
( cd "$WS5/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup for the detached-HEAD case"
( cd "$WT5" && git checkout -q --detach HEAD )
( cd "$WS5/proj" && bash "$SETUP" --mode worktree ) > "$WS5/setup.out" 2>&1
assert_ok $? "setup resumes over our own detached worktree"
assert_file_contains "$WS5/setup.out" "already initialized" "a detached sandbox still short-circuits"
( cd "$WS5/proj" && bash "$CLEAN" ) >/dev/null 2>&1
assert_absent "$WT5" "clean removes our own worktree even when its HEAD is detached"

# --- case 6: OUR OWN worktree whose branch was renamed is still ours ----------
WS6=$(mk_ws); track_ws "$WS6"; WT6="$WS6/proj-qa-loop"
( cd "$WS6/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup for the renamed-branch case"
( cd "$WS6/proj" && git branch -m qa/loop-testing qa/renamed )
( cd "$WS6/proj" && bash "$CLEAN" ) >/dev/null 2>&1
assert_absent "$WT6" "clean removes our own worktree after its branch was renamed"

# --- case 8: the refusal has a working way out -------------------------------
# A dead end is not a safety feature: pointing the user at --worktree-path only
# helps if passing it actually builds the sandbox somewhere else.
foreign_worktree_repo; assert_ok $? "fixture: foreign worktree for the recovery route"; WS8="$FOREIGN_WS"
( cd "$WS8/proj" && bash "$SETUP" --mode worktree --worktree-path "$WS8/elsewhere" ) > "$WS8/setup.out" 2>&1
assert_ok $? "setup recovers when told to use another worktree path"
assert_exists "$WS8/elsewhere" "the sandbox was rebuilt at the requested path"
assert_exists "$WS8/shared-wt/feature.txt" "the user's worktree was left untouched by the recovery"
if ( cd "$WS8/shared-wt" && [ "$(git branch --show-current)" = "my-feature" ] ); then
  PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: the user's worktree left its branch during recovery" >&2; fi

# --- case 9: a marker with no recorded stamp carries no permission ------------
# Sandboxes created before stamping have no identity to check, and the pre-fix
# behavior was to force-remove anything standing at the recorded path. That is
# the original data-loss bug, still armed for every install that already exists —
# so "no identity recorded" must mean "do not touch", not "assume it is ours".
# The cost is one manual step per pre-existing sandbox; after it the rebuilt
# marker carries a stamp and the sandbox behaves normally forever.
WS9=$(mk_ws); track_ws "$WS9"; WT9="$WS9/proj-qa-loop"
( cd "$WS9/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup for the legacy-stamp case"
MK9="$WS9/proj/docs/looptesting/.sandbox/ownership.env"
grep -v '^WORKTREE_STAMP=' "$MK9" > "$MK9.tmp" && mv "$MK9.tmp" "$MK9"
GD9=$( cd "$WT9" && git rev-parse --absolute-git-dir 2>/dev/null )
rm -f "$GD9/loop-testing-owner"
# the user's own work, standing where a pre-stamp marker points
echo "work that predates the upgrade" > "$WT9/user-untracked.txt"

( cd "$WS9/proj" && bash "$CLEAN" ) > "$WS9/clean.out" 2>&1
assert_ok $? "clean over a legacy marker exits 0"
assert_exists "$WT9" "clean does not force-remove a worktree it cannot identify"
assert_exists "$WT9/user-untracked.txt" "untracked work at that path survives"
assert_file_contains "$WS9/clean.out" "git worktree remove" "clean names the exact manual command"
# ...and the command it names must be the one that REFUSES when there is work to
# lose. `legacy` is `unknown`'s situation, not `foreign`'s: the stamp was never
# written, so there is no identity to read and this run cannot say whose work is
# in there. Both of those arms stopped handing over a paste-ready --force (cases
# 32 and 34); this one kept doing it, with "check it first" written next to the
# command that skips the check. Plain `git worktree remove` succeeds on a clean
# worktree and refuses on this one — the fixture above put untracked work there
# on purpose — so git performs the check instead of asking for it.
# `--` because the needle begins with a dash.
if grep -qF -- "worktree remove --force" "$WS9/clean.out"; then
  FAIL=$((FAIL+1))
  echo "  FAIL: clean handed the user --force for a worktree it had just said it could not identify" >&2
else PASS=$((PASS+1)); fi
assert_file_contains "$WS9/clean.out" "only refuses over" \
  "clean states the LIMIT of git's refusal rather than selling it as a blanket check"

# --- case 9b: the refusal that advice leaned on does not cover ignored files --
# Case 9's fixture holds UNTRACKED work, and git does refuse over that. A
# finished loop sandbox does not look like that: round-N commits its fixes, so
# what remains is build output, .env and logs — matched by the project's own
# .gitignore, invisible to `git status --porcelain`, and not enough to make
# `git worktree remove` refuse anything. The advice told the user that refusal
# was their check. In the state a finished sandbox is actually in, there is no
# refusal to read, and following the advice destroys the lot at exit 0.
WS9B=$(mk_ws); track_ws "$WS9B"; WT9B="$WS9B/proj-qa-loop"
printf 'node_modules/\n.env\n*.log\n' >> "$WS9B/proj/.gitignore"
( cd "$WS9B/proj" && git add .gitignore && git commit -qm 'ignore build output' ) >/dev/null 2>&1
( cd "$WS9B/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup for the ignored-only case"
MK9B="$WS9B/proj/docs/looptesting/.sandbox/ownership.env"
grep -v '^WORKTREE_STAMP=' "$MK9B" > "$MK9B.tmp" && mv "$MK9B.tmp" "$MK9B"
GD9B=$( cd "$WT9B" && git rev-parse --absolute-git-dir 2>/dev/null )
rm -f "$GD9B/loop-testing-owner"
printf 'API_KEY=local-dev-secret\n' > "$WT9B/.env"
mkdir -p "$WT9B/node_modules" && echo x > "$WT9B/node_modules/p.js"
echo y > "$WT9B/server.log"
# Fixture self-probe, and it needs both halves: git must call this worktree
# CLEAN while the files are demonstrably in it. Either half alone would let the
# case pass over a fixture that never reached the state it is about.
if [ -z "$( cd "$WT9B" && git status --porcelain )" ] \
   && [ "$( cd "$WT9B" && git status --porcelain --ignored 2>/dev/null | grep -c '^!!' )" -ge 2 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); echo "  FAIL: fixture: worktree must look clean to git while holding ignored files" >&2
fi
( cd "$WS9B/proj" && bash "$CLEAN" ) > "$WS9B/clean.out" 2>&1
assert_ok $? "clean over a legacy marker with ignored-only content exits 0"
assert_exists "$WT9B" "clean itself still leaves the worktree alone"
assert_file_contains "$WS9B/clean.out" "--ignored -uall" \
  "the advice names an inspection that lists ignored files one by one"
# Pin why `-uall` is in that command, the same way the rc-0 assertion below pins
# why the advice cannot lean on a refusal (delta review D6): `--ignored` alone
# reports an ignored DIRECTORY as one collapsed entry and never names the file
# inside it, which for this tool is exactly the `.env` the case is about.
mkdir -p "$WT9B/cfgdir" && printf 'API_KEY=inside-an-ignored-dir\n' > "$WT9B/cfgdir/.env"
printf 'cfgdir/\n' >> "$WS9B/proj/.gitignore"
( cd "$WS9B/proj" && git add .gitignore && git commit -qm 'ignore cfgdir' ) >/dev/null 2>&1
n_plain=$( cd "$WT9B" && git status --porcelain --ignored 2>/dev/null | grep -c 'cfgdir/\.env' )
n_uall=$( cd "$WT9B" && git status --porcelain --ignored -uall 2>/dev/null | grep -c 'cfgdir/\.env' )
if [ "$n_plain" -eq 0 ] && [ "$n_uall" -ge 1 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "  FAIL: the premise for -uall no longer holds — plain=$n_plain uall=$n_uall (expected 0 and >=1)" >&2
fi
if grep -qF "that refusal is the check" "$WS9B/clean.out"; then
  FAIL=$((FAIL+1))
  echo "  FAIL: the advice still sells git's refusal as the check, in the state where git does not refuse" >&2
else PASS=$((PASS+1)); fi
# Pin git's real behaviour here, so this advice can never again be written
# against a premise nobody measured. This removal is the LAST thing case 9b
# does — it consumes the fixture.
( cd "$WS9B/proj" && git worktree remove "$WT9B" ) >/dev/null 2>&1
assert_eq 0 "$?" "git does NOT refuse a worktree whose only content is ignored"
assert_absent "$WT9B" "…it is taken silently, .env and all"

# Resuming is NOT the destructive half. Adopting a worktree to continue a run is
# reversible — at worst QA commits land on a branch and can be undone — while a
# force-remove is not. Refusing to resume would break every sandbox that already
# exists, and an unattended run would report BLOCKED on the isolation gate; the
# protection that matters is clean's, above.
( cd "$WS9/proj" && bash "$SETUP" --mode worktree ) > "$WS9/setup.out" 2>&1
assert_ok $? "an existing pre-stamp sandbox still resumes"
assert_file_contains "$WS9/setup.out" "already initialized" "resume is unchanged for pre-stamp sandboxes"
assert_exists "$WT9/user-untracked.txt" "resuming touched nothing in that worktree"

# The route clean names still works, and rebuilding upgrades the sandbox to a
# stamped marker so the next teardown needs no manual step.
( cd "$WS9/proj" && git worktree remove --force "$WT9" ) >/dev/null 2>&1
( cd "$WS9/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup rebuilds once that worktree is dealt with"
if grep -qE '^WORKTREE_STAMP=.+' "$MK9"; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: the rebuilt sandbox carries no identity" >&2; fi

# --- case 10: purge must not delete the only record of a worktree it kept ----
# The worktree stage decides to leave a worktree standing; the purge stage then
# rm -rf's the evidence dir, marker included. What is left is a registered
# worktree with nothing on disk tying it to this tool — unclaimable by a later
# clean and invisible to purge, i.e. exactly the orphan the fail-closed design
# exists to prevent.
foreign_worktree_repo; assert_ok $? "fixture: worktree purge cannot claim"; WS10="$FOREIGN_WS"
sed -i.bak 's/^status: .*/status: CONVERGED/' "$WS10/proj/docs/looptesting/STATE.md"
rm -f "$WS10/proj/docs/looptesting/STATE.md.bak"
( cd "$WS10/proj" && bash "$CLEAN" --purge ) > "$WS10/purge.out" 2>&1
purge10_rc=$?
# A run that deleted the baseline tag and then stopped short is not a success.
assert_eq "4" "$purge10_rc" "purge that stopped short exits 4, not 0"
assert_file_contains "$WS10/purge.out" "purge incomplete" "and says so"
assert_exists "$WS10/proj/docs/looptesting/.sandbox/ownership.env" \
  "the marker identifying the kept worktree survives purge"
assert_file_contains "$WS10/purge.out" "still registered" "purge says why it kept the evidence dir"
assert_exists "$WS10/shared-wt/feature.txt" "the user's worktree and its work are untouched"

# --- case 11: a registration whose directory is gone has nothing to protect ---
# git keeps the worktree registered after the user deletes the folder. That is the
# one case where ownership is not in doubt for the reason that matters: there is
# nothing on disk to lose. Calling it "cannot tell, keep it" strands a phantom
# registration, and the next setup then fails because the branch is still held.
WS11=$(mk_ws); track_ws "$WS11"; WT11="$WS11/proj-qa-loop"
( cd "$WS11/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup for the deleted-directory case"
rm -rf "${WT11:?}"
( cd "$WS11/proj" && bash "$CLEAN" ) > "$WS11/clean.out" 2>&1
assert_ok $? "clean exits 0 when the worktree directory was deleted"
if ( cd "$WS11/proj" && git worktree list --porcelain | grep -qxF "worktree $WT11" ); then
  FAIL=$((FAIL+1)); echo "  FAIL: a phantom worktree registration survived clean" >&2
else PASS=$((PASS+1)); fi
( cd "$WS11/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup works again after the phantom registration is cleared"

# --- case 12: no external text tool may sit in the ownership decision ---------
# This replaces an earlier awk-only version of the same test, which stopped
# being able to fail once awk left the decision path. The property is not
# "awk is not used" but "no external text tool decides ownership".
# The first version of this check parsed `git worktree list` with awk, so a
# missing awk read as "not ours". Replacing awk with `cat` moved the same hole
# rather than closing it: any external command in this path can fail and be
# mistaken for a verdict.
WS12=$(mk_ws); track_ws "$WS12"; WT12="$WS12/proj-qa-loop"
( cd "$WS12/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup for the broken-cat case"
mkdir -p "$WS12/bin"
# Only the two tools that have actually sat in this decision. grep/head/cut are
# deliberately left working: they parse the ownership marker, and their failure
# degrades to "no marker", which is clean's documented fail-closed path — a
# different mechanism with a different, already-safe answer.
for t in cat awk; do printf '#!/bin/sh\nexit 127\n' > "$WS12/bin/$t"; chmod +x "$WS12/bin/$t"; done
( cd "$WS12/proj" && PATH="$WS12/bin:$PATH" bash "$CLEAN" ) > "$WS12/clean.out" 2>&1
assert_ok $? "clean exits 0 with cat and awk broken"
assert_absent "$WT12" "clean still removes its own worktree with cat and awk broken"

# --- case 13: a relative --worktree-path must not blind every later lookup ----
# `git worktree list --porcelain` prints absolute paths. Recording the flag
# verbatim means every membership test misses, so the sandbox's own live worktree
# reads as `absent`: clean reports "already gone" and silently leaks it, and the
# marker points at a path that resolves differently depending on cwd.
WS13=$(mk_ws); track_ws "$WS13"
( cd "$WS13/proj" && bash "$SETUP" --mode worktree --worktree-path ../rel-wt ) >/dev/null 2>&1
assert_ok $? "setup accepts a relative --worktree-path"
assert_exists "$WS13/rel-wt" "the worktree was created where the relative path points"
MK13="$WS13/proj/docs/looptesting/.sandbox/ownership.env"
if grep -qE '^CREATED_WORKTREE=/' "$MK13"; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: the marker recorded a non-absolute worktree path" >&2
  grep '^CREATED_WORKTREE=' "$MK13" >&2; fi
( cd "$WS13/proj" && bash "$CLEAN" ) > "$WS13/clean.out" 2>&1
assert_ok $? "clean over a relative-path sandbox exits 0"
assert_absent "$WS13/rel-wt" "clean removes the worktree it created via a relative path"
if grep -qF "already gone" "$WS13/clean.out"; then
  FAIL=$((FAIL+1)); echo "  FAIL: clean claimed the live worktree was already gone" >&2
else PASS=$((PASS+1)); fi

# --- case 14: a malformed SANDBOX_VERSION must not leak shell noise -----------
WS14=$(mk_ws); track_ws "$WS14"
( cd "$WS14/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
MK14="$WS14/proj/docs/looptesting/.sandbox/ownership.env"
sed -e 's/^SANDBOX_VERSION=.*/SANDBOX_VERSION=99999999999999999999999999/' "$MK14" > "$MK14.tmp"
mv "$MK14.tmp" "$MK14"
sed -i.bak 's/^status: .*/status: CONVERGED/' "$WS14/proj/docs/looptesting/STATE.md"
rm -f "$WS14/proj/docs/looptesting/STATE.md.bak"
( cd "$WS14/proj" && bash "$CLEAN" --purge ) > "$WS14/purge.out" 2>&1
assert_ok $? "purge survives an absurd SANDBOX_VERSION"
if grep -qiE 'integer expression|out of range|syntax error|line [0-9]+:' "$WS14/purge.out"; then
  FAIL=$((FAIL+1)); echo "  FAIL: raw shell error leaked to the user" >&2
  grep -iE 'integer expression|out of range|syntax error|line [0-9]+:' "$WS14/purge.out" >&2
else PASS=$((PASS+1)); fi

# --- case 15: rebuilding elsewhere must not erase the record of what was left --
# When setup is told to build somewhere else, the worktree it could not claim
# stays standing — and the new marker describes only the new one. purge's own
# guard keys off the marker, so that worktree becomes invisible to every later
# run: the orphan the fail-closed design exists to prevent, reached by the
# documented recovery route.
foreign_worktree_repo; assert_ok $? "fixture for the rebuild-elsewhere record"; WS15="$FOREIGN_WS"
( cd "$WS15/proj" && bash "$SETUP" --mode worktree --worktree-path "$WS15/elsewhere" ) > "$WS15/setup.out" 2>&1
assert_ok $? "setup rebuilds at the requested path"
assert_file_contains "$WS15/setup.out" "still standing" "setup says the old worktree was left behind"
MK15="$WS15/proj/docs/looptesting/.sandbox/ownership.env"
assert_file_contains "$MK15" "UNCLAIMED_WORKTREE=$WS15/shared-wt" "the marker records what was left unclaimed"
sed -i.bak 's/^status: .*/status: CONVERGED/' "$WS15/proj/docs/looptesting/STATE.md"
rm -f "$WS15/proj/docs/looptesting/STATE.md.bak"
( cd "$WS15/proj" && bash "$CLEAN" --purge ) > "$WS15/purge.out" 2>&1
# An unclaimed worktree still standing means this purge stopped short too.
assert_eq "4" "$?" "purge with an unclaimed worktree on record exits 4"
assert_file_contains "$WS15/purge.out" "$WS15/shared-wt" "purge names the worktree nobody claimed"
assert_exists "$WS15/shared-wt/feature.txt" "and still does not touch it"
# naming it and then deleting the only record of it is worse than silence
assert_exists "$WS15/proj/docs/looptesting/.sandbox/ownership.env" \
  "the marker that records the unclaimed worktree survives purge"

# --- case 16: the harvest workflow the tool itself tells the user to perform ---
# clean keeps qa/loop-testing because the fix commits live only there, and purge's
# own message tells the user to harvest them. Doing that means adding a worktree
# on THAT branch — and the previous fixture used 'my-feature', so no case covered
# the one branch a user is actually likely to check out at that path.
WS16=$(mk_ws); track_ws "$WS16"; WT16="$WS16/proj-qa-loop"
( cd "$WS16/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup for the harvest case"
( cd "$WT16" && echo fix > fix.txt && git add -A && git commit -qm "fix: something" ) >/dev/null 2>&1
( cd "$WS16/proj" && bash "$CLEAN" ) >/dev/null 2>&1
( cd "$WS16/proj" && git worktree add -q "$WT16" qa/loop-testing )
echo "review notes, uncommitted" > "$WT16/REVIEW-NOTES.md"
( cd "$WS16/proj" && bash "$CLEAN" ) > "$WS16/clean.out" 2>&1
assert_ok $? "clean exits 0 during a harvest"
assert_exists "$WT16" "a harvest worktree on the kept qa branch is not removed"
assert_exists "$WT16/REVIEW-NOTES.md" "uncommitted review notes survive the harvest"
assert_file_contains "$WS16/clean.out" "does not match" "clean says the stamp did not match"

# --- case 16b: the SAME question, asked of setup ------------------------------
# wt_ownership exists twice, once per script, and every harvest assertion above
# drives only sandbox-clean.sh. A branch-name fallback restored in the setup copy
# alone would pass all of them while setup adopts the user's harvest worktree and
# the loop commits its fixes into that checkout.
WS16B=$(mk_ws); track_ws "$WS16B"; WT16B="$WS16B/proj-qa-loop"
( cd "$WS16B/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup for the setup-side harvest case"
( cd "$WT16B" && echo fix > fix.txt && git add -A && git commit -qm "fix: x" ) >/dev/null 2>&1
( cd "$WS16B/proj" && bash "$CLEAN" ) >/dev/null 2>&1
( cd "$WS16B/proj" && git worktree add -q "$WT16B" qa/loop-testing )
echo "uncommitted review note" > "$WT16B/NOTES.md"
( cd "$WS16B/proj" && bash "$SETUP" --mode worktree ) > "$WS16B/setup.out" 2>&1
if grep -qF "already initialized" "$WS16B/setup.out"; then
  FAIL=$((FAIL+1)); echo "  FAIL: setup adopted the user's harvest worktree as its sandbox" >&2
else PASS=$((PASS+1)); fi
assert_exists "$WT16B/NOTES.md" "setup left the harvest worktree's contents alone"

# --- case 17: a symlinked --worktree-path must still be recognized later ------
WS17=$(mk_ws); track_ws "$WS17"
mkdir -p "$WS17/real-parent"; ln -s "$WS17/real-parent" "$WS17/link-parent"
( cd "$WS17/proj" && bash "$SETUP" --mode worktree --worktree-path "$WS17/link-parent/wt" ) >/dev/null 2>&1
assert_ok $? "setup accepts a symlinked --worktree-path"
( cd "$WS17/proj" && bash "$CLEAN" ) > "$WS17/clean.out" 2>&1
assert_absent "$WS17/real-parent/wt" "clean removes a worktree reached through a symlink"
if grep -qF "already gone" "$WS17/clean.out"; then
  FAIL=$((FAIL+1)); echo "  FAIL: clean claimed a live worktree was already gone (symlink)" >&2
else PASS=$((PASS+1)); fi

# --- case 18: a --worktree-path whose parent does not exist yet --------------
# This worked before canonicalization was added; refusing it would be a new
# refusal invented by the fix, not by the bug.
WS18=$(mk_ws); track_ws "$WS18"
( cd "$WS18/proj" && bash "$SETUP" --mode worktree --worktree-path ../not-yet/wt ) > "$WS18/setup.out" 2>&1
assert_ok $? "setup still accepts a path whose parent does not exist"
assert_exists "$WS18/not-yet/wt" "the worktree was created under the new parent"

# --- case 19: a leading-dash path must not leak coreutils usage text ----------
WS19=$(mk_ws); track_ws "$WS19"
( cd "$WS19/proj" && bash "$SETUP" --mode worktree --worktree-path -dashy ) > "$WS19/setup.out" 2>&1
if grep -qiE 'usage: dirname|usage: basename|try .* --help' "$WS19/setup.out"; then
  FAIL=$((FAIL+1)); echo "  FAIL: raw coreutils usage text leaked" >&2
  grep -iE 'usage: dirname|usage: basename' "$WS19/setup.out" >&2
else PASS=$((PASS+1)); fi

# --- case 20: the `unknown` verdict never deletes -----------------------------
# Its entire purpose is "cannot tell, so do not touch", and nothing covered it.
WS20=$(mk_ws); track_ws "$WS20"; WT20="$WS20/proj-qa-loop"
( cd "$WS20/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup for the unknown-verdict case"
echo "untracked work" > "$WT20/keepme.txt"
# The worktree must stay one git will happily remove — otherwise git refuses the
# fixture and the file below survives no matter what the script decides, which
# makes the assertion unfalsifiable. Break only the thing the OWNERSHIP decision
# reads: the stamp file, present but unreadable, which is the `unknown` arm's
# reason for existing. (Skipped when running as root, which can read it anyway.)
GD20=$( cd "$WT20" && git rev-parse --absolute-git-dir 2>/dev/null )
chmod 000 "$GD20/loop-testing-owner" 2>/dev/null || true
( cd "$WS20/proj" && bash "$CLEAN" ) > "$WS20/clean.out" 2>&1
assert_ok $? "clean exits 0 on an unreadable worktree"
# Root reads a chmod 000 file regardless, so this fixture cannot reach the arm
# there. It used to hand out `PASS=$((PASS+2))` in that case — two passes for two
# assertions that never ran, which is a green tally reporting coverage it does
# not have (audit T-11). Say it was skipped, count nothing, and let case 20b —
# which does not depend on file permissions — carry the arm on every host.
if [ "$(id -u 2>/dev/null)" = 0 ]; then
  echo "  skip: running as root, an unreadable stamp is still readable — case 20b covers the unknown arm here"
else
  assert_exists "$WT20/keepme.txt" "an unidentifiable worktree is not force-removed"
  assert_file_contains "$WS20/clean.out" "could not confirm" "clean says it could not confirm ownership"
fi
chmod 600 "$GD20/loop-testing-owner" 2>/dev/null || true

# --- case 20b: the same verdict, reached without relying on permissions -------
# `unknown` has a second route that no privilege level can read past: the
# worktree's own git dir cannot be resolved at all. A `.git` file pointing
# nowhere is exactly that — the path is still registered in the main repo, the
# directory is still there, and wt_gitdir_of comes back empty. Same arm, same
# requirement (touch nothing), and it runs as any user.
WS20B=$(mk_ws); track_ws "$WS20B"; WT20B="$WS20B/proj-qa-loop"
( cd "$WS20B/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup for the unresolvable-git-dir case"
echo "untracked work" > "$WT20B/keepme.txt"
printf 'gitdir: /nonexistent/broken\n' > "$WT20B/.git"
( cd "$WS20B/proj" && bash "$CLEAN" ) > "$WS20B/clean.out" 2>&1
assert_ok $? "clean exits 0 when the worktree's git dir cannot be resolved"
assert_exists "$WT20B/keepme.txt" "a worktree whose git dir is unresolvable is not force-removed"
assert_file_contains "$WS20B/clean.out" "could not confirm" "clean says it could not confirm ownership"

# --- case 21: the stale rebuild path must not force-remove anything -----------
WS21=$(mk_ws); track_ws "$WS21"; WT21="$WS21/proj-qa-loop"
( cd "$WS21/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup for the stale-rebuild case"
rm -rf "${WT21:?}"                        # directory gone, registration remains
( cd "$WS21/proj" && bash "$SETUP" --mode worktree ) > "$WS21/setup.out" 2>&1
assert_ok $? "setup rebuilds straight over a stale registration"
assert_exists "$WT21" "the rebuilt worktree exists"
if ( cd "$WS21/proj" && git worktree list --porcelain | grep -c "worktree $WT21" | grep -qx 1 ); then
  PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: the stale registration was not replaced cleanly" >&2; fi

# --- case 22: cleaning up after ourselves must not touch other worktrees ------
# `git worktree prune` takes no path argument: it drops EVERY prunable
# registration in the repo. Using it to clear one stale entry applies a
# repo-wide remedy to a per-path verdict, and a user who relocated their own
# worktree with plain `mv` — the state `git worktree repair` exists to fix —
# loses its admin dir and can no longer repair it.
WS22=$(mk_ws); track_ws "$WS22"
( cd "$WS22/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup for the other-worktrees case"
( cd "$WS22/proj" && git worktree add -q "$WS22/user-wt" -b feature/mine )
echo "my uncommitted work" > "$WS22/user-wt/notes.txt"
mv "$WS22/user-wt" "$WS22/user-wt-moved"        # user relocates their own worktree
rm -rf "${WS22:?}/proj-qa-loop"                 # sandbox dir deleted by hand -> stale
( cd "$WS22/proj" && bash "$CLEAN" ) >/dev/null 2>&1
assert_ok $? "clean exits 0 while clearing a stale registration"
assert_exists "$WS22/proj/.git/worktrees/user-wt" "the user's own worktree registration survives"
if ( cd "$WS22/user-wt-moved" && git worktree repair >/dev/null 2>&1 ); then
  PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: the user can no longer repair their relocated worktree" >&2; fi
if ( cd "$WS22/proj" && git worktree list --porcelain | grep -qxF "worktree $WS22/proj-qa-loop" ); then
  FAIL=$((FAIL+1)); echo "  FAIL: our own stale registration was not cleared" >&2
else PASS=$((PASS+1)); fi

# --- case 23: a locked stale worktree must not be reported as cleared ---------
WS23=$(mk_ws); track_ws "$WS23"; WT23="$WS23/proj-qa-loop"
( cd "$WS23/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
( cd "$WS23/proj" && git worktree lock "$WT23" ) >/dev/null 2>&1
rm -rf "${WT23:?}"
( cd "$WS23/proj" && bash "$CLEAN" ) > "$WS23/clean.out" 2>&1
assert_ok $? "clean exits 0 against a locked stale worktree"
if ( cd "$WS23/proj" && git worktree list --porcelain | grep -qxF "worktree $WT23" ); then
  # still registered: the message must not claim otherwise
  if grep -qE 'pruned|removed' "$WS23/clean.out"; then
    FAIL=$((FAIL+1)); echo "  FAIL: clean claimed it cleared a registration that is still there" >&2
    grep -E 'worktree' "$WS23/clean.out" >&2
  else PASS=$((PASS+1)); fi
else PASS=$((PASS+1)); fi   # it did clear it — then the claim was true

# --- case 24: a resolved path must not keep .. in it -------------------------
# `git worktree list` prints resolved paths, so a recorded path containing ..
# never matches and the sandbox leaks its own worktree.
WS24=$(mk_ws); track_ws "$WS24"
( cd "$WS24/proj" && bash "$SETUP" --mode worktree --worktree-path "$WS24/proj/../wt24" ) >/dev/null 2>&1
assert_ok $? "setup accepts a path containing .."
MK24="$WS24/proj/docs/looptesting/.sandbox/ownership.env"
if grep -qE '^CREATED_WORKTREE=.*/\.\./' "$MK24"; then
  FAIL=$((FAIL+1)); echo "  FAIL: the marker recorded an unresolved .. path" >&2
  grep '^CREATED_WORKTREE=' "$MK24" >&2
else PASS=$((PASS+1)); fi
( cd "$WS24/proj" && bash "$CLEAN" ) > "$WS24/clean.out" 2>&1
assert_absent "$WS24/wt24" "clean removes a worktree created through a .. path"

# --- case 25: the SAME scoping question, asked of setup ----------------------
# The round-4 fix (scoped removal, never repo-wide prune) exists twice, and case
# 22 drives only sandbox-clean.sh. Case 16b made exactly this argument about
# wt_ownership; nobody applied it here, so half of the blocker's fix was guarded
# by nothing.
WS25=$(mk_ws); track_ws "$WS25"
( cd "$WS25/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup for the setup-side scoping case"
( cd "$WS25/proj" && git worktree add -q "$WS25/user-wt" -b feature/mine )
echo "my uncommitted work" > "$WS25/user-wt/notes.txt"
mv "$WS25/user-wt" "$WS25/user-wt-moved"
rm -rf "${WS25:?}/proj-qa-loop"
( cd "$WS25/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup rebuilds over its own stale registration"
assert_exists "$WS25/proj/.git/worktrees/user-wt" "setup leaves other worktrees' registrations alone"
if ( cd "$WS25/user-wt-moved" && git worktree repair >/dev/null 2>&1 ); then
  PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: setup left the user unable to repair their worktree" >&2; fi

# --- case 26: a purge that could not remove OUR worktree is not done either ---
# Every other outcome that leaves a worktree standing marks the purge partial.
# The `ours`-but-removal-failed branch did not, so purge deleted the marker,
# printed "purge done." and exited 0 with a worktree this tool created still on
# disk — the orphan the partial-purge reporting exists to prevent.
WS26=$(mk_ws); track_ws "$WS26"; WT26="$WS26/proj-qa-loop"
( cd "$WS26/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
mkdir -p "$WT26/.cache/x"; echo d > "$WT26/.cache/x/f"; chmod 500 "$WT26/.cache/x"
sed -i.bak 's/^status: .*/status: CONVERGED/' "$WS26/proj/docs/looptesting/STATE.md"
rm -f "$WS26/proj/docs/looptesting/STATE.md.bak"
( cd "$WS26/proj" && bash "$CLEAN" --purge ) > "$WS26/purge.out" 2>&1
purge26_rc=$?
chmod 700 "$WT26/.cache/x" 2>/dev/null || true
if [ -d "$WT26" ]; then
  assert_eq "4" "$purge26_rc" "a purge that could not remove our worktree exits 4"
  assert_exists "$WS26/proj/docs/looptesting/.sandbox/ownership.env" \
    "and keeps the marker that still records it"
else
  # The chmod did not stop git (root ignores it), so the partial arm is
  # unreachable on this host. Assert what MUST hold in the world that actually
  # happened instead of awarding two passes for two assertions that did not run
  # (audit T-11): a worktree that really was removed is a purge that completed.
  assert_eq "0" "$purge26_rc" "a purge that did remove the worktree reports success"
  assert_absent "$WS26/proj/docs/looptesting" "and the evidence dir goes with it"
fi

# --- case 27: a path segment containing a glob must not be expanded ----------
# The .. folding loop splits an unquoted expansion on IFS=/ — which is also
# subject to pathname expansion, so a segment like * would be replaced by
# whatever happens to sit in the current directory.
WS27=$(mk_ws); track_ws "$WS27"
# The pattern must be able to MATCH something, or bash leaves it alone and the
# bug stays invisible. setup runs with the repo as cwd, and the fixture repo
# contains README.md, so a `READ*` segment is what an accidental expansion would
# latch onto.
( cd "$WS27/proj" && bash "$SETUP" --mode worktree --worktree-path "$WS27/READ*/wt" ) >/dev/null 2>&1
assert_ok $? "setup accepts a path containing a glob character"
MK27="$WS27/proj/docs/looptesting/.sandbox/ownership.env"
if grep -qF "CREATED_WORKTREE=$WS27/README.md/wt" "$MK27"; then
  FAIL=$((FAIL+1)); echo "  FAIL: a path segment was glob-expanded against the current directory" >&2
  grep '^CREATED_WORKTREE=' "$MK27" >&2
else PASS=$((PASS+1)); fi
assert_file_contains "$MK27" "CREATED_WORKTREE=$WS27/READ*/wt" "the marker records the literal path"

# --- case 28: .. after a component that does not exist must still be folded ---
# Case 24's path had an existing component before the .., so pwd -P resolved it
# and the lexical folding block was never reached.
WS28=$(mk_ws); track_ws "$WS28"
( cd "$WS28/proj" && bash "$SETUP" --mode worktree --worktree-path "$WS28/nope/../wt28" ) >/dev/null 2>&1
assert_ok $? "setup accepts .. after a missing component"
MK28="$WS28/proj/docs/looptesting/.sandbox/ownership.env"
if grep -qE '^CREATED_WORKTREE=.*/\.\./' "$MK28"; then
  FAIL=$((FAIL+1)); echo "  FAIL: an unresolved .. survived into the marker" >&2
  grep '^CREATED_WORKTREE=' "$MK28" >&2
else PASS=$((PASS+1)); fi
( cd "$WS28/proj" && bash "$CLEAN" ) > "$WS28/clean.out" 2>&1
if grep -qF "already gone" "$WS28/clean.out"; then
  FAIL=$((FAIL+1)); echo "  FAIL: clean leaked its own worktree (unfolded ..)" >&2
else PASS=$((PASS+1)); fi

# --- case 29: a FAILED `git worktree list` is not a verdict (audit S-04) ------
# wt_ownership's own header says "a failed command must never be mistaken for an
# ownership verdict", and every external command was removed from the path for
# that reason — except the one the whole function is built on. `git worktree
# list --porcelain` can fail outright: an unreadable or locked .git/worktrees, a
# corrupted admin entry, a fork that cannot allocate. The empty output then
# matched nothing, so a LIVE worktree read as `absent`: clean announced "already
# gone", purge deleted the baseline tag, and the run ended "purge done." with
# exit 0 — the success code — while the worktree it was supposed to remove was
# still registered and still on disk. Exit 4 exists for exactly that state ("ran
# but stopped short"), and the one verdict that would have raised it was the one
# a failed command silently skipped. (Measured: the marker survived this fixture
# only because git refused to delete a branch checked out in that very worktree,
# which is a coincidence of the fixture, not a protection.)
#
# The shim fails ONLY `worktree list` and delegates every other subcommand to the
# real git, resolved before the shim goes on PATH so it cannot recurse into
# itself. A blanket "git is broken" fixture would prove nothing — the script
# would fail at its first rev-parse and never reach the ownership question.
WS29=$(mk_ws); track_ws "$WS29"
( cd "$WS29/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? 'fixture: setup for the failing worktree-list case'
assert_exists "$WS29/proj-qa-loop" "fixture: the worktree really is there"
# --purge is refused outside a terminal STATE, and the refusal happens before the
# worktree stage — without this the case would pass on exit 3 having tested
# nothing. Not `sed -i`: BSD sed needs an argument there, so the in-place form
# this repo already avoids would fail on macOS.
S29="$WS29/proj/docs/looptesting/STATE.md"
sed 's/^status: RUNNING/status: CONVERGED/' "$S29" > "$S29.new" && mv "$S29.new" "$S29"
assert_file_contains "$S29" "status: CONVERGED" "fixture: STATE is terminal so --purge is allowed to run"
REAL_GIT29="$(command -v git)"
mkdir -p "$WS29/shim"
printf '#!/usr/bin/env bash\ncase " $* " in *" worktree list "*) exit 128 ;; esac\nexec %s "$@"\n' \
  "$REAL_GIT29" > "$WS29/shim/git"
chmod +x "$WS29/shim/git"
# The shim must be a shim, not a brick: if it broke ordinary git the assertions
# below would pass for the wrong reason.
( cd "$WS29/proj" && PATH="$WS29/shim:$PATH" git rev-parse HEAD ) >/dev/null 2>&1
assert_ok $? "fixture: the shim delegates everything except worktree list"
( cd "$WS29/proj" && PATH="$WS29/shim:$PATH" git worktree list --porcelain ) >/dev/null 2>&1
assert_nonzero $? "fixture: the shim really does fail worktree list"

( cd "$WS29/proj" && PATH="$WS29/shim:$PATH" bash "$CLEAN" --purge ) > "$WS29/clean.out" 2>&1
rc29=$?
if grep -qF "already gone" "$WS29/clean.out"; then
  FAIL=$((FAIL+1)); echo "  FAIL: a failed 'git worktree list' was reported as 'already gone'" >&2
else PASS=$((PASS+1)); fi
assert_eq 4 "$rc29" "purge exits 4 (stopped short) rather than 0 when it could not identify the worktree"
assert_exists "$WS29/proj-qa-loop" "the live worktree is still on disk"
# The marker is what makes the leftover recoverable at all.
assert_exists "$WS29/proj/docs/looptesting/.sandbox/ownership.env" \
  "purge kept the ownership marker that still names the worktree"
assert_file_contains "$WS29/clean.out" "could not confirm" \
  "clean says it could not answer the ownership question"

# --- case 30: the unclaimed record must survive the NEXT rebuild too (S-09) ---
# Case 15 covers one rebuild. The record it checks is written from the verdict of
# THAT run, and the next rebuild has a verdict of its own — about a different
# path — so it wrote UNCLAIMED_WORKTREE= empty and the marker stopped naming the
# worktree it had walked away from. Nothing else on disk names it. That is the
# same transitivity hole ADOPTED_BRANCH/ADOPTED_TAG were given a carry-forward
# for, on the field where the consequence is a worktree nobody can find rather
# than a ref nobody can delete: README's fourth purge keep-case simply stops
# firing after the second rebuild, and purge closes over the evidence dir that
# held the only record.
#
# Two rebuilds, and the second one has no unclaimed worktree of its own: clean
# removes the worktree the first rebuild created, so the second sees `absent` —
# the ordinary "recorded worktree is gone" rebuild, not an exotic state.
foreign_worktree_repo; assert_ok $? "fixture for the two-rebuild record"; WS30="$FOREIGN_WS"
( cd "$WS30/proj" && bash "$SETUP" --mode worktree --worktree-path "$WS30/elsewhere" ) >/dev/null 2>&1
assert_ok $? "rebuild 1 lands at the requested path"
MK30="$WS30/proj/docs/looptesting/.sandbox/ownership.env"
assert_file_contains "$MK30" "UNCLAIMED_WORKTREE=$WS30/shared-wt" \
  "fixture: rebuild 1 recorded the worktree it could not claim"
( cd "$WS30/proj" && bash "$CLEAN" ) >/dev/null 2>&1
assert_ok $? "clean removes the worktree rebuild 1 created"
( cd "$WS30/proj" && bash "$SETUP" --mode worktree --worktree-path "$WS30/elsewhere" ) >/dev/null 2>&1
assert_ok $? "rebuild 2 succeeds"
assert_file_contains "$MK30" "UNCLAIMED_WORKTREE=$WS30/shared-wt" \
  "rebuild 2 still records the worktree the FIRST rebuild could not claim"

# The record only matters for what purge does with it.
sed 's/^status: .*/status: CONVERGED/' "$WS30/proj/docs/looptesting/STATE.md" > "$WS30/st" \
  && mv "$WS30/st" "$WS30/proj/docs/looptesting/STATE.md"
( cd "$WS30/proj" && bash "$CLEAN" --purge ) > "$WS30/purge.out" 2>&1
assert_eq "4" "$?" "purge still stops short over the worktree it cannot claim"
assert_file_contains "$WS30/purge.out" "$WS30/shared-wt" "purge still names it"
assert_exists "$WS30/shared-wt/feature.txt" "and still does not touch the user's work in it"
assert_exists "$MK30" "the marker that names it survives purge"

# --- case 31: a record that is no longer on disk is not carried forever -------
# The carry-forward must not turn into a permanent exit 4. With the unclaimed
# worktree removed by the user, the next rebuild has nothing to name and purge
# must be able to finish.
foreign_worktree_repo; assert_ok $? "fixture for the stale-record case"; WS31="$FOREIGN_WS"
( cd "$WS31/proj" && bash "$SETUP" --mode worktree --worktree-path "$WS31/elsewhere" ) >/dev/null 2>&1
assert_ok $? "rebuild 1 lands at the requested path"
( cd "$WS31/proj" && git worktree remove --force "$WS31/shared-wt" ) >/dev/null 2>&1
assert_absent "$WS31/shared-wt" "fixture: the user dealt with the unclaimed worktree"
( cd "$WS31/proj" && bash "$CLEAN" ) >/dev/null 2>&1
( cd "$WS31/proj" && bash "$SETUP" --mode worktree --worktree-path "$WS31/elsewhere" ) >/dev/null 2>&1
assert_ok $? "rebuild 2 succeeds"
MK31="$WS31/proj/docs/looptesting/.sandbox/ownership.env"
if grep -qF "UNCLAIMED_WORKTREE=$WS31/shared-wt" "$MK31"; then
  FAIL=$((FAIL+1)); echo "  FAIL: a path that no longer exists was carried forward" >&2
else PASS=$((PASS+1)); fi

# --- case 32: `git worktree list` exiting 0 while OMITTING an entry (S-04) ----
# Case 29 covers the failure git REPORTS. This is the one it does not report: an
# unreadable `.git/worktrees` makes `git worktree list --porcelain` exit 0, print
# nothing on stderr, and silently drop the entry. An exit-status-only guard never
# fires, so a live worktree still reads `absent` and purge deletes the tag, the
# branch, the evidence dir and the marker over a sandbox still standing — closing
# at PURGE_RC=0, the success code. Measured on git 2.53.0: rc=0, empty stderr,
# entry gone.
#
# The positive test that survives it is the checkout's own `.git` FILE. A linked
# worktree's `.git` is a regular file holding `gitdir: …`; it lives inside the
# checkout, not in the admin dir, so it outlives both an unreadable
# `.git/worktrees` and a missing `gitdir` file. It must be `-f` and not `-e`: a
# plain `git init` repo parked at the freed path has `.git` as a DIRECTORY, and
# that one really is absent as far as this sandbox is concerned.
WS32=$(mk_ws); track_ws "$WS32"
( cd "$WS32/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? 'fixture: setup for the silently-omitted worktree case'
assert_exists "$WS32/proj-qa-loop" "fixture: the worktree really is there"
# --purge is refused outside a terminal STATE, and that refusal lands before the
# worktree stage — without this the case would pass on exit 3 having tested
# nothing. Not `sed -i`: BSD sed needs an argument there.
S32="$WS32/proj/docs/looptesting/STATE.md"
sed 's/^status: RUNNING/status: CONVERGED/' "$S32" > "$S32.new" && mv "$S32.new" "$S32"
assert_file_contains "$S32" "status: CONVERGED" "fixture: STATE is terminal so --purge is allowed to run"

if [ "$(id -u 2>/dev/null)" = 0 ]; then
  echo "  skip: running as root — an unreadable .git/worktrees is still readable, so git cannot be made to omit the entry"
else
  chmod 000 "$WS32/proj/.git/worktrees" 2>/dev/null
  # The fixture must prove it created the condition under test: exit 0 AND the
  # entry missing. If it did not, this case has to say so — a case that quietly
  # tests nothing is the defect class this suite exists to catch.
  probe32=""; probe32_rc=0
  probe32="$( cd "$WS32/proj" && git worktree list --porcelain 2>/dev/null )" || probe32_rc=$?
  if [ "$probe32_rc" = 0 ] && ! printf '%s\n' "$probe32" | grep -qxF "worktree $WS32/proj-qa-loop"; then
    PASS=$((PASS+1))   # fixture self-probe: git really does exit 0 and omit it
    ( cd "$WS32/proj" && bash "$CLEAN" --purge ) > "$WS32/clean.out" 2>&1
    rc32=$?
    if grep -qF "already gone" "$WS32/clean.out"; then
      FAIL=$((FAIL+1)); echo "  FAIL: an entry omitted at exit 0 was reported as 'already gone'" >&2
    else PASS=$((PASS+1)); fi
    assert_eq 4 "$rc32" "purge exits 4 (stopped short), not 0, when the registry could not be read"
    assert_exists "$WS32/proj-qa-loop" "the live worktree is still on disk"
    assert_exists "$WS32/proj/docs/looptesting/.sandbox/ownership.env" \
      "purge kept the ownership marker that still names the worktree"
    # `git branch -D` refuses a branch checked out in another worktree, and it
    # reads that fact out of the SAME unreadable admin dir — so the refusal does
    # not fire either, and the branch goes with everything else. The marker was
    # the only record of the worktree's path; the branch is the only record of
    # its commits. Both have to be gated on the same verdict.
    if ( cd "$WS32/proj" && git show-ref --verify --quiet refs/heads/qa/loop-testing ); then
      PASS=$((PASS+1))
    else
      FAIL=$((FAIL+1))
      echo "  FAIL: the sandbox branch was deleted while its worktree could not be identified" >&2
    fi
    # Same rule case 34 applies to setup. `foreign` is an ANSWER and offers no
    # removal command; `unknown` is the absence of one and must not offer one
    # either — clean's copy had those two the other way round, and this arm
    # became reachable from more states once a failed registry read started
    # producing `unknown`. `--` because the needle begins with a dash.
    if grep -qF -- "worktree remove --force" "$WS32/clean.out"; then
      FAIL=$((FAIL+1))
      echo "  FAIL: clean handed the user --force for a worktree it had just said it could not identify" >&2
    else PASS=$((PASS+1)); fi
  else
    FAIL=$((FAIL+1))
    echo "  FAIL: fixture could not make git omit the entry at exit 0 — case 32 tested nothing" >&2
  fi
  chmod 755 "$WS32/proj/.git/worktrees" 2>/dev/null
fi

# --- case 33: a plain repo parked at the freed path is `absent`, not `unknown` -
# Case 32's positive test is `[ -f "$p/.git" ]`, and the `-f` is load-bearing: a
# linked worktree's `.git` is a FILE holding `gitdir: …`, an ordinary
# repository's is a DIRECTORY. Under `-e` the two are indistinguishable, and a
# user who reused the freed path for a repository of their own would put this
# sandbox into a permanent exit 4 — "could not identify the worktree", forever,
# over something that is not a worktree at all. That is the failure mode the
# widened guard would have introduced, so it gets an assertion of its own.
WS33=$(mk_ws); track_ws "$WS33"
( cd "$WS33/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? 'fixture: setup for the reused-path case'
( cd "$WS33/proj" && git worktree remove --force "$WS33/proj-qa-loop" ) >/dev/null 2>&1
assert_absent "$WS33/proj-qa-loop" "fixture: the sandbox worktree is gone and the path is free"
git init -q "$WS33/proj-qa-loop" >/dev/null 2>&1
# The whole case turns on this being a directory. If a future git made `.git` a
# file for ordinary repos too, the case would still pass while testing nothing.
if [ -d "$WS33/proj-qa-loop/.git" ]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1))
  echo "  FAIL: fixture: a plain repo's .git must be a DIRECTORY for this case to discriminate" >&2
fi
( cd "$WS33/proj" && bash "$CLEAN" ) > "$WS33/clean.out" 2>&1
rc33=$?
assert_eq 0 "$rc33" "clean exits 0 — a plain repo at the freed path is absent, not an unidentifiable worktree"
# The message assertion is the one that carries this case: measured under the
# `-f` -> `-e` mutation, the exit code stays 0 and only the wording changes, so
# the rc assertion above documents the contract without discriminating on it.
assert_file_contains "$WS33/clean.out" "already gone" \
  "clean reports the worktree as gone rather than as one it could not identify"
assert_exists "$WS33/proj-qa-loop/.git" "the user's own repository at that path was not touched"

# --- case 34: an `unknown` verdict must not hand the user --force ------------
# `foreign` and `unknown` are different situations. `foreign` is an answer — the
# stamp was read and it is somebody else's — so naming --force is fair. `unknown`
# is the absence of an answer, and the refusal used to offer --force anyway,
# qualified with "if it is the sandbox's". When the probe failed the worktree
# usually IS the sandbox's, so that qualifier reads as a yes: the tool refuses a
# destructive operation and then asks the user to run it by hand, on a worktree
# it has just said it cannot identify, discarding whatever uncommitted or
# untracked QA work is in there.
WS34=$(mk_ws); track_ws "$WS34"
( cd "$WS34/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? 'fixture: setup for the unresolvable-registry advice case'
if [ "$(id -u 2>/dev/null)" = 0 ]; then
  echo "  skip: running as root — .git/worktrees stays readable, so the unknown verdict cannot be reached here"
else
  chmod 000 "$WS34/proj/.git/worktrees" 2>/dev/null
  probe34="$( cd "$WS34/proj" && git worktree list --porcelain 2>/dev/null )"; probe34_rc=$?
  if [ "$probe34_rc" = 0 ] && ! printf '%s\n' "$probe34" | grep -qxF "worktree $WS34/proj-qa-loop"; then
    PASS=$((PASS+1))   # fixture self-probe: the registry really is unreadable
    ( cd "$WS34/proj" && bash "$SETUP" --mode worktree ) > "$WS34/setup.out" 2>&1
    rc34=$?
    assert_eq 6 "$rc34" "setup refuses (exit 6) over a worktree it cannot identify"
    assert_file_contains "$WS34/setup.out" "could not confirm" \
      "the refusal says it could not confirm ownership, rather than asserting someone else's"
    # `--` because the needle would otherwise be read as grep options.
    if grep -qF -- "worktree remove --force" "$WS34/setup.out"; then
      FAIL=$((FAIL+1))
      echo "  FAIL: the refusal handed the user --force for a worktree it had just said it could not identify" >&2
    else PASS=$((PASS+1)); fi
    # The route that actually works must still be named, or the refusal is a
    # dead end dressed as advice.
    assert_file_contains "$WS34/setup.out" "--worktree-path" "and it still names the flag that works"
  else
    FAIL=$((FAIL+1))
    echo "  FAIL: fixture could not make the registry unreadable — case 34 tested nothing" >&2
  fi
  chmod 755 "$WS34/proj/.git/worktrees" 2>/dev/null
fi

# --- case 35: a user's --separate-git-dir repo at the freed path is `absent` --
# Case 33 pins `-f` against a plain repo, whose `.git` is a DIRECTORY. This pins
# the other half: `git init --separate-git-dir` — and equally a submodule
# checkout, or a plain file called `.git` — has `.git` as a FILE, so `-f` alone
# reads the user's own repository as a worktree this sandbox cannot identify.
# The consequence is not a deletion, it is the opposite and just as wrong: a
# permanent exit 4 over something that is not a worktree at all, with a
# diagnosis ("the registry could not be read") that is false, and removal advice
# aimed at the user's repo. What makes a `.git` file OURS is that its `gitdir:`
# points into this repo's own .git/worktrees/.
WS35=$(mk_ws); track_ws "$WS35"
( cd "$WS35/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? 'fixture: setup for the separate-git-dir case'
( cd "$WS35/proj" && git worktree remove --force "$WS35/proj-qa-loop" ) >/dev/null 2>&1
assert_absent "$WS35/proj-qa-loop" "fixture: the sandbox worktree is gone and the path is free"
git init -q --separate-git-dir "$WS35/elsewhere-gitdir" "$WS35/proj-qa-loop" >/dev/null 2>&1
# The case only means something if git really produced a .git FILE here.
if [ -f "$WS35/proj-qa-loop/.git" ]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1))
  echo "  FAIL: fixture: --separate-git-dir did not produce a .git file, so case 35 discriminates nothing" >&2
fi
echo "my own work" > "$WS35/proj-qa-loop/mine.txt"
( cd "$WS35/proj" && bash "$CLEAN" ) > "$WS35/clean.out" 2>&1
rc35=$?
assert_eq 0 "$rc35" "clean exits 0 — a user's --separate-git-dir repo is not an unidentifiable worktree"
assert_file_contains "$WS35/clean.out" "already gone" \
  "and reports the sandbox worktree as gone rather than as one it could not identify"
assert_exists "$WS35/proj-qa-loop/mine.txt" "the user's file at that path was not touched"

report "worktree-identity.test.sh"
