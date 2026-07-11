#!/usr/bin/env bash
# unattended-loop.sh fail-closed limits: no-progress breaker, max-sessions cap,
# max-minutes cap.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# A. NO_PROGRESS: two consecutive sessions with no change -> exit 5
WS=$(mk_proj); trap 'rm -rf "$WS"' EXIT
stub=$(write_stub "$WS")
write_state "$WS" RUNNING 0
STUB_NO_PROGRESS=1 bash "$DRIVER" --project "$WS" --claude-bin "$stub" --max-sessions 10 >/dev/null 2>&1
assert_rc $? 5 "no-progress circuit breaker -> exit 5"
assert_eq "2" "$(sessions_in_log "$WS")" "breaker fires after 2 stuck sessions"
assert_file_contains "$WS/docs/looptesting/driver.log" "NO_PROGRESS" "driver.log records NO_PROGRESS"

# B. max-sessions cap without convergence -> exit 3
WS2=$(mk_proj); trap 'rm -rf "$WS" "$WS2"' EXIT
stub=$(write_stub "$WS2")
write_state "$WS2" RUNNING 0
# stub advances round each call (never converges) so no-progress never fires
bash "$DRIVER" --project "$WS2" --claude-bin "$stub" --max-sessions 3 >/dev/null 2>&1
assert_rc $? 3 "hit --max-sessions -> exit 3"
assert_eq "3" "$(sessions_in_log "$WS2")" "exactly max-sessions sessions ran"
assert_file_contains "$WS2/docs/looptesting/driver.log" "hit --max-sessions" "driver.log records max-sessions INCOMPLETE"

# C. max-minutes cap (0 minutes) -> exit 4 before any session
WS3=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3"' EXIT
stub=$(write_stub "$WS3")
write_state "$WS3" RUNNING 0
bash "$DRIVER" --project "$WS3" --claude-bin "$stub" --max-minutes 0 >/dev/null 2>&1
assert_rc $? 4 "hit --max-minutes -> exit 4"
assert_eq "0" "$(sessions_in_log "$WS3")" "no session launched past the time budget"

# D. usage error: missing --project -> exit 2
bash "$DRIVER" --claude-bin /bin/true >/dev/null 2>&1
assert_rc $? 2 "missing --project -> exit 2"

# E. value-taking flag as the LAST token must fail-closed (exit 2), never hang.
# (Regression guard: `shift 2` on a 1-arg tail is a no-op -> infinite loop.)
timeout 10 bash "$DRIVER" --project >/dev/null 2>&1
assert_rc $? 2 "trailing --project -> exit 2 (no hang)"
timeout 10 bash "$DRIVER" --project /tmp --max-turns >/dev/null 2>&1
assert_rc $? 2 "trailing --max-turns -> exit 2 (no hang)"

report "driver-limits.test.sh"
