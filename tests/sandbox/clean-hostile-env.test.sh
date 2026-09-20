#!/usr/bin/env bash
# sandbox-clean.sh must complete its teardown in an environment that carries no
# HOME (audit S-04/S-05 class: the destructive path is the one that must not
# depend on ambient state).
#
# S-05: the suspicious-path guard reads `"$HOME"` directly inside a `case`
# pattern, and the script runs under `set -u`. With HOME unset — cron, a systemd
# unit without `User=`, `env -i`, a container entrypoint, the unattended driver
# started from any of those — that reference is a fatal unbound-variable error
# BEFORE the worktree is removed. The visible result is the opposite of a safe
# refusal: clean exits 1, the worktree is still registered, `.active` is still
# armed, so the stop-gate keeps refusing to end the session, and the next setup
# finds a sandbox it must rebuild around. A guard against deleting $HOME that
# fires when $HOME does not exist protects nothing and costs the whole teardown.
#
# The fix is `${HOME:-}`: an unset HOME then contributes an empty pattern, which
# cannot match the non-empty path the surrounding `[ -n "$CREATED_WORKTREE" ]`
# already guarantees.
#
# SAFETY: everything here runs against a throwaway repo from mk_ws. `env -u HOME`
# is scoped to the clean invocation — this test never unsets HOME for itself.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WS=$(mk_ws); trap 'rm -rf "$WS"' EXIT
REPO="$WS/proj"
WT="$WS/proj-qa-loop"   # default sibling worktree path

( cd "$REPO" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "fixture: worktree-mode setup succeeds"
assert_exists "$WT" "fixture: worktree checkout created"
assert_exists "$REPO/docs/looptesting/.active" "fixture: stop-gate sentinel armed"

# --- case 1: HOME unset — the teardown still runs to completion ---------------
# `env -u HOME` removes the variable rather than blanking it: an empty HOME would
# be defined, and `set -u` only fires on undefined. Blanking it would test the
# string comparison, not the guard that breaks.
( cd "$REPO" && env -u HOME bash "$CLEAN" ) > "$WS/clean.out" 2>&1
assert_ok $? "clean exits 0 with HOME unset"
assert_absent "$WT" "owned worktree removed with HOME unset"
assert_absent "$REPO/docs/looptesting/.active" "stop-gate sentinel disarmed with HOME unset"

# Name the failure mode, not just the outcome: a future regression that trades
# the unbound error for a silent skip would leave the two assertions above red
# with no explanation on stdout, and a regression that reintroduces `"$HOME"`
# prints exactly this.
if grep -q 'unbound variable' "$WS/clean.out" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "  FAIL: clean died on an unbound variable with HOME unset" >&2
else PASS=$((PASS+1)); fi

# The guard must not have swallowed the worktree either: "suspicious path" here
# would mean an empty HOME matched a real path.
if grep -q 'refusing to remove suspicious worktree path' "$WS/clean.out" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "  FAIL: an unset HOME made the suspicious-path guard fire on a real worktree" >&2
else PASS=$((PASS+1)); fi

# --- case 2: control — the guard still refuses when the path really is $HOME ---
# Case 1 passes trivially for a fix that deletes the guard. This one fails for
# that fix: with HOME pointed at the recorded worktree path, clean must refuse to
# remove it and say so.
WS2=$(mk_ws); REPO2="$WS2/proj"
( cd "$REPO2" && bash "$SETUP" --mode worktree --worktree-path "$WS2/shared-wt" ) >/dev/null 2>&1
assert_ok $? "fixture: setup at an explicit worktree path"
( cd "$REPO2" && HOME="$WS2/shared-wt" bash "$CLEAN" ) > "$WS2/clean.out" 2>&1
assert_ok $? "clean exits 0 when the recorded worktree is \$HOME"
assert_file_contains "$WS2/clean.out" "refusing to remove suspicious worktree path" \
  "the suspicious-path guard still fires when the recorded path IS \$HOME"
assert_exists "$WS2/shared-wt" "a worktree standing at \$HOME is left on disk"
rm -rf "$WS2"

report "clean-hostile-env.test.sh"
