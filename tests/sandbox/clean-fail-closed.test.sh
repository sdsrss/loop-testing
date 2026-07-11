#!/usr/bin/env bash
# sandbox-clean.sh fails closed: with no/absent ownership marker it must delete
# nothing (never guess what it owns).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# --- clean on a repo that never ran setup: no-op, deletes nothing -------------
WS0=$(mk_ws); trap 'rm -rf "$WS0"' EXIT
REPO0="$WS0/proj"
( cd "$REPO0" && bash "$CLEAN" ) >/dev/null 2>&1
assert_ok $? "clean without prior setup is a benign no-op"

# --- marker missing/tampered: owned worktree must NOT be removed --------------
WS=$(mk_ws); trap 'rm -rf "$WS0" "$WS"' EXIT
REPO="$WS/proj"
WT="$WS/proj-qa-loop"
( cd "$REPO" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_exists "$WT" "worktree created for fail-closed test"

# simulate a lost/tampered ownership marker
rm -f "$REPO/docs/looptesting/.sandbox/ownership.env"

( cd "$REPO" && bash "$CLEAN" ) >/dev/null 2>&1
status=$?
assert_ok $status "clean exits cleanly when marker absent"
assert_exists "$WT" "fail-closed: worktree preserved when marker missing"
assert_exists "$REPO/docs/looptesting" "fail-closed: evidence dir preserved"

# cleanup the orphan worktree we deliberately left behind
( cd "$REPO" && git worktree remove --force "$WT" ) >/dev/null 2>&1 || rm -rf "$WT"

report "clean-fail-closed.test.sh"
