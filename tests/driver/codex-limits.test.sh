#!/usr/bin/env bash
# unattended-codex.sh: fail-closed limits — no-progress breaker, max-sessions,
# max-minutes, argument validation. Stub codex + --no-protect throughout.
set -u
. "$(cd "$(dirname "$0")" && pwd)/codex-lib.sh"

# A. no-progress: two consecutive sessions with no change -> exit 5
WS=$(mk_proj); trap 'rm -rf "$WS"' EXIT
stub=$(write_stub "$WS")
write_state "$WS" RUNNING 1
STUB_NO_PROGRESS=1 bash "$CODEX_DRIVER" --project "$WS" --codex-bin "$stub" --no-protect >/dev/null 2>&1
assert_rc $? 5 "no-progress breaker -> exit 5"
assert_file_contains "$WS/docs/looptesting/driver.log" "NO_PROGRESS" "driver.log records NO_PROGRESS"

# B. max-sessions before terminal -> exit 3, launches exactly N sessions
WS2=$(mk_proj); trap 'rm -rf "$WS" "$WS2"' EXIT
stub=$(write_stub "$WS2")
write_state "$WS2" RUNNING 0
# stub advances round each call but never converges (STUB_CONVERGE_AT unset=9999)
bash "$CODEX_DRIVER" --project "$WS2" --codex-bin "$stub" --no-protect --max-sessions 3 >/dev/null 2>&1
assert_rc $? 3 "max-sessions cap -> exit 3"
assert_eq "3" "$(sessions_in_log "$WS2")" "exactly 3 sessions before cap"

# C. max-minutes=0 -> exit 4 immediately, zero sessions
WS3=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3"' EXIT
stub=$(write_stub "$WS3")
write_state "$WS3" RUNNING 0
bash "$CODEX_DRIVER" --project "$WS3" --codex-bin "$stub" --no-protect --max-minutes 0 >/dev/null 2>&1
assert_rc $? 4 "max-minutes=0 -> exit 4"
assert_eq "0" "$(sessions_in_log "$WS3")" "no session launched when out of time"

# D. missing --project -> usage error exit 2
bash "$CODEX_DRIVER" --codex-bin /bin/true --no-protect >/dev/null 2>&1
assert_rc $? 2 "missing --project -> exit 2"

# E. non-integer --max-minutes -> usage error exit 2
WS4=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4"' EXIT
bash "$CODEX_DRIVER" --project "$WS4" --codex-bin /bin/true --no-protect --max-minutes abc >/dev/null 2>&1
assert_rc $? 2 "non-integer --max-minutes -> exit 2"

# F. value-taking flag as the LAST token must fail-closed (exit 2), never hang.
# (Regression guard: `shift 2` on a 1-arg tail is a no-op -> infinite loop.)
timeout 10 bash "$CODEX_DRIVER" --project >/dev/null 2>&1
assert_rc $? 2 "trailing --project -> exit 2 (no hang)"
timeout 10 bash "$CODEX_DRIVER" --project /tmp --max-sessions >/dev/null 2>&1
assert_rc $? 2 "trailing --max-sessions -> exit 2 (no hang)"

# G. Watchdog binary detection falls back to `gtimeout` when GNU `timeout` is
# absent (macOS/Homebrew coreutils). Evaluate the detection logic under a PATH
# where only a stub gtimeout exists, then assert the driver actually carries the
# fallback branch (kept identical to unattended-loop.sh).
WS5=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5"' EXIT
mkdir -p "$WS5/bin"; printf '#!/bin/sh\nexit 0\n' > "$WS5/bin/gtimeout"; chmod +x "$WS5/bin/gtimeout"
# Subshell with PATH restricted to the stub dir; command/echo are builtins so no
# real coreutils are needed to resolve them.
got=$(
  PATH="$WS5/bin"
  TIMEOUT_BIN=""
  if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN=timeout
  elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN=gtimeout; fi
  echo "$TIMEOUT_BIN"
)
assert_eq "gtimeout" "$got" "watchdog detection falls back to gtimeout when timeout absent"
assert_file_contains "$CODEX_DRIVER" "elif command -v gtimeout" "codex driver carries the gtimeout fallback branch"

