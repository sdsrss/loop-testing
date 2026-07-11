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

report "setup.test.sh"
