#!/usr/bin/env bash
# unattended-loop.sh: stop immediately on a terminal STATE; drive RUNNING to
# CONVERGED; write per-session driver.log lines.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# Without timeout/gtimeout the driver refuses to start (DR-7), so every case here
# would measure that refusal; skip the file whole via the run-all protocol.
require_watchdog_binary

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

# D. an annotated `round:` must read as the round number, not a digit soup.
# `round: 3 of 12` used to parse as 312 (every non-digit stripped, both numbers
# glued), so driver.log and the summary line reported a round that never existed.
WS3=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3"' EXIT
stub=$(write_stub "$WS3")
cat > "$WS3/docs/looptesting/STATE.md" <<'EOF'
# STATE
round: 3 of 12
converged_streak: 0
status: CONVERGED
max_rounds: 12
EOF
OUT3=$(bash "$DRIVER" --project "$WS3" --claude-bin "$stub" 2>&1)
assert_rc $? 0 "annotated round + terminal status -> exit 0"
case "$OUT3" in
  *"round=3,"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: annotated round must report round=3 — got: $OUT3" >&2 ;;
esac
# driver.log is the durable artifact — normalizing only the stdout line leaves the
# record that outlives the session saying round=3of12.
assert_file_contains "$WS3/docs/looptesting/driver.log" "round=3 " "driver.log records the normalized round too"

report "driver-terminal.test.sh"
