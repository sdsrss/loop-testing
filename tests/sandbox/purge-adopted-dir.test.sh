#!/usr/bin/env bash
# --purge must not delete a docs/looptesting/ that the sandbox only ADOPTED.
#
# setup writes CREATED_LOOPTESTING_DIR into the ownership marker, and purge does
# `rm -rf` on the evidence dir. When a user already keeps notes/ADRs under
# docs/looptesting/, the sandbox reuses that directory rather than creating it —
# and purge then destroys the user's files, untracked ones unrecoverably. That
# contradicts the script headers ("removes ONLY its own artifacts", "Never
# touches user data") and the purge block's own rule for refs it only adopted:
# report it, never delete it (sandbox-clean.sh "adopted refs" section).
#
# The marker must carry the truth ACROSS lifecycles: a second setup over a marker
# that says "adopted" must not silently upgrade the dir to "ours" and re-arm the
# deletion one round later.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WS_ALL=""
cleanup_all() { [ -n "$WS_ALL" ] && rm -rf $WS_ALL; }   # word-split on purpose
trap cleanup_all EXIT

# Sets NEW_WS rather than echoing it: the caller would need $( ), and a command
# substitution runs in a subshell, so the WS_ALL registration would be discarded
# and the EXIT trap would clean nothing — every fixture would leak into TMPDIR.
NEW_WS=""
new_ws() { local ws; ws=$(mk_ws) || return 1; WS_ALL="$WS_ALL $ws"; NEW_WS="$ws"; }

terminal_state() { sed -i.bak 's/^status: .*/status: CONVERGED/' "$1/docs/looptesting/STATE.md" \
                   && rm -f "$1/docs/looptesting/STATE.md.bak"; }

# --- case 1: a pre-existing user evidence dir survives --purge ----------------
new_ws; WS="$NEW_WS"; REPO="$WS/proj"
mkdir -p "$REPO/docs/looptesting"
echo "ADR: why we chose X" > "$REPO/docs/looptesting/adr-1.md"
( cd "$REPO" && git add -A && git commit -qm "user docs" ) >/dev/null 2>&1
echo "untracked user notes" > "$REPO/docs/looptesting/scratch-notes.md"

