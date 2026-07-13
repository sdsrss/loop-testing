#!/usr/bin/env bash
# sandbox-clean.sh: removes only owned worktree, stops only started processes,
# keeps the qa branch + docs/looptesting evidence, and is idempotent.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WS=$(mk_ws); trap 'rm -rf "$WS"' EXIT
REPO="$WS/proj"
WT="$WS/proj-qa-loop"   # default sibling worktree path

( cd "$REPO" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "worktree-mode setup succeeds"
assert_exists "$WT" "worktree checkout created"

# evidence the agent produced during the loop — must survive cleanup
mkdir -p "$REPO/docs/looptesting/runs"
echo "round 1 evidence" > "$REPO/docs/looptesting/runs/round-1.md"

# a process the sandbox 'started' (recorded) and one it did NOT start
sleep 30 & owned_pid=$!
sleep 30 & foreign_pid=$!
# a recorded process that IGNORES SIGTERM -> clean must escalate to SIGKILL (C7)
( trap '' TERM; while true; do sleep 0.5; done ) & stubborn_pid=$!
# a recorded "server" that forks a worker child (dev-server->worker pattern); only
# the parent PID is recorded. Killing just the recorded PID leaks the worker (DR-1).
bash -c 'sleep 300 & echo $! > "'"$WS"'/worker.pid"; wait' & server_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$WS/worker.pid" ] && break; sleep 0.1; done
worker_pid=$(cat "$WS/worker.pid" 2>/dev/null)
echo "$owned_pid" >> "$REPO/docs/looptesting/.pids"
echo "$stubborn_pid" >> "$REPO/docs/looptesting/.pids"
echo "$server_pid" >> "$REPO/docs/looptesting/.pids"

( cd "$REPO" && bash "$CLEAN" ) >/dev/null 2>&1
assert_ok $? "clean succeeds"

assert_absent "$WT" "owned worktree removed"
assert_exists "$REPO/docs/looptesting/runs/round-1.md" "evidence preserved"
assert_absent "$REPO/docs/looptesting/.active" "stop-gate sentinel disarmed by clean"
assert_absent "$REPO/docs/looptesting/.gate-count" "gate counter removed by clean"
# qa branch (holds fix commits) must be kept
if ( cd "$REPO" && git rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 ); then
  PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: qa branch must be kept" >&2; fi

# owned process stopped, foreign process untouched
if kill -0 "$owned_pid" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "  FAIL: owned process should be stopped" >&2; else PASS=$((PASS+1)); fi
if kill -0 "$foreign_pid" 2>/dev/null; then
  PASS=$((PASS+1)); kill "$foreign_pid" 2>/dev/null; else
  FAIL=$((FAIL+1)); echo "  FAIL: foreign process must NOT be stopped" >&2; fi
# SIGTERM-ignoring recorded process must be escalated to SIGKILL
if kill -0 "$stubborn_pid" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "  FAIL: SIGTERM-ignoring process should be SIGKILLed" >&2; kill -9 "$stubborn_pid" 2>/dev/null
else PASS=$((PASS+1)); fi
# forked worker child of a recorded server must NOT survive cleanup (DR-1)
if [ -n "$worker_pid" ] && kill -0 "$worker_pid" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "  FAIL: forked worker child leaked past cleanup (pid $worker_pid)" >&2; kill -9 "$worker_pid" 2>/dev/null
else PASS=$((PASS+1)); fi

# idempotent: second clean is a no-op success
( cd "$REPO" && bash "$CLEAN" ) >/dev/null 2>&1
assert_ok $? "second clean is idempotent"

# --- R57 (NEW-1): clean invoked from INSIDE the worktree must still clean ------
# Old behavior: TOP resolved to the worktree, the marker lookup missed the main
# repo's marker, and the fail-closed "deleting nothing" path returned exit 0 —
# a FAKE success that left the worktree (and any recorded processes) behind.
WS2=$(mk_ws); trap 'rm -rf "$WS" "$WS2"' EXIT
REPO2="$WS2/proj"
WT2="$WS2/proj-qa-loop"
( cd "$REPO2" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup for the worktree-cwd clean case"
assert_exists "$WT2" "worktree exists before the worktree-cwd clean"
( cd "$WT2" && bash "$CLEAN" ) >/dev/null 2>&1
assert_ok $? "clean from inside the worktree exits 0 (R57)"
assert_absent "$WT2" "worktree removed even when clean ran from inside it (R57)"
assert_absent "$REPO2/docs/looptesting/.active" "sentinel disarmed by worktree-cwd clean (R57)"
assert_file_contains "$REPO2/docs/looptesting/.sandbox/ownership.env" "CLEANED_AT=" "CLEANED_AT recorded on the MAIN-tree marker (R57)"

report "clean.test.sh"
