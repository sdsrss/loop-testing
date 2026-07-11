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

report "codex-limits.test.sh"