( cd "$REPO" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup adopts the pre-existing evidence dir"
assert_file_contains "$REPO/docs/looptesting/.sandbox/ownership.env" \
  "CREATED_LOOPTESTING_DIR=false" "marker records that the dir was adopted, not created"

terminal_state "$REPO"
( cd "$REPO" && bash "$CLEAN" --purge ) > "$WS/purge.out" 2>&1
assert_ok $? "purge over an adopted evidence dir still exits 0"
assert_exists "$REPO/docs/looptesting/adr-1.md" "tracked user file survives purge"
assert_exists "$REPO/docs/looptesting/scratch-notes.md" "UNTRACKED user file survives purge"
assert_file_contains "$WS/purge.out" "re-used by this run" "purge says why it kept the dir"
# and it must not pretend it deleted it
if grep -qF "removed evidence dir" "$WS/purge.out"; then
  FAIL=$((FAIL+1)); echo "  FAIL: purge claimed to remove an evidence dir it kept" >&2
else PASS=$((PASS+1)); fi

# --- case 2 (mutation guard): a dir the sandbox DID create is still purged ----
# A fix that simply stopped deleting the evidence dir would pass case 1 and
# quietly break purge's documented job.
new_ws; WS2="$NEW_WS"; REPO2="$WS2/proj"
( cd "$REPO2" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup creates the evidence dir when none existed"
assert_file_contains "$REPO2/docs/looptesting/.sandbox/ownership.env" \
  "CREATED_LOOPTESTING_DIR=true" "marker records a dir this run created"
terminal_state "$REPO2"
( cd "$REPO2" && bash "$CLEAN" --purge ) > "$WS2/purge.out" 2>&1
assert_ok $? "purge over an owned evidence dir exits 0"
assert_absent "$REPO2/docs/looptesting" "owned evidence dir is still removed by purge"

# --- case 3: the adopted flag survives a clean -> setup -> purge lifecycle ----
# Second setup finds the dir already there. Inheriting "ours" from mere presence
# would re-arm the deletion one lifecycle later, which is the same bug delayed.
new_ws; WS3="$NEW_WS"; REPO3="$WS3/proj"
mkdir -p "$REPO3/docs/looptesting"
echo "user notes round 0" > "$REPO3/docs/looptesting/notes.md"
( cd "$REPO3" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "first setup over an adopted dir"
( cd "$REPO3" && bash "$CLEAN" ) >/dev/null 2>&1
assert_ok $? "plain clean between the two setups"
( cd "$REPO3" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "second setup reuses the evidence dir"
assert_file_contains "$REPO3/docs/looptesting/.sandbox/ownership.env" \
  "CREATED_LOOPTESTING_DIR=false" "adopted flag is inherited, not upgraded to true"
terminal_state "$REPO3"
( cd "$REPO3" && bash "$CLEAN" --purge ) >/dev/null 2>&1
assert_ok $? "purge after the second lifecycle exits 0"
assert_exists "$REPO3/docs/looptesting/notes.md" "user file survives the second-lifecycle purge"

# --- case 4: a marker written by an OLDER version cannot be trusted -----------
# v0.9.1 and earlier wrote CREATED_LOOPTESTING_DIR=true unconditionally, over a
# directory the user already owned included. A reader that trusts that `true`
# fixes nothing for anyone who already has a sandbox — i.e. the entire install
# base — while the README now promises it does. The marker must carry a version,
# and a pre-v2 value must count as UNKNOWN, which is the rule this block already
# applies to an absent field.
new_ws; WS4="$NEW_WS"; REPO4="$WS4/proj"
mkdir -p "$REPO4/docs/looptesting"
echo "user ADR kept here since before the tool existed" > "$REPO4/docs/looptesting/adr.md"
( cd "$REPO4" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup for the legacy-marker case"
MK4="$REPO4/docs/looptesting/.sandbox/ownership.env"
# rewrite the marker into exactly the shape v0.9.1 emitted
sed -e 's/^SANDBOX_VERSION=.*/SANDBOX_VERSION=1/' \
    -e 's/^CREATED_LOOPTESTING_DIR=.*/CREATED_LOOPTESTING_DIR=true/' "$MK4" > "$MK4.tmp"
mv "$MK4.tmp" "$MK4"
terminal_state "$REPO4"
( cd "$REPO4" && bash "$CLEAN" --purge ) > "$WS4/purge.out" 2>&1
assert_ok $? "purge over a v1 marker exits 0"
assert_exists "$REPO4/docs/looptesting/adr.md" "a v1 marker's true is not trusted — user file survives"
# and it must not claim something it cannot know
if grep -qF "already yours" "$WS4/purge.out"; then
  FAIL=$((FAIL+1)); echo "  FAIL: purge asserted the dir holds user files when it only knows the marker is old" >&2
else PASS=$((PASS+1)); fi
assert_file_contains "$WS4/purge.out" "older version" "purge names the stale marker as the reason"

# --- case 5: a setup that fails AFTER the git stage must not brand its own dir -
# The rollback at die() is skipped once a git artifact exists, so docs/looptesting/
# survives with no marker. If the retry then infers ownership from "the dir is
# already there", it records false for a directory that was never the user's, and
# purge refuses to clean up the tool's own artifacts forever while saying so
# falsely.
new_ws; WS5="$NEW_WS"; REPO5="$WS5/proj"
mkdir -p "$WS5/proj-qa-loop"          # occupy the default worktree path -> setup fails
( cd "$REPO5" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_eq "6" "$?" "occupied default worktree path -> documented exit 6"
assert_exists "$REPO5/docs/looptesting" "the failed setup left its evidence dir behind"
( cd "$REPO5" && bash "$SETUP" --mode worktree --worktree-path "$WS5/alt-wt" ) >/dev/null 2>&1
assert_ok $? "retry with another worktree path succeeds"
assert_file_contains "$REPO5/docs/looptesting/.sandbox/ownership.env" \
  "CREATED_LOOPTESTING_DIR=true" "the retry still knows the dir is the tool's own"
terminal_state "$REPO5"
( cd "$REPO5" && bash "$CLEAN" --purge ) >/dev/null 2>&1
assert_ok $? "purge after the failed-then-retried setup exits 0"
assert_absent "$REPO5/docs/looptesting" "purge removes a dir that was always the tool's own"

# --- case 6: setup must not launder a v1 marker's constant into a v2 fact -----
# clean refuses to trust CREATED_LOOPTESTING_DIR below version 2. That gate is
# worthless if setup reads the same untrustworthy field out of the old marker and
# re-emits it under SANDBOX_VERSION=2 — the value becomes "measured" without
# anyone measuring it. The path is the ordinary upgrade: a pre-v2 sandbox is
# cleaned, the user updates the plugin, the next setup rebuilds.
new_ws; WS6="$NEW_WS"; REPO6="$WS6/proj"
mkdir -p "$REPO6/docs/looptesting"
echo "user notes from before the tool" > "$REPO6/docs/looptesting/notes.md"
( cd "$REPO6" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup for the v1-launder case"
MK6="$REPO6/docs/looptesting/.sandbox/ownership.env"
# reshape into exactly what v0.9.1 left behind: constant true, version 1, and no
# breadcrumb — the breadcrumb did not exist then, and leaving it would mask this.
sed -e 's/^SANDBOX_VERSION=.*/SANDBOX_VERSION=1/' \
    -e 's/^CREATED_LOOPTESTING_DIR=.*/CREATED_LOOPTESTING_DIR=true/' "$MK6" > "$MK6.tmp"
mv "$MK6.tmp" "$MK6"
rm -f "$REPO6/docs/looptesting/.sandbox/created-dirs.env"
( cd "$REPO6" && bash "$CLEAN" ) >/dev/null 2>&1       # plain clean: worktree goes, marker stays
( cd "$REPO6" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1   # next setup rebuilds
assert_ok $? "setup rebuilds over the v1 marker"
assert_file_contains "$MK6" "SANDBOX_VERSION=2" "the rebuilt marker is v2"
# false means "measured, and it was not ours". This lifecycle measured nothing —
# the v1 marker carried no usable value and v0.9.1 wrote no breadcrumb — so the
# honest record is "unknown", and purge must not go on to tell the user the
# directory holds files that were already theirs, which it cannot know either.
assert_file_contains "$MK6" "CREATED_LOOPTESTING_DIR=unknown" \
  "an unmeasured value is recorded as unknown, not laundered and not guessed"
terminal_state "$REPO6"
( cd "$REPO6" && bash "$CLEAN" --purge ) > "$WS6/purge.out" 2>&1
assert_exists "$REPO6/docs/looptesting/notes.md" "the user's file survives the upgrade lifecycle"
assert_file_contains "$WS6/purge.out" "could not determine" "purge says it does not know, instead of claiming"
if grep -qF "already yours" "$WS6/purge.out"; then
  FAIL=$((FAIL+1)); echo "  FAIL: purge asserted ownership it never measured" >&2
else PASS=$((PASS+1)); fi

report "purge-adopted-dir.test.sh"
