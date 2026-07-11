#!/usr/bin/env bash
# ledger-gate.sh: deny VERIFIED-without-replay writes (Write/Edit/Bash), never
# false-deny normal writes, honor escape hatch, fail open on bad input.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

issues_path() { echo "$1/docs/looptesting/ISSUES.md"; }

# 1. Edit stamping VERIFIED on ISSUE-003 with NO replay footprint -> deny
WS=$(mk_lt); trap 'rm -rf "$WS"' EXIT
json="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$(issues_path "$WS")\",\"new_string\":\"### ISSUE-003 | P1 | VERIFIED | fixed dup id\"}}"
run_ledger "$WS" "$json"; assert_rc $? 2 "Edit VERIFIED w/o replay footprint -> deny"

# 2. Same edit, but runs/ has a replay record for ISSUE-003 -> allow
WS2=$(mk_lt); trap 'rm -rf "$WS" "$WS2"' EXIT
echo "replayed ISSUE-003: add A;add B -> ids unique (pass)" > "$WS2/docs/looptesting/runs/round-2.md"
json="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$(issues_path "$WS2")\",\"new_string\":\"### ISSUE-003 | P1 | VERIFIED | fixed\"}}"
run_ledger "$WS2" "$json"; assert_rc $? 0 "Edit VERIFIED WITH replay footprint -> allow"

# 3. Bash echo-append writing VERIFIED for ISSUE-004, no footprint -> deny
WS3=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3"' EXIT
json='{"tool_name":"Bash","tool_input":{"command":"echo \"### ISSUE-004 | P1 | VERIFIED |\" >> docs/looptesting/ISSUES.md"}}'
run_ledger "$WS3" "$json"; assert_rc $? 2 "Bash VERIFIED write w/o footprint -> deny"

# 4. Normal Edit adding an OPEN issue -> allow (no false positive)
WS4=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4"' EXIT
json="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$(issues_path "$WS4")\",\"new_string\":\"### ISSUE-005 | P2 | OPEN | new finding\"}}"
run_ledger "$WS4" "$json"; assert_rc $? 0 "normal OPEN write -> allow"

# 5. Write to a runs/ file (not ISSUES.md) containing VERIFIED -> allow
WS5=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5"' EXIT
json="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WS5/docs/looptesting/runs/round-3.md\",\"content\":\"ISSUE-006 VERIFIED via replay\"}}"
run_ledger "$WS5" "$json"; assert_rc $? 0 "VERIFIED in runs/ file (not ledger) -> allow"

# 6. Escape hatch env -> allow even the cheat write
WS6=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6"' EXIT
json="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$(issues_path "$WS6")\",\"new_string\":\"### ISSUE-007 | P0 | VERIFIED | x\"}}"
( cd "$WS6" && LOOP_TESTING_DISABLE_LEDGER_GATE=1 printf '%s' "$json" | LOOP_TESTING_DISABLE_LEDGER_GATE=1 bash "$LEDGER" ) >/dev/null 2>&1
assert_rc $? 0 "escape hatch disables gate -> allow"

# 7. Unparseable stdin -> fail open (allow)
WS7=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7"' EXIT
run_ledger "$WS7" 'not-json-at-all'; assert_rc $? 0 "unparseable stdin -> fail open"

# 8. MultiEdit stamping VERIFIED w/o footprint -> deny (edits[].new_string seen)
WS8=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8"' EXIT
json="{\"tool_name\":\"MultiEdit\",\"tool_input\":{\"file_path\":\"$(issues_path "$WS8")\",\"edits\":[{\"new_string\":\"### ISSUE-008 | P1 | VERIFIED | y\"}]}}"
run_ledger "$WS8" "$json"; assert_rc $? 2 "MultiEdit VERIFIED w/o footprint -> deny"

report "ledger-gate.test.sh"
