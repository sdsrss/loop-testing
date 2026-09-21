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
# `-f` alone is satisfied by the very outcome this case exists to prevent: a
# stealing driver deletes the holder's pid file and writes its own, so the file
# is still there. Assert the CONTENT — the holder's pid, unchanged.
if grep -qx 1 "$WS1/docs/looptesting/.driver.lock/pid" 2>/dev/null; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: the refused run replaced the other holder's pid file with its own" >&2; fi

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

# --- cases 4-6: a probe that cannot answer must not answer "gone" ------------
# Case 1 covers a procfs that CAN see the holder. These cover the ones that
# cannot, where the first fix replaced one probe that fails to answer with two
# more that also fail to answer — and all three failures resolved to `gone`, the
# verdict that authorises `rm -rf "$LOCK_DIR"`.
#
# WHY THE ASSERTIONS PIN THE MESSAGE TEXT: both refusals are `die`, both exit 2,
# and both name the holder pid and the lock path. A case that asserts only the
# exit code or only "the lock survived" passes identically whether the refusal
# fired for "it is alive" or for "I cannot tell" — so it would stay green if the
# canary below mistakenly reported every holder as unknown, and tell us nothing.
#
# LOOP_TESTING_PROCFS is the seam that makes any of this reachable: on Linux
# `[ -d /proc/self ]` is always true, so without it the ps arm — the only
# liveness path on macOS, and CI is ubuntu-only — can never be exercised at all.
if [ "$(id -u 2>/dev/null)" = "0" ]; then
  echo "  note: running as root — 'kill -0 1' succeeds, so cases 4 and 6 cannot reach the probes they test; skipped"
else
  # --- case 4: a procfs that hides other accounts' processes (hidepid=2) ------
  # `self` is present (the probe is selected) but PID 1 is not visible, which is
  # what hidepid=2 shows a non-root reader. The holder must read as unknown, not
  # gone: it is PID 1, it is alive, and it is simply invisible here.
  WS4=$(mk_proj); WS_ALL="$WS_ALL $WS4"
  mkdir -p "$WS4/docs/looptesting/.driver.lock" "$WS4/fakeproc/self"
  echo "1" > "$WS4/docs/looptesting/.driver.lock/pid"
  # The fixture must be the condition it claims: self visible, PID 1 not.
  if [ -d "$WS4/fakeproc/self" ] && [ ! -e "$WS4/fakeproc/1" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: fixture: the blind-procfs model was not built as described" >&2; fi
  stub=$(write_stub "$WS4"); write_state "$WS4" RUNNING 0
  LOOP_TESTING_PROCFS="$WS4/fakeproc" bash "$DRIVER" --project "$WS4" \
    --claude-bin "$stub" --max-sessions 1 > "$WS4/out.txt" 2>&1
  assert_rc $? 2 "a holder invisible to a hidepid procfs is refused, not stolen"
  assert_file_contains "$WS4/out.txt" "no way to tell" \
    "and it is the CANNOT-TELL refusal that fired, not the it-is-alive one"
  if grep -qx 1 "$WS4/docs/looptesting/.driver.lock/pid" 2>/dev/null; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: the live holder's lock was stolen through a blind procfs" >&2; fi

  # --- case 5: control — a procfs that CAN answer still reports gone ---------
  # Without this, case 4 would also pass for a canary that reports every holder
  # as unknown, which would lock a project out after every crash.
  WS5=$(mk_proj); WS_ALL="$WS_ALL $WS5"
  mkdir -p "$WS5/docs/looptesting/.driver.lock" "$WS5/fakeproc/self" "$WS5/fakeproc/1"
  DEAD5="$(bash -c 'echo $$')"
  echo "$DEAD5" > "$WS5/docs/looptesting/.driver.lock/pid"
  if [ -e "$WS5/fakeproc/1" ] && [ ! -e "$WS5/fakeproc/$DEAD5" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: fixture: the sighted-procfs model was not built as described" >&2; fi
  stub=$(write_stub "$WS5"); write_state "$WS5" RUNNING 0
  STUB_CONVERGE_AT=1 LOOP_TESTING_PROCFS="$WS5/fakeproc" bash "$DRIVER" --project "$WS5" \
    --claude-bin "$stub" --max-sessions 3 >/dev/null 2>&1
  assert_rc $? 0 "a procfs that can see PID 1 still reports a genuinely dead holder as gone"

  # --- case 6: the ps arm, the only liveness path on macOS -------------------
  # Procfs is pointed at a path that does not exist, so the ps arm is selected.
  # The shim fails `ps -p` for EVERY pid, modelling a ps that cannot answer at
  # all; its self-test on our own pid then fails too, so the verdict is unknown.
  WS6=$(mk_proj); WS_ALL="$WS_ALL $WS6"
  mkdir -p "$WS6/docs/looptesting/.driver.lock" "$WS6/shim"
  echo "1" > "$WS6/docs/looptesting/.driver.lock/pid"
  REAL_PS6="$(command -v ps)"
  printf '#!/usr/bin/env bash\ncase " $* " in *" -p "*) exit 1 ;; esac\nexec %s "$@"\n' \
    "$REAL_PS6" > "$WS6/shim/ps"
  chmod +x "$WS6/shim/ps"
  # The shim must be a shim, not a brick — proc_start uses ps too, and a blanket
  # failure would make these assertions pass for the wrong reason.
  PATH="$WS6/shim:$PATH" ps >/dev/null 2>&1
  assert_rc $? 0 "fixture: the ps shim delegates everything except -p"
  PATH="$WS6/shim:$PATH" ps -p "$$" >/dev/null 2>&1
  ps6rc=$?
  if [ "$ps6rc" -ne 0 ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1))
    echo "  FAIL: fixture: the ps shim did not fail -p, so case 6 would test nothing" >&2
  fi
  stub=$(write_stub "$WS6"); write_state "$WS6" RUNNING 0
  PATH="$WS6/shim:$PATH" LOOP_TESTING_PROCFS="$WS6/nonexistent-procfs" \
    bash "$DRIVER" --project "$WS6" --claude-bin "$stub" --max-sessions 1 > "$WS6/out.txt" 2>&1
  assert_rc $? 2 "a ps that cannot answer is refused, not read as 'no such process'"
  assert_file_contains "$WS6/out.txt" "no way to tell" \
    "and again it is the CANNOT-TELL refusal that fired"
  if grep -qx 1 "$WS6/docs/looptesting/.driver.lock/pid" 2>/dev/null; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: the live holder's lock was stolen through a blind ps" >&2; fi
fi

report "lock-holder-identity.test.sh"
