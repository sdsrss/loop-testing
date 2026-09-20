#!/usr/bin/env bash
# D-06, codex side. The two drivers keep this guard identical, so the defect and
# the fix are identical too: `kill -0` fails for ESRCH (gone) and EPERM (alive,
# owned by another user), and acquire_lock stole the lock on both — putting two
# bypassPermissions drivers on one STATE.md, ISSUES.md and worktree.
#
# Rationale, fixture choice (PID 1) and the root caveat are documented once, in
# lock-holder-identity.test.sh; this suite is its mirror for unattended-codex.sh.
set -u
. "$(cd "$(dirname "$0")" && pwd)/codex-lib.sh"

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
bash "$CODEX_DRIVER" --project "$WS1" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_rc $? 2 "a lock holder that exists but cannot be signalled is refused, not stolen"
assert_eq "0" "$(sessions_in_log "$WS1")" "no session launched against the held lock"
if [ -f "$WS1/docs/looptesting/.driver.lock/pid" ]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: the refused run removed the other holder's lock" >&2; fi

# --- case 2: control — a genuinely dead holder is still stolen ----------------
WS2=$(mk_proj); WS_ALL="$WS_ALL $WS2"
mkdir -p "$WS2/docs/looptesting/.driver.lock"
echo "$(bash -c 'echo $$')" > "$WS2/docs/looptesting/.driver.lock/pid"
stub=$(write_stub "$WS2"); write_state "$WS2" RUNNING 0
STUB_CONVERGE_AT=1 bash "$CODEX_DRIVER" --project "$WS2" --codex-bin "$stub" --no-protect --max-sessions 3 >/dev/null 2>&1
assert_rc $? 0 "a lock whose holder really is gone is still stolen (exit 0)"
if [ -e "$WS2/docs/looptesting/.driver.lock" ]; then
  FAIL=$((FAIL+1)); echo "  FAIL: lock not released on normal exit" >&2; else PASS=$((PASS+1)); fi

# --- case 3: the refusal names the pid it refused for ------------------------
WS3=$(mk_proj); WS_ALL="$WS_ALL $WS3"
mkdir -p "$WS3/docs/looptesting/.driver.lock"
echo "1" > "$WS3/docs/looptesting/.driver.lock/pid"
stub=$(write_stub "$WS3"); write_state "$WS3" RUNNING 0
bash "$CODEX_DRIVER" --project "$WS3" --codex-bin "$stub" --no-protect --max-sessions 1 > "$WS3/out.txt" 2>&1
assert_file_contains "$WS3/out.txt" "pid 1" "the refusal names the holder pid"
assert_file_contains "$WS3/out.txt" ".driver.lock" "and the lock path to remove by hand"

report "codex-lock-holder-identity.test.sh"
