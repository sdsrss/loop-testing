#!/usr/bin/env bash
# D-06: the driver lock is stolen from a holder that `kill -0` cannot signal.
#
# `kill -0 PID` fails for two unrelated reasons: ESRCH (the process is gone) and
# EPERM (it is alive and owned by another user). acquire_lock treated both as
# "crashed driver" and stole the lock. The holder is then still running, so two
# drivers — both launched with bypassPermissions — write the same STATE.md,
# ISSUES.md, driver.log and worktree. The concurrency guard's whole purpose is to
# make that impossible, and the case it fails on is not exotic: a driver started
# by root, by a systemd unit, or by another account on a shared machine.
#
# `ps -p` and procfs answer "does this PID exist" without needing permission to
# signal it, which is the question the lock is actually asking.
#
# FIXTURE: PID 1. It always exists and is owned by root, so `kill -0 1` from an
# ordinary account fails with EPERM — the exact case, with no privileges needed
# to build it. Running AS root makes `kill -0 1` succeed, and the assertions then
# hold for the ordinary "live holder" reason instead; the suite says so rather
# than reporting coverage it does not have.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WS_ALL=""
cleanup_all() { [ -n "$WS_ALL" ] && rm -rf $WS_ALL; }   # word-split on purpose
trap cleanup_all EXIT

if [ "$(id -u 2>/dev/null)" = "0" ]; then
  echo "  note: running as root — 'kill -0 1' succeeds here, so case 1 asserts the outcome but does not exercise the EPERM path"
fi

# --- case 1: a holder that exists but cannot be signalled is NOT stolen -------
WS1=$(mk_proj); WS_ALL="$WS_ALL $WS1"
mkdir -p "$WS1/docs/looptesting/.driver.lock"
echo "1" > "$WS1/docs/looptesting/.driver.lock/pid"
stub=$(write_stub "$WS1"); write_state "$WS1" RUNNING 0
bash "$DRIVER" --project "$WS1" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_rc $? 2 "a lock holder that exists but cannot be signalled is refused, not stolen"
assert_eq "0" "$(sessions_in_log "$WS1")" "no session launched against the held lock"
if [ -f "$WS1/docs/looptesting/.driver.lock/pid" ]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: the refused run removed the other holder's lock" >&2; fi

# --- case 2: control — a genuinely dead holder is still stolen ----------------
# Case 1 passes for a driver that never steals any lock, which would lock a
# project out after every crash. The dead PID is a just-exited child; a
# background job would inherit the EXIT trap and delete the workspace mid-test.
WS2=$(mk_proj); WS_ALL="$WS_ALL $WS2"
mkdir -p "$WS2/docs/looptesting/.driver.lock"
echo "$(bash -c 'echo $$')" > "$WS2/docs/looptesting/.driver.lock/pid"
stub=$(write_stub "$WS2"); write_state "$WS2" RUNNING 0
STUB_CONVERGE_AT=1 bash "$DRIVER" --project "$WS2" --claude-bin "$stub" --max-sessions 3 >/dev/null 2>&1
assert_rc $? 0 "a lock whose holder really is gone is still stolen (exit 0)"
if [ -e "$WS2/docs/looptesting/.driver.lock" ]; then
  FAIL=$((FAIL+1)); echo "  FAIL: lock not released on normal exit" >&2; else PASS=$((PASS+1)); fi

# --- case 3: the refusal names the pid it refused for ------------------------
# The user's only route out of a lock held by an account they cannot signal is to
# remove it by hand, so the message has to say which pid it is talking about.
WS3=$(mk_proj); WS_ALL="$WS_ALL $WS3"
mkdir -p "$WS3/docs/looptesting/.driver.lock"
echo "1" > "$WS3/docs/looptesting/.driver.lock/pid"
stub=$(write_stub "$WS3"); write_state "$WS3" RUNNING 0
bash "$DRIVER" --project "$WS3" --claude-bin "$stub" --max-sessions 1 > "$WS3/out.txt" 2>&1
assert_file_contains "$WS3/out.txt" "pid 1" "the refusal names the holder pid"
assert_file_contains "$WS3/out.txt" ".driver.lock" "and the lock path to remove by hand"

report "lock-holder-identity.test.sh"
