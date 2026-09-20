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

# 19. No jq AND no python3 -> the gate is documented to fail OPEN with a notice
#     ("a gate must never brick a session") — previously untested.
WS19=$(mk_lt); BINL=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-noparse.XXXXXX")
trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$WS14" "$WS15" "$WS16" "$WS17" "$OTHER17" "$WS18" "$WS19" "$BINL"' EXIT
for b in bash grep sed head cut tr cat rm date printf dirname; do
  p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$BINL/$b"
done
json='{"tool_name":"Bash","tool_input":{"command":"echo \"### ISSUE-030 | P1 | VERIFIED | faked\" >> docs/looptesting/ISSUES.md"}}'
err=$( cd "$WS19" && printf '%s' "$json" | env -u CLAUDE_PROJECT_DIR PATH="$BINL" bash "$LEDGER" 2>&1 >/dev/null ); rc=$?
assert_rc $rc 0 "no jq/python3 -> fail open (allow), never brick the session"
if printf '%s' "$err" | grep -q 'gate inactive'; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: fail-open must announce itself ('gate inactive'), got [$err]" >&2; fi

# ── H-01 / H-04 / H-05 (audit 2026-09-20): bind "write" to the verb, take the ID
#    from the ledger's leading column, and make in-place edits name their ID. ──
# Every case below shares one workspace: ISSUE-002 OPEN with NO footprint,
# ISSUE-003 FIXED_UNVERIFIED WITH a footprint.
WS20=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$WS14" "$WS15" "$WS16" "$WS17" "$OTHER17" "$WS18" "$WS19" "$BINL" "$WS20"' EXIT
printf '# ISSUES\n\n### ISSUE-002 | P1 | OPEN | dup ids\n### ISSUE-003 | P1 | FIXED_UNVERIFIED | crash\n' > "$WS20/docs/looptesting/ISSUES.md"
echo "replayed ISSUE-003: repro cmd -> pass" > "$WS20/docs/looptesting/runs/round-1.md"
run_ledger_err() { local ws="$1" json="$2"; ( cd "$ws" && printf '%s' "$json" | env -u CLAUDE_PROJECT_DIR bash "$LEDGER" 2>&1 >/dev/null ); }

# 20. H-01: a READ-ONLY grep that mentions the ledger path, an ID, VERIFIED and a
#     `2>/dev/null` redirection is not a write. It used to be denied with the
#     "faking verification is a red line" accusation.
json='{"tool_name":"Bash","tool_input":{"command":"grep -n '"'"'ISSUE-002.*VERIFIED'"'"' docs/looptesting/ISSUES.md 2>/dev/null"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "H-01: read-only grep on the ledger with 2>/dev/null -> allow"

# 21. H-01: `sed -n` (print, not in-place) and `cat … | grep` are reads too.
json='{"tool_name":"Bash","tool_input":{"command":"sed -n '"'"'/ISSUE-002/p'"'"' docs/looptesting/ISSUES.md | grep -c VERIFIED"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "H-01: sed -n + pipe to grep on the ledger -> allow"
json='{"tool_name":"Bash","tool_input":{"command":"cat docs/looptesting/ISSUES.md | tee /tmp/ledger-copy.txt | grep -w VERIFIED; echo ISSUE-002 >&2"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "H-01: tee to a NON-ledger path, >&2 redirect -> allow"

# 22. Still a write when the VERB targets the ledger: >> path, tee path, sed -i path.
json='{"tool_name":"Bash","tool_input":{"command":"printf \"### ISSUE-002 | P1 | VERIFIED | x\\n\" >> ./docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "verb-bound: >> ./ledger with no footprint -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"echo \"### ISSUE-002 | P1 | VERIFIED | x\" | tee -a docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "verb-bound: tee -a ledger with no footprint -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"sed -i '"'"'s/| OPEN |/| VERIFIED |/'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "verb-bound: sed -i with a | inside the script still targets the ledger -> deny"

# 23. H-04: an in-place edit that introduces VERIFIED without naming an ISSUE-ID
#     used to pass at zero cost (ID unresolvable -> allow). It must name the ID.
json='{"tool_name":"Bash","tool_input":{"command":"sed -i '"'"'s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md"}}'
err=$(run_ledger_err "$WS20" "$json"); rc=$?
assert_rc $rc 2 "H-04: sed -i introducing VERIFIED with no ISSUE-ID -> deny"
if printf '%s' "$err" | grep -q 'ISSUE-ID'; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: H-04 denial must ask for the ISSUE-ID, got [$err]" >&2; fi
json='{"tool_name":"Bash","tool_input":{"command":"perl -pi -e '"'"'s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "H-04: perl -pi introducing VERIFIED with no ISSUE-ID -> deny"
# …and the same in-place edit that DOES name an ID with a footprint is allowed.
json='{"tool_name":"Bash","tool_input":{"command":"sed -i '"'"'/ISSUE-003/s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "H-04: sed -i naming ISSUE-003 (footprint exists) -> allow"

# 24. H-05: a legitimate VERIFIED row for ISSUE-003 (footprint) whose TITLE cites
#     ISSUE-002 (no footprint) — the ID comes from the leading column, not the title.
json="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$(issues_path "$WS20")\",\"old_string\":\"### ISSUE-003 | P1 | FIXED_UNVERIFIED | crash\",\"new_string\":\"### ISSUE-003 | P1 | VERIFIED | crash, dup of ISSUE-002\"}}"
run_ledger "$WS20" "$json"; assert_rc $? 0 "H-05: Edit VERIFIED row citing another ID in its title -> allow"
json='{"tool_name":"Bash","tool_input":{"command":"echo \"### ISSUE-003 | P1 | VERIFIED | dup of ISSUE-002\" >> docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "H-05: Bash VERIFIED row citing another ID in its title -> allow"
# Partial edit of the same row (no header in new_string): the enclosing header in
# the ledger resolves the ID (ISSUE-003), not the cited ISSUE-002 in the text.
json="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$(issues_path "$WS20")\",\"old_string\":\"| FIXED_UNVERIFIED | crash\",\"new_string\":\"| VERIFIED | crash, dup of ISSUE-002\"}}"
run_ledger "$WS20" "$json"; assert_rc $? 0 "H-05: partial Edit, ID from enclosing header, title cites other ID -> allow"
# Control: the leading-column ID with NO footprint is still denied even when the
# title cites one that has a footprint.
json='{"tool_name":"Bash","tool_input":{"command":"echo \"### ISSUE-002 | P1 | VERIFIED | same as ISSUE-003\" >> docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "H-05 control: leading-column ID without footprint -> deny"

report "ledger-gate.test.sh"
