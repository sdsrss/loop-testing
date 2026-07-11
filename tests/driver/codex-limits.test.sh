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

report "codex-limits.test.sh"