# H. Progress via convergence + evidence only (round/issues static, streak + runs/
#    evidence advance) must NOT trip NO_PROGRESS (audit A3). Mirrors loop driver F.
WS6=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6"' EXIT
stub=$(write_stub "$WS6")
write_state "$WS6" RUNNING 1
STUB_STREAK_ONLY=1 bash "$CODEX_DRIVER" --project "$WS6" --codex-bin "$stub" --no-protect --max-sessions 3 >/dev/null 2>&1
assert_rc $? 3 "streak+evidence progress (round/issues static) -> max-sessions, not NO_PROGRESS"

# I. STATE.md never created -> fail fast after exactly 1 session, not 2 (audit C9).
WS7=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7"' EXIT
stub=$(write_stub "$WS7")
STUB_NO_STATE=1 bash "$CODEX_DRIVER" --project "$WS7" --codex-bin "$stub" --no-protect --max-sessions 5 >/dev/null 2>&1
assert_rc $? 5 "absent STATE.md -> exit 5"
assert_eq "1" "$(sessions_in_log "$WS7")" "exits after exactly 1 STATE-less session (not 2)"

# J. Round-0 progress: round/issues/streak static and NO runs/ file, but PLAN.md +
#    FEATURE_MATRIX.md grow each session. Must NOT trip NO_PROGRESS (audit PL-2).
#    Mirrors loop driver H.
WS8=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8"' EXIT
stub=$(write_stub "$WS8")
write_state "$WS8" RUNNING 0
STUB_BOOTSTRAP=1 bash "$CODEX_DRIVER" --project "$WS8" --codex-bin "$stub" --no-protect --max-sessions 3 >/dev/null 2>&1
assert_rc $? 3 "round-0 bootstrap progress (PLAN/FEATURE_MATRIX grow) -> max-sessions, not NO_PROGRESS"

# K. driver.log not writable -> die exit 2 BEFORE any session (parity with the loop
#    driver's writability guard; R16 gained this for codex but had no dedicated test).
WS9=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9"' EXIT
mkdir "$WS9/docs/looptesting/driver.log"   # append to a directory fails -> guard fires
stub=$(write_stub "$WS9")
bash "$CODEX_DRIVER" --project "$WS9" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_rc $? 2 "unwritable driver.log -> die exit 2"
assert_eq "0" "$(sessions_in_log "$WS9")" "no session launched when driver.log is unwritable"

# L. Concurrency guard: a second codex driver is refused while a LIVE holder holds
#    the lock -> exit 2 (audit DR-4; mirrors loop driver J). Live holder = $$.
WS10=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10"' EXIT
mkdir -p "$WS10/docs/looptesting/.driver.lock"
echo "$$" > "$WS10/docs/looptesting/.driver.lock/pid"
stub=$(write_stub "$WS10"); write_state "$WS10" RUNNING 0
bash "$CODEX_DRIVER" --project "$WS10" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_rc $? 2 "live driver holds the lock -> concurrent codex run refused (exit 2)"
assert_eq "0" "$(sessions_in_log "$WS10")" "no session launched while the lock is held"

# M. Stale lock (dead holder) stolen; run proceeds and releases the lock on exit
#    (audit DR-4; mirrors loop driver K). Dead holder = a just-exited child PID.
WS11=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11"' EXIT
mkdir -p "$WS11/docs/looptesting/.driver.lock"
echo "$(bash -c 'echo $$')" > "$WS11/docs/looptesting/.driver.lock/pid"
stub=$(write_stub "$WS11"); write_state "$WS11" RUNNING 0
STUB_CONVERGE_AT=1 bash "$CODEX_DRIVER" --project "$WS11" --codex-bin "$stub" --no-protect --max-sessions 3 >/dev/null 2>&1
assert_rc $? 0 "stale lock stolen -> run proceeds to convergence (exit 0)"
if [ -e "$WS11/docs/looptesting/.driver.lock" ]; then FAIL=$((FAIL+1)); echo "  FAIL: lock not released on normal exit" >&2; else PASS=$((PASS+1)); fi

# N. Fail-closed: a lock dir whose holder PID is unreadable/absent must be REFUSED,
#    not stolen (DR-4 hardening from code review; mirrors loop driver L).
WS12=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12"' EXIT
mkdir -p "$WS12/docs/looptesting/.driver.lock"   # lock dir present, NO pid file
stub=$(write_stub "$WS12"); write_state "$WS12" RUNNING 0
bash "$CODEX_DRIVER" --project "$WS12" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_rc $? 2 "lock with no readable holder PID -> refused (fail-closed), not stolen"
assert_eq "0" "$(sessions_in_log "$WS12")" "no session launched on an ambiguous lock"

report "codex-limits.test.sh"
