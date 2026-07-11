#!/usr/bin/env bash
# unattended-loop.sh: stop immediately on a terminal STATE; drive RUNNING to
# CONVERGED; write per-session driver.log lines.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# A. terminal status already present -> exit 0, launch zero sessions
WS=$(mk_proj); trap 'rm -rf "$WS"' EXIT
stub=$(write_stub "$WS")
write_state "$WS" CONVERGED 4
bash "$DRIVER" --project "$WS" --claude-bin "$stub" >/dev/null 2>&1
assert_rc $? 0 "terminal STATE -> exit 0"
assert_eq "0" "$(sessions_in_log "$WS")" "no session launched when already terminal"

# B. RUNNING -> converge at round 2 (two sessions), exit 0
WS2=$(mk_proj); trap 'rm -rf "$WS" "$WS2"' EXIT
stub=$(write_stub "$WS2")
write_state "$WS2" RUNNING 0
STUB_CONVERGE_AT=2 bash "$DRIVER" --project "$WS2" --claude-bin "$stub" >/dev/null 2>&1
assert_rc $? 0 "RUNNING driven to CONVERGED -> exit 0"
assert_eq "2" "$(sessions_in_log "$WS2")" "exactly 2 sessions to converge"
assert_eq "CONVERGED" "$(grep -aE '^status:' "$WS2/docs/looptesting/STATE.md" | sed 's/^status:[[:space:]]*//' | tr -d '[:space:]')" "final STATE is CONVERGED"

# C. driver.log line format + append
assert_file_contains "$WS2/docs/looptesting/driver.log" "session 1: exit=0 round=1 issues=1 status=RUNNING" "driver.log session-1 line"
assert_file_contains "$WS2/docs/looptesting/driver.log" "session 2: exit=0 round=2 issues=2 status=CONVERGED" "driver.log session-2 line"
assert_file_contains "$WS2/docs/looptesting/driver.log" "driver end:" "driver.log end line"

report "driver-terminal.test.sh"
