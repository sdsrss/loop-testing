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
# `-f` alone is satisfied by the very outcome this case exists to prevent: a
# stealing driver deletes the holder's pid file and writes its own, so the file
# is still there. Assert the CONTENT — the holder's pid, unchanged.
if grep -qx 1 "$WS1/docs/looptesting/.driver.lock/pid" 2>/dev/null; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: the refused run replaced the other holder's pid file with its own" >&2; fi

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

# --- cases 4-6: a probe that cannot answer must not answer "gone" ------------
# The two drivers carry byte-identical copies of holder_state, so these mirror
# lock-holder-identity.test.sh's cases 4-6 exactly. Without them a fix applied
# to one copy and not the other would be caught by nothing: the parity check in
# setup-marker-integrity only compares one-line function definitions.
#
# The assertions pin the message text on purpose: both refusals are `die`, both
# exit 2, and both name the holder pid and the lock path, so a case asserting
# only the exit code stays green whether the refusal fired for "it is alive" or
# for "I cannot tell" — including if the canary wrongly reported every holder as
# unknown.
if [ "$(id -u 2>/dev/null)" = "0" ]; then
  echo "  note: running as root — 'kill -0 1' succeeds, so cases 4 and 6 cannot reach the probes they test; skipped"
else
  # --- case 4: a procfs that hides other accounts' processes (hidepid=2) ------
  WS4=$(mk_proj); WS_ALL="$WS_ALL $WS4"
  mkdir -p "$WS4/docs/looptesting/.driver.lock" "$WS4/fakeproc/self"
  echo "1" > "$WS4/docs/looptesting/.driver.lock/pid"
  if [ -d "$WS4/fakeproc/self" ] && [ ! -e "$WS4/fakeproc/1" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: fixture: the blind-procfs model was not built as described" >&2; fi
  stub=$(write_stub "$WS4"); write_state "$WS4" RUNNING 0
  LOOP_TESTING_PROCFS="$WS4/fakeproc" bash "$CODEX_DRIVER" --project "$WS4" \
    --codex-bin "$stub" --no-protect --max-sessions 1 > "$WS4/out.txt" 2>&1
  assert_rc $? 2 "a holder invisible to a hidepid procfs is refused, not stolen"
  assert_file_contains "$WS4/out.txt" "no way to tell" \
    "and it is the CANNOT-TELL refusal that fired, not the it-is-alive one"
  if grep -qx 1 "$WS4/docs/looptesting/.driver.lock/pid" 2>/dev/null; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: the live holder's lock was stolen through a blind procfs" >&2; fi

  # --- case 5: control — a procfs that CAN answer still reports gone ---------
  WS5=$(mk_proj); WS_ALL="$WS_ALL $WS5"
  mkdir -p "$WS5/docs/looptesting/.driver.lock" "$WS5/fakeproc/self" "$WS5/fakeproc/1"
  DEAD5="$(bash -c 'echo $$')"
  echo "$DEAD5" > "$WS5/docs/looptesting/.driver.lock/pid"
  if [ -e "$WS5/fakeproc/1" ] && [ ! -e "$WS5/fakeproc/$DEAD5" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: fixture: the sighted-procfs model was not built as described" >&2; fi
  stub=$(write_stub "$WS5"); write_state "$WS5" RUNNING 0
  STUB_CONVERGE_AT=1 LOOP_TESTING_PROCFS="$WS5/fakeproc" bash "$CODEX_DRIVER" --project "$WS5" \
    --codex-bin "$stub" --no-protect --max-sessions 3 >/dev/null 2>&1
  assert_rc $? 0 "a procfs that can see PID 1 still reports a genuinely dead holder as gone"

  # --- case 6: the ps arm, the only liveness path on macOS -------------------
  WS6=$(mk_proj); WS_ALL="$WS_ALL $WS6"
  mkdir -p "$WS6/docs/looptesting/.driver.lock" "$WS6/shim"
  echo "1" > "$WS6/docs/looptesting/.driver.lock/pid"
  REAL_PS6="$(command -v ps)"
  printf '#!/usr/bin/env bash\ncase " $* " in *" -p "*) exit 1 ;; esac\nexec %s "$@"\n' \
    "$REAL_PS6" > "$WS6/shim/ps"
  chmod +x "$WS6/shim/ps"
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
    bash "$CODEX_DRIVER" --project "$WS6" --codex-bin "$stub" --no-protect \
    --max-sessions 1 > "$WS6/out.txt" 2>&1
  assert_rc $? 2 "a ps that cannot answer is refused, not read as 'no such process'"
  assert_file_contains "$WS6/out.txt" "no way to tell" \
    "and again it is the CANNOT-TELL refusal that fired"
  if grep -qx 1 "$WS6/docs/looptesting/.driver.lock/pid" 2>/dev/null; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: the live holder's lock was stolen through a blind ps" >&2; fi
fi

report "codex-lock-holder-identity.test.sh"
