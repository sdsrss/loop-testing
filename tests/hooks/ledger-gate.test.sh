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

# 9. Edit setting the legit FIXED_UNVERIFIED status -> allow (word-boundary: the
#    substring VERIFIED inside FIXED_UNVERIFIED must NOT trigger a false-deny).
WS9=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9"' EXIT
json="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$(issues_path "$WS9")\",\"new_string\":\"### ISSUE-009 | P1 | FIXED_UNVERIFIED | fixed, awaiting replay\"}}"
run_ledger "$WS9" "$json"; assert_rc $? 0 "FIXED_UNVERIFIED write (word-boundary) -> allow, not false-deny"

# 10. Minimal Edit old=FIXED_UNVERIFIED new=VERIFIED: introduced text has no ID,
#     ID resolved from the ledger block enclosing old_string; no footprint -> deny.
WS10=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10"' EXIT
printf '# ISSUES\n\n### ISSUE-010 | P1 | FIXED_UNVERIFIED | fixed\n- 验证: 待复验\n' > "$WS10/docs/looptesting/ISSUES.md"
json="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$(issues_path "$WS10")\",\"old_string\":\"FIXED_UNVERIFIED\",\"new_string\":\"VERIFIED\"}}"
run_ledger "$WS10" "$json"; assert_rc $? 2 "minimal VERIFIED edit, ID from context, no footprint -> deny"

# 11. Same minimal edit but ISSUE-010 HAS a replay footprint -> allow.
WS11=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11"' EXIT
printf '# ISSUES\n\n### ISSUE-010 | P1 | FIXED_UNVERIFIED | fixed\n' > "$WS11/docs/looptesting/ISSUES.md"
echo "replayed ISSUE-010 ok" > "$WS11/docs/looptesting/runs/round-1.md"
json="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$(issues_path "$WS11")\",\"old_string\":\"FIXED_UNVERIFIED\",\"new_string\":\"VERIFIED\"}}"
run_ledger "$WS11" "$json"; assert_rc $? 0 "minimal VERIFIED edit WITH footprint -> allow"

# 12. Bash writing a bare ISSUES.md (no docs/looptesting path, loop NOT armed) ->
#     allow. An unrelated project using the same ISSUE-NNN/VERIFIED convention must
#     not be false-denied by a bare-substring match.
WS12=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12"' EXIT
json='{"tool_name":"Bash","tool_input":{"command":"echo \"- ISSUE-99 VERIFIED\" >> ISSUES.md"}}'
run_ledger "$WS12" "$json"; assert_rc $? 0 "bare ISSUES.md write, loop not armed -> allow (no false-deny)"

# 13. Bash bare ISSUES.md BUT the loop IS armed (.active present) + no footprint ->
#     deny (a real in-loop cd-then-append is still caught).
WS13=$(mk_lt); arm "$WS13"; trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13"' EXIT
json='{"tool_name":"Bash","tool_input":{"command":"echo \"### ISSUE-013 | P1 | VERIFIED |\" >> ISSUES.md"}}'
run_ledger "$WS13" "$json"; assert_rc $? 2 "armed loop, bare ISSUES.md VERIFIED, no footprint -> deny"

# 14. Bash perl -i inlining a fabricated VERIFIED verdict on the ledger path, no
#     footprint -> deny (write-verb table now covers perl/mv/cp/dd/python) (C6).
WS14=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$WS14"' EXIT
json='{"tool_name":"Bash","tool_input":{"command":"perl -i -pe \"s/OPEN/VERIFIED/ if /ISSUE-014/\" docs/looptesting/ISSUES.md"}}'
run_ledger "$WS14" "$json"; assert_rc $? 2 "perl -i fabricating VERIFIED on ledger, no footprint -> deny"

# 15. OPEN issue whose TITLE column contains the word "VERIFIED" as prose (e.g.
#     "not yet VERIFIED by committee"). The status column is OPEN, so this is a
#     legitimate write and must be allowed — the status token is anchored to the
#     `| STATUS |` column, not matched anywhere on the line (HK-2).
WS15=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$WS14" "$WS15"' EXIT
json="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$(issues_path "$WS15")\",\"new_string\":\"### ISSUE-015 | P2 | OPEN | repro not yet VERIFIED by committee\"}}"
run_ledger "$WS15" "$json"; assert_rc $? 0 "OPEN issue with 'VERIFIED' in prose title -> allow (not false-deny)"

# 16. Same, lowercase "verified" in the title -> allow (case-sensitive: the status
#     token is always uppercase, so -i only false-matched prose) (HK-2).
WS16=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$WS14" "$WS15" "$WS16"' EXIT
json="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$(issues_path "$WS16")\",\"new_string\":\"### ISSUE-016 | P2 | OPEN | crash could not be verified yet\"}}"
run_ledger "$WS16" "$json"; assert_rc $? 0 "OPEN issue with 'verified' lowercase prose -> allow"

# 17. HK-7: hook run from an UNRELATED cwd with $CLAUDE_PROJECT_DIR pointing at the
#     workspace. A legitimate VERIFIED (replay footprint EXISTS in the workspace's
#     runs/) must be allowed — cwd-relative resolution used to look for runs/ under
#     the wrong directory and false-deny.
WS17=$(mk_lt); OTHER17=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-othercwd.XXXXXX")
trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$WS14" "$WS15" "$WS16" "$WS17" "$OTHER17"' EXIT
echo "replayed ISSUE-021: repro cmd -> pass" > "$WS17/docs/looptesting/runs/round-1.md"
json='{"tool_name":"Bash","tool_input":{"command":"printf \"### ISSUE-021 | P1 | VERIFIED | fixed\\n\" >> docs/looptesting/ISSUES.md"}}'
( cd "$OTHER17" && printf '%s' "$json" | CLAUDE_PROJECT_DIR="$WS17" bash "$LEDGER" ) >/dev/null 2>&1
assert_rc $? 0 "wrong cwd + CLAUDE_PROJECT_DIR: footprint in workspace runs/ -> allow (HK-7)"

# 18. HK-7 fail-open direction: an ARMED loop's bare-ISSUES.md VERIFIED write (no
#     footprint) must still be denied when the hook runs from an unrelated cwd —
#     cwd-relative resolution missed the .active sentinel and let it through.
WS18=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$WS14" "$WS15" "$WS16" "$WS17" "$OTHER17" "$WS18"' EXIT
: > "$WS18/docs/looptesting/.active"
json='{"tool_name":"Bash","tool_input":{"command":"echo \"### ISSUE-022 | P1 | VERIFIED | faked\" >> ISSUES.md"}}'
( cd "$OTHER17" && printf '%s' "$json" | CLAUDE_PROJECT_DIR="$WS18" bash "$LEDGER" ) >/dev/null 2>&1
assert_rc $? 2 "wrong cwd + CLAUDE_PROJECT_DIR: armed bare-ISSUES.md VERIFIED w/o footprint -> deny (HK-7)"

report "ledger-gate.test.sh"
