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

# ── Review round 2: the Bash leg decides per TOKEN, not by searching the command
#    string. Shapes below are the reviewer's measured table; the allowed column is
#    a deliberate, documented choice (see the residual list in the hook header). ──
# Same workspace shape as the block above: ISSUE-002 has NO footprint,
# ISSUE-003 HAS one.
L20="docs/looptesting/ISSUES.md"

# 25. P0: one extra character must not walk past the in-place rule. The old span
#     between the -i flag and the path stopped at `;` and `&`, so a single
#     trailing semicolon turned a denied bulk flip into an allowed one.
json='{"tool_name":"Bash","tool_input":{"command":"sed -i '"'"'s/FIXED_UNVERIFIED/VERIFIED/;'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "P0: sed -i script ending in a semicolon -> still denied"
json='{"tool_name":"Bash","tool_input":{"command":"sed -i '"'"'s/FIXED_UNVERIFIED/VERIFIED&/'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "P0: sed -i script with an & backreference -> still denied"
json='{"tool_name":"Bash","tool_input":{"command":"sed -i '"'"'s/a/b/;s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "P0: two-statement sed -i script -> still denied"
json='{"tool_name":"Bash","tool_input":{"command":"perl -pi -e '"'"'s/FIXED_UNVERIFIED/VERIFIED/ ; 1;'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "P0: perl -pi script with a semicolon -> still denied"

# 26. P1 regression: `tee <ledger>` with no flag and a single space is a write.
json='{"tool_name":"Bash","tool_input":{"command":"echo \"### ISSUE-002 | P1 | VERIFIED | x\" | tee docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "P1: bare tee <ledger>, one space, no flag -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"echo \"### ISSUE-002 | P1 | VERIFIED | x\" | tee --append docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "P1: tee --append <ledger> -> deny"

# 27. P1 regression: a downgrade or a deletion REMOVES VERIFIED. Re-verification
#     failing and moving a row back to OPEN is protocol behavior, and must never
#     draw the "faking verification is a red line" accusation.
json='{"tool_name":"Bash","tool_input":{"command":"sed -i '"'"'s/VERIFIED/OPEN/'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "P1: sed -i downgrading VERIFIED -> OPEN -> allow"
json='{"tool_name":"Bash","tool_input":{"command":"sed -i '"'"'/VERIFIED/d'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "P1: sed -i deleting VERIFIED rows -> allow"
json='{"tool_name":"Bash","tool_input":{"command":"sed -i '"'"'/ISSUE-002/s/| VERIFIED |/| OPEN |/'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "P1: downgrade naming an ID with no footprint -> allow"
json='{"tool_name":"Bash","tool_input":{"command":"perl -ni -e '"'"'print unless /VERIFIED/'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "P1: perl -ni dropping VERIFIED rows -> allow"

# 28. DOCUMENTED RESIDUAL: a redirection target computed at runtime. The lexer
#     does not expand anything, so `>> "$L"` is an unresolved target, not a ledger
#     one. Closing it would need either variable resolution or matching the path
#     anywhere in the command — and anywhere-matching denies a read of the ledger
#     that merely sits in the same compound command (case 30), which is the
#     expensive failure for a hook that accuses. Allowed, and named in the header.
json='{"tool_name":"Bash","tool_input":{"command":"L=docs/looptesting/ISSUES.md; echo \"### ISSUE-002 | P1 | VERIFIED | x\" >> \"$L\""}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "documented residual: runtime-computed redirect target -> allow"

# 29. P2: the path comparison is a whole-token match, so a sibling file whose name
#     merely starts with the ledger's is not the ledger.
json='{"tool_name":"Bash","tool_input":{"command":"echo \"### ISSUE-002 | P1 | VERIFIED | x\" >> docs/looptesting/ISSUES.md.bak"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "P2: >> ISSUES.md.bak is not the ledger -> allow"

# 30. The reviewer's false-denial list. Every one of these is a READ of the ledger
#     or a write to something else, and a false deny here accuses the model of
#     faking verification and derails the loop.
for c in \
  "grep -n 'ISSUE-002.*VERIFIED' docs/looptesting/ISSUES.md 2>/dev/null" \
  "rg -n 'ISSUE-002.*VERIFIED' docs/looptesting/ISSUES.md" \
  "sed -n '/ISSUE-002/p' docs/looptesting/ISSUES.md | grep -c VERIFIED" \
  "awk '/VERIFIED/ {print}' docs/looptesting/ISSUES.md" \
  "cat docs/looptesting/ISSUES.md | grep -w VERIFIED" \
  "git diff -- docs/looptesting/ISSUES.md" \
  "git log -S VERIFIED -- docs/looptesting/ISSUES.md" \
  "cat docs/looptesting/ISSUES.md | tee /tmp/lg-copy.txt | grep -w VERIFIED" \
  "echo '### ISSUE-002 replay: cmd -> pass, now VERIFIED' >> docs/looptesting/runs/round-1.md" \
  "sed -i 's/pending/### ISSUE-002 VERIFIED/' docs/looptesting/runs/round-1.md" \
  "sed -i 's/x/y/' other-file.md && grep -n 'ISSUE-002' docs/looptesting/ISSUES.md" \
  "diff <(grep VERIFIED docs/looptesting/ISSUES.md) /tmp/lg-expected.txt" \
; do
  esc=$(printf '%s' "$c" | sed 's/\\/\\\\/g; s/"/\\"/g')
  run_ledger "$WS20" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$esc\"}}"
  assert_rc $? 0 "read/elsewhere-write must not be denied: $c"
done

# 31. Verbs whose write target is identifiable from the token alone are bound too.
json='{"tool_name":"Bash","tool_input":{"command":"ruby -i -pe '"'"'gsub(/FIXED_UNVERIFIED/, \"VERIFIED\")'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "ruby -i on the ledger -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"printf '"'"'### ISSUE-002 | P1 | VERIFIED |\\n'"'"' | sponge docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "sponge <ledger> -> deny"

# 32. DOCUMENTED RESIDUAL. These reach the ledger through a verb whose target this
#     gate does not resolve, and they are allowed — matching the residual list in
#     the hook header. The assertions pin the documentation, not the desirability:
#     this is a soft gate that raises the cost of cheating (see K-04), and closing
#     these needs argument-position knowledge per verb.
for c in \
  "mv /tmp/lg-forged.md docs/looptesting/ISSUES.md" \
  "cp /tmp/lg-forged.md docs/looptesting/ISSUES.md" \
  "dd if=/tmp/lg-forged.md of=docs/looptesting/ISSUES.md" \
  "python3 -c \\\"open('docs/looptesting/ISSUES.md','a').write('### ISSUE-002 | P1 | VERIFIED |')\\\"" \
  "printf '### ISSUE-002 | P1 | VERIFIED |' | ed -s docs/looptesting/ISSUES.md" \
; do
  run_ledger "$WS20" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}"
  assert_rc $? 0 "documented residual (verb target not resolved), allowed: $c"
done

# 33. P2: an Edit whose old_string is not found in the ledger must not fall back to
#     an ID cited in the title — that re-opened the H-05 shape whenever the anchor
#     lookup missed.
WS21=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$WS14" "$WS15" "$WS16" "$WS17" "$OTHER17" "$WS18" "$WS19" "$BINL" "$WS20" "$WS21"' EXIT
printf '# ISSUES\n\n### ISSUE-003 | P1 | FIXED_UNVERIFIED | crash\n### ISSUE-005 | P2 | OPEN | dup ids\n' > "$WS21/docs/looptesting/ISSUES.md"
echo "replayed ISSUE-003: repro -> pass" > "$WS21/docs/looptesting/runs/round-1.md"
json="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$(issues_path "$WS21")\",\"old_string\":\"text that is not in the file at all\",\"new_string\":\"| VERIFIED | same root cause as ISSUE-005\"}}"
run_ledger "$WS21" "$json"; assert_rc $? 0 "P2: anchor lookup misses -> do not fall back to a title-cited ID"

# 34. P2: MultiEdit must not lift a header ID out of a NON-verifying edit and deny
#     that issue. edit 1 touches ISSUE-005 (no footprint, no VERIFIED); edit 2
#     verifies ISSUE-003, which has one. The call is legitimate.
json="{\"tool_name\":\"MultiEdit\",\"tool_input\":{\"file_path\":\"$(issues_path "$WS21")\",\"edits\":[{\"old_string\":\"### ISSUE-005 | P2 | OPEN | dup ids\",\"new_string\":\"### ISSUE-005 | P2 | WONT_FIX | dup ids\"},{\"old_string\":\"FIXED_UNVERIFIED\",\"new_string\":\"VERIFIED\"}]}}"
run_ledger "$WS21" "$json"; assert_rc $? 0 "P2: MultiEdit resolves the ID from the VERIFYING edit only"
# Control: the same MultiEdit shape where the verifying edit's issue has NO
# footprint must still be denied.
WS22=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$WS14" "$WS15" "$WS16" "$WS17" "$OTHER17" "$WS18" "$WS19" "$BINL" "$WS20" "$WS21" "$WS22"' EXIT
printf '# ISSUES\n\n### ISSUE-007 | P1 | FIXED_UNVERIFIED | crash\n### ISSUE-005 | P2 | OPEN | dup ids\n' > "$WS22/docs/looptesting/ISSUES.md"
json="{\"tool_name\":\"MultiEdit\",\"tool_input\":{\"file_path\":\"$(issues_path "$WS22")\",\"edits\":[{\"old_string\":\"### ISSUE-005 | P2 | OPEN | dup ids\",\"new_string\":\"### ISSUE-005 | P2 | WONT_FIX | dup ids\"},{\"old_string\":\"FIXED_UNVERIFIED\",\"new_string\":\"VERIFIED\"}]}}"
run_ledger "$WS22" "$json"; assert_rc $? 2 "P2 control: MultiEdit verifying an unfootprinted issue -> deny"

# 35. P3: a NUL byte in the payload must not make bash warn on stderr. A hook that
#     exits 0 with noise on stderr still shows that noise to the model.
WS23=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$WS14" "$WS15" "$WS16" "$WS17" "$OTHER17" "$WS18" "$WS19" "$BINL" "$WS20" "$WS21" "$WS22" "$WS23"' EXIT
err=$( cd "$WS23" && printf 'not json \000 with a NUL' | env -u CLAUDE_PROJECT_DIR bash "$LEDGER" 2>&1 >/dev/null ); rc=$?
assert_rc $rc 0 "NUL byte in stdin -> fail open"
assert_eq "" "$err" "NUL byte in stdin -> no warning on stderr"

# 36. The no-python3 path. Lexing lives in a python3 leg; without it the gate
#     falls back to the (weaker, documented) regex leg, which must still deny the
#     canonical shapes and must still never deny a read.
NOPY=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-nopy.XXXXXX")
trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$WS14" "$WS15" "$WS16" "$WS17" "$OTHER17" "$WS18" "$WS19" "$BINL" "$WS20" "$WS21" "$WS22" "$WS23" "$NOPY"' EXIT
for b in bash grep sed head cut tr cat rm date printf dirname sort jq; do
  p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$NOPY/$b"
done
run_nopy() { ( cd "$1" && printf '%s' "$2" | env -u CLAUDE_PROJECT_DIR PATH="$NOPY" bash "$LEDGER" ) >/dev/null 2>&1; }
json='{"tool_name":"Bash","tool_input":{"command":"sed -i '"'"'s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md"}}'
run_nopy "$WS20" "$json"; assert_rc $? 2 "no python3: canonical in-place flip still denied (regex leg)"
json='{"tool_name":"Bash","tool_input":{"command":"echo \"### ISSUE-002 | P1 | VERIFIED | x\" >> docs/looptesting/ISSUES.md"}}'
run_nopy "$WS20" "$json"; assert_rc $? 2 "no python3: redirect write still denied (regex leg)"
json='{"tool_name":"Bash","tool_input":{"command":"echo \"### ISSUE-002 | P1 | VERIFIED | x\" | tee docs/looptesting/ISSUES.md"}}'
run_nopy "$WS20" "$json"; assert_rc $? 2 "no python3: bare tee <ledger> still denied (regex leg)"
json='{"tool_name":"Bash","tool_input":{"command":"grep -n '"'"'ISSUE-002.*VERIFIED'"'"' docs/looptesting/ISSUES.md 2>/dev/null"}}'
run_nopy "$WS20" "$json"; assert_rc $? 0 "no python3: read-only grep still allowed (regex leg)"
json='{"tool_name":"Bash","tool_input":{"command":"sed -i '"'"'s/VERIFIED/OPEN/'"'"' docs/looptesting/ISSUES.md"}}'
run_nopy "$WS20" "$json"; assert_rc $? 0 "no python3: downgrade still allowed (regex leg)"
json='{"tool_name":"Bash","tool_input":{"command":"echo \"### ISSUE-002 | P1 | VERIFIED | x\" >> docs/looptesting/ISSUES.md.bak"}}'
run_nopy "$WS20" "$json"; assert_rc $? 0 "no python3: ISSUES.md.bak is not the ledger (regex leg)"

# 37. Shell the lexer REJECTS goes to the regex leg, not to an automatic allow —
#     see the round-4 block below for why (bash runs most of these). It must
#     still never crash, and a non-forgery shape must not draw a deny.
for c in \
  "echo \\\"unbalanced quote >> docs/looptesting/ISSUES.md" \
  "echo VERIFIED >> docs/looptesting/ISSUES.md \\\\" \
; do
  run_ledger "$WS20" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}"
  assert_rc $? 0 "unlexable, no forgery to see -> allow: $c"
done
# A forgery shape with an unterminated quote is denied by the regex leg. bash
# exits non-zero on it too, so the model has to fix the command either way.
for c in \
  "sed -i 's/a/VERIFIED/ docs/looptesting/ISSUES.md" \
  "sed -i 's/FIXED_UNVERIFIED/VERIFIED/ docs/looptesting/ISSUES.md" \
; do
  run_ledger "$WS20" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}"
  assert_rc $? 2 "unlexable in-place forgery -> regex leg denies: $c"
done
# Lexable but with the VERB computed at runtime: unresolved, so the regex leg is
# consulted and may still deny. Either answer is defensible; neither may crash.
run_ledger "$WS20" '{"tool_name":"Bash","tool_input":{"command":"$(echo sed) -i '"'"'s/x/VERIFIED/'"'"' docs/looptesting/ISSUES.md"}}'; rc=$?
if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: runtime-computed verb must exit 0 or 2, got $rc" >&2; fi
json='{"tool_name":"Bash","tool_input":{"command":"sed -i '"'"'s/FIXED_UNVERIFIED/VERIFIED/ docs/looptesting/ISSUES.md"}}'
out=$( cd "$WS20" && printf '%s' "$json" | env -u CLAUDE_PROJECT_DIR bash "$LEDGER" 2>/dev/null ); rc=$?
assert_eq "" "$out" "unterminated quote -> empty stdout"

# ── Review round 3: `sponge` is functionally in-place — it soaks stdin and
#    replaces the file — so the "name the ISSUE-ID" rule has to reach it. The
#    replacement text lives in an earlier segment of the same PIPELINE, which is
#    why the substitution is read across the pipe rather than per segment. ──
json='{"tool_name":"Bash","tool_input":{"command":"sed '"'"'s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md | sponge docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "sponge: mass flip through a pipeline, no ID -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"sed '"'"'/ISSUE-002/s/OPEN/VERIFIED/'"'"' docs/looptesting/ISSUES.md | sponge docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "sponge: flip naming an unfootprinted ID -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"sed '"'"'/ISSUE-003/s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md | sponge docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "sponge: flip naming a footprinted ID -> allow"
# The same guard the in-place rule needs everywhere: a downgrade is not a forgery.
json='{"tool_name":"Bash","tool_input":{"command":"sed '"'"'s/VERIFIED/OPEN/'"'"' docs/looptesting/ISSUES.md | sponge docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "sponge: downgrade through a pipeline -> allow"
json='{"tool_name":"Bash","tool_input":{"command":"grep -w VERIFIED docs/looptesting/ISSUES.md; sed '"'"'s/VERIFIED/OPEN/'"'"' docs/looptesting/ISSUES.md | sponge docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "sponge: a READ in an adjacent (non-piped) segment does not supply the forgery text"

# A sed ADDRESS written directly before the `s` (`2s/…/`, `1,$s/…/`, `0s/…/`)
# left the substitution unrecognised, and the address rule then ate `/VERIFIED/`
# as if it were a match position — turning a forgery into an allow. Found by the
# fail-open battery, not by review.
json='{"tool_name":"Bash","tool_input":{"command":"sed -i '"'"'2s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "line-number address before s -> still denied"
json='{"tool_name":"Bash","tool_input":{"command":"sed -i '"'"'1,$s/OPEN/VERIFIED/'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "range address before s -> still denied"
json='{"tool_name":"Bash","tool_input":{"command":"sed -i 0s/a/VERIFIED/ docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "unquoted address before s -> still denied"
json='{"tool_name":"Bash","tool_input":{"command":"sed -i '"'"'2s/VERIFIED/OPEN/'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "line-number address on a downgrade -> allow"

# A JSON-escaped NUL reaches bash through the parser, where a raw one never does.
WS24=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$WS14" "$WS15" "$WS16" "$WS17" "$OTHER17" "$WS18" "$WS19" "$BINL" "$WS20" "$WS21" "$WS22" "$WS23" "$NOPY" "$WS24"' EXIT
json='{"tool_name":"Bash","tool_input":{"command":"echo a\u0000b"}}'
err=$( cd "$WS24" && printf '%s' "$json" | env -u CLAUDE_PROJECT_DIR bash "$LEDGER" 2>&1 >/dev/null ); rc=$?
assert_rc $rc 0 "JSON-escaped NUL -> fail open"
assert_eq "" "$err" "JSON-escaped NUL -> no warning on stderr"

# ── Review round 4. Unlexable does NOT mean unrunnable: clearing `commenters` is
#    what lets a hash-delimited sed script through, and it also means an
#    apostrophe in a trailing comment or a heredoc body reads as an unbalanced
#    quote. bash runs all of these and they really do write VERIFIED, so a lex
#    failure falls back to the regex leg instead of allowing outright. ──
json='{"tool_name":"Bash","tool_input":{"command":"echo '"'"'### ISSUE-002 | P1 | VERIFIED | x'"'"' >> docs/looptesting/ISSUES.md # it'"'"'s fine"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "unlexable: append with an apostrophe in a trailing comment -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"sed -i '"'"'s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md # doesn'"'"'t matter"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "unlexable: in-place flip with an apostrophe in a trailing comment -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"cat >> docs/looptesting/ISSUES.md <<EOF\n### ISSUE-002 | P1 | VERIFIED | doesn'"'"'t repro\nEOF\n"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "unlexable: heredoc body with an apostrophe -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"printf '"'"'%s\\n'"'"' $'"'"'### ISSUE-002 | P1 | VERIFIED | don\\'"'"'t'"'"' >> docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "unlexable: \$'...' with an escaped quote -> deny"
# …and the reads that carry the same apostrophes stay allowed, because the regex
# leg is target-bound: a read is not a write however it is punctuated.
json='{"tool_name":"Bash","tool_input":{"command":"grep -v '"'"'VERIFIED'"'"' docs/looptesting/ISSUES.md # doesn'"'"'t matter"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "unlexable read: grep with an apostrophe in a comment -> allow"
json='{"tool_name":"Bash","tool_input":{"command":"cat >> docs/looptesting/runs/round-1.md <<EOF\nreplayed ISSUE-002: it doesn'"'"'t crash now, VERIFIED\nEOF\n"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "unlexable: heredoc appending a replay line to a ROUND LOG -> allow"

# `tee` is in-place too. The truncate-vs-read race resolves in the writer's
# favour at any ledger size sed can buffer in one read, i.e. every real ledger.
json='{"tool_name":"Bash","tool_input":{"command":"sed '"'"'s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md | tee docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "tee: mass flip through a pipeline, no ID -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"sed '"'"'s/VERIFIED/OPEN/'"'"' docs/looptesting/ISSUES.md | tee docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "tee: downgrade through a pipeline -> allow"

# Pipeline text must not pick up a FILTER's pattern. Dropping verified rows with
# grep -v is the ordinary way to do it, and it was drawing the accusation.
json='{"tool_name":"Bash","tool_input":{"command":"grep -v '"'"'VERIFIED'"'"' docs/looptesting/ISSUES.md | sponge docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "grep -v VERIFIED | sponge -> allow (filter pattern is not written text)"
json='{"tool_name":"Bash","tool_input":{"command":"cat docs/looptesting/ISSUES.md | grep -v VERIFIED | sponge docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "cat | grep -v VERIFIED | sponge -> allow"
json='{"tool_name":"Bash","tool_input":{"command":"grep -v '"'"'VERIFIED'"'"' docs/looptesting/ISSUES.md | tee docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "grep -v VERIFIED | tee -> allow"
# Control: a non-filter verb in the pipeline still supplies the forgery text.
json='{"tool_name":"Bash","tool_input":{"command":"sed '"'"'s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md | grep -v nothing | sponge docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "sed forgery upstream of a filter -> still denied"

# ruby downgrades read as match positions too (`sub(/VERIFIED/, "OPEN")`).
json='{"tool_name":"Bash","tool_input":{"command":"ruby -i -pe '"'"'sub(/VERIFIED/,\"OPEN\")'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "ruby sub(/VERIFIED/,\"OPEN\") downgrade -> allow"
json='{"tool_name":"Bash","tool_input":{"command":"ruby -i -pe '"'"'gsub(/FIXED_UNVERIFIED/, \"VERIFIED\")'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "ruby gsub introducing VERIFIED -> still denied"

# The replay lookup matched a footprint by SUBSTRING, so a truncated ID rode on a
# longer one: ISSUE-01 passed on ISSUE-012's replay record.
WS25=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$WS14" "$WS15" "$WS16" "$WS17" "$OTHER17" "$WS18" "$WS19" "$BINL" "$WS20" "$WS21" "$WS22" "$WS23" "$NOPY" "$WS24" "$WS25"' EXIT
echo "replayed ISSUE-012: repro -> pass" > "$WS25/docs/looptesting/runs/round-1.md"
json='{"tool_name":"Bash","tool_input":{"command":"echo \"### ISSUE-01 | P1 | VERIFIED | x\" >> docs/looptesting/ISSUES.md"}}'
run_ledger "$WS25" "$json"; assert_rc $? 2 "ID prefix must not ride on a longer ID's replay record"
json='{"tool_name":"Bash","tool_input":{"command":"echo \"### ISSUE-012 | P1 | VERIFIED | x\" >> docs/looptesting/ISSUES.md"}}'
run_ledger "$WS25" "$json"; assert_rc $? 0 "control: the ID that really has the replay record -> allow"

# ── Review round 5. Marking tee in-place turned a weak early exit into a hole:
#    the exit read "no forgery text in the write group" as "therefore a
#    downgrade". That is absence of evidence. The grouping rules guarantee shapes
#    where the text legitimately sits outside the write group, and a list or a
#    subshell feeding tee is exactly one. A downgrade must now LOOK like one. ──
json='{"tool_name":"Bash","tool_input":{"command":"{ cat docs/looptesting/ISSUES.md; echo '"'"'### ISSUE-002 | P1 | VERIFIED | x'"'"'; } | tee docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "brace list feeding tee: the appended row is still judged -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"( cat docs/looptesting/ISSUES.md; echo '"'"'### ISSUE-002 | P1 | VERIFIED | x'"'"' ) | tee docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "subshell feeding tee: same shape -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"{ cat docs/looptesting/ISSUES.md; echo '"'"'### ISSUE-002 | P1 | VERIFIED | x'"'"'; } | sponge docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "brace list feeding sponge -> deny"
# The same shape naming a FOOTPRINTED id is legitimate and must land.
json='{"tool_name":"Bash","tool_input":{"command":"{ cat docs/looptesting/ISSUES.md; echo '"'"'### ISSUE-003 | P1 | VERIFIED | x'"'"'; } | tee docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "brace list feeding tee, footprinted ID -> allow"
# A write group with no recognizable text and no ID is not benign either.
json='{"tool_name":"Bash","tool_input":{"command":"{ cat docs/looptesting/ISSUES.md; echo '"'"'| VERIFIED |'"'"'; } | tee docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "brace list feeding tee, no ID at all -> deny"
# …and the filter chain is still allowed, for the POSITIVE reason that a chain of
# filters only ever drops rows — not because no forgery text was found.
json='{"tool_name":"Bash","tool_input":{"command":"grep -v '"'"'VERIFIED'"'"' docs/looptesting/ISSUES.md | sponge docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "filter chain into sponge -> still allow"
json='{"tool_name":"Bash","tool_input":{"command":"cat docs/looptesting/ISSUES.md | grep -v VERIFIED | sort | sponge docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "longer filter chain into sponge -> still allow"
json='{"tool_name":"Bash","tool_input":{"command":"sed '"'"'s/VERIFIED/OPEN/'"'"' docs/looptesting/ISSUES.md | tee docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "downgrade that looks like one -> still allow"

# A bracket glob splits the literal name and hides it from BOTH legs. Adding `[`
# to the unresolved set makes the lexer say so instead of silently reading the
# token as some other file; the regex leg still cannot see through it, so these
# stay allowed and the header says so.
json='{"tool_name":"Bash","tool_input":{"command":"echo '"'"'### ISSUE-002 | P1 | VERIFIED | x'"'"' >> docs/looptesting/ISSUES.m[d]"}}'
run_ledger "$WS20" "$json"; rc=$?
if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: bracket-glob redirect must not crash, got $rc" >&2; fi
json='{"tool_name":"Bash","tool_input":{"command":"sed -i '"'"'s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUE[S].md"}}'
run_ledger "$WS20" "$json"; rc=$?
if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: bracket-glob in-place must not crash, got $rc" >&2; fi
# The two shapes are pinned at their documented outcome — allowed — rather than
# at "0 or 2". No test isolates the `[` in `unres` itself: a bracket that hides
# the path hides it from the regex leg too, and a bracket anywhere else does not
# change the decision, so the flag has no externally observable effect. It is
# there so the lexer reports the target as unknown instead of silently reading it
# as some unrelated file, and the header states the residual.
json='{"tool_name":"Bash","tool_input":{"command":"echo '"'"'### ISSUE-002 | P1 | VERIFIED | x'"'"' >> docs/looptesting/ISSUES.m[d]"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "documented residual: bracket glob hides the path from both legs"
json='{"tool_name":"Bash","tool_input":{"command":"sed -i '"'"'s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUE[S].md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "documented residual: bracket glob in an in-place target"

# ── Review round 6. A writer whose stdin comes from a REDIRECT has no pipeline,
#    so it lands in a group of one — and "every member is a filter or the writer"
#    is vacuously true of a lone writer. That granted the row-dropping claim to a
#    command that drops nothing. A filter chain needs an actual filter upstream
#    AND the writer taking its input from the pipe. ──
json='{"tool_name":"Bash","tool_input":{"command":"tee docs/looptesting/ISSUES.md <<< '"'"'### ISSUE-002 | P1 | VERIFIED | x'"'"'"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "here-string into tee: content is in the command -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"tee -a docs/looptesting/ISSUES.md <<< '"'"'### ISSUE-002 | P1 | VERIFIED | x'"'"'"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "here-string into tee -a -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"sponge docs/looptesting/ISSUES.md <<< '"'"'### ISSUE-002 | P1 | VERIFIED | x'"'"'"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "here-string into sponge -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"tee docs/looptesting/ISSUES.md <<< '"'"'### ISSUE-003 | P1 | VERIFIED | x'"'"'"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "here-string into tee, footprinted ID -> allow"
# A lone writer fed by a plain file redirect: the content is not in the command,
# so no version of this gate can judge it. Pinned as the documented residual.
json='{"tool_name":"Bash","tool_input":{"command":"tee -a docs/looptesting/ISSUES.md < /tmp/row.txt"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "documented residual: content arrives from a file, not the command"
# …and a real filter chain keeps its claim.
json='{"tool_name":"Bash","tool_input":{"command":"grep -v '"'"'VERIFIED'"'"' docs/looptesting/ISSUES.md | tee docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "filter chain into tee -> still allow"
json='{"tool_name":"Bash","tool_input":{"command":"cat docs/looptesting/ISSUES.md | grep -v VERIFIED | sponge docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "filter chain into sponge -> still allow"

# A newline is a command separator, not whitespace. Merging lines into one
# segment made a legitimate multi-line call read as one command whose text
# carried a bare VERIFIED from a neighbouring read, and denied it.
json='{"tool_name":"Bash","tool_input":{"command":"sed -i '"'"'s/VERIFIED/OPEN/'"'"' docs/looptesting/ISSUES.md\ngrep -c VERIFIED docs/looptesting/ISSUES.md\n"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "multi-line: downgrade then a read -> allow"
json='{"tool_name":"Bash","tool_input":{"command":"grep -c VERIFIED docs/looptesting/ISSUES.md\nsed -i '"'"'/ISSUE-002/s/VERIFIED/OPEN/'"'"' docs/looptesting/ISSUES.md\n"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "multi-line: a read then a downgrade -> allow"
json='{"tool_name":"Bash","tool_input":{"command":"grep -v VERIFIED docs/looptesting/ISSUES.md > /tmp/x\nmv /tmp/x docs/looptesting/ISSUES.md\n"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "multi-line: filter to a temp file then move it back -> allow"
# Control: a multi-line call that really does append a forged row is still denied.
json='{"tool_name":"Bash","tool_input":{"command":"echo '"'"'### ISSUE-002 | P1 | VERIFIED | x'"'"' >> docs/looptesting/ISSUES.md\nls -la\n"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "multi-line: append a forged row then ls -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"ls -la\nsed -i '"'"'s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md\n"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "multi-line: ls then an in-place forgery -> deny"
# A newline inside a quoted string stays part of that token, not a separator.
json='{"tool_name":"Bash","tool_input":{"command":"echo '"'"'### ISSUE-002 | P1 | OPEN | x\n### ISSUE-002 | P1 | VERIFIED | y'"'"' >> docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "newline inside a quoted argument is content, not a separator -> deny"

# perl/sed transliteration is a match position too (same class as ruby sub).
json='{"tool_name":"Bash","tool_input":{"command":"perl -i -pe '"'"'tr/VERIFIED/verified/'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "perl tr/// downgrade -> allow"

# ── Review round 7. Three ways to name a writer that the verb lookup missed. ──

# 1. VERB WRAPPERS. `command`, `env`, `nice`, `timeout`, `stdbuf`, `nohup`,
#    `busybox` and `xargs` all take a command as their argument, so the first
#    word was the wrapper and the real writer was never classified.
json='{"tool_name":"Bash","tool_input":{"command":"echo '"'"'### ISSUE-002 | P1 | VERIFIED | x'"'"' | command tee -a docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "wrapper: command tee -a ledger -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"echo '"'"'### ISSUE-002 | P1 | VERIFIED | x'"'"' | env tee -a docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "wrapper: env tee -a ledger -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"echo '"'"'### ISSUE-002 | P1 | VERIFIED | x'"'"' | env -u FOO BAR=1 tee -a docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "wrapper: env with a value-flag and an assignment -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"timeout 5 sed -i '"'"'s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "wrapper: timeout DURATION sed -i -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"nice -n 10 tee docs/looptesting/ISSUES.md <<< '"'"'### ISSUE-002 | P1 | VERIFIED | x'"'"'"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "wrapper: nice -n N tee -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"echo '"'"'### ISSUE-002 | P1 | VERIFIED | x'"'"' | xargs -I{} nohup tee -a docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "wrapper: xargs -I{} then nohup, two deep -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"stdbuf -oL sed -i '"'"'s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "wrapper: stdbuf -oL sed -i -> deny"
# Unwrapping must not create denies of its own: a wrapped FILTER is still a
# filter, and a wrapped write of a footprinted ID is still legitimate.
json='{"tool_name":"Bash","tool_input":{"command":"command grep -v VERIFIED docs/looptesting/ISSUES.md | sponge docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "wrapper on a filter keeps the chain -> allow"
json='{"tool_name":"Bash","tool_input":{"command":"echo '"'"'### ISSUE-003 | P1 | VERIFIED | x'"'"' | command tee -a docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "wrapper: footprinted ID -> allow"
json='{"tool_name":"Bash","tool_input":{"command":"timeout 5 grep -c VERIFIED docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "wrapper on a read -> allow"

# 2. A LISTED FILTER THAT CAN WRITE. `sort -o` and `uniq IN OUT` replace a file
#    as surely as sponge does; the list meant "reads stdin, writes stdout".
json='{"tool_name":"Bash","tool_input":{"command":"sed '"'"'s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md | sort -o docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "sort -o ledger -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"sed '"'"'s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md | sort --output=docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "sort --output=ledger -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"sed '"'"'s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md > /tmp/x\nuniq /tmp/x docs/looptesting/ISSUES.md\n"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "uniq IN OUT where OUT is the ledger -> deny"
# …and plain `sort` in a filter chain is still a filter.
json='{"tool_name":"Bash","tool_input":{"command":"cat docs/looptesting/ISSUES.md | grep -v VERIFIED | sort | sponge docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "plain sort in a filter chain -> still allow"
json='{"tool_name":"Bash","tool_input":{"command":"grep -v VERIFIED docs/looptesting/ISSUES.md | sort -o /tmp/elsewhere.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "sort -o somewhere else -> allow"

# 3. A REDIRECT INSIDE ANOTHER LANGUAGE'S PROGRAM TEXT. Documented residual, in
#    the same class as python3 -c: this gate reads shell, not awk.
json='{"tool_name":"Bash","tool_input":{"command":"awk '"'"'{gsub(/FIXED_UNVERIFIED/,\"VERIFIED\"); print > \"docs/looptesting/ISSUES.md\"}'"'"' docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "documented residual: awk print > \"file\" inside the program text"

# ── Round 8. `sort -o OUT IN` names its target in the token AFTER -o; taking
#    every operand instead made a ledger read as INPUT look like the write
#    target, and accused correct work. All four spellings are pinned. ──
json='{"tool_name":"Bash","tool_input":{"command":"sed '"'"'s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md | sort -o docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "sort -o FILE (separated) -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"sed '"'"'s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md | sort -odocs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "sort -oFILE (attached) -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"sed '"'"'s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md | sort --output=docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "sort --output=FILE -> deny"
json='{"tool_name":"Bash","tool_input":{"command":"sed '"'"'s/FIXED_UNVERIFIED/VERIFIED/'"'"' docs/looptesting/ISSUES.md | sort --output docs/looptesting/ISSUES.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 2 "sort --output FILE (separated long) -> deny"
# The ledger as sort's INPUT, with the output going elsewhere, is a read.
json='{"tool_name":"Bash","tool_input":{"command":"sort -o /tmp/s.md docs/looptesting/ISSUES.md && grep -c VERIFIED /tmp/s.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "sort -o ELSEWHERE with the ledger as input -> allow"
json='{"tool_name":"Bash","tool_input":{"command":"sort --output=/tmp/s.md docs/looptesting/ISSUES.md && grep -c VERIFIED /tmp/s.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "sort --output=ELSEWHERE with the ledger as input -> allow"
# uniq already takes only its last operand; pin that the input side is a read.
json='{"tool_name":"Bash","tool_input":{"command":"uniq docs/looptesting/ISSUES.md /tmp/u.md && grep -c VERIFIED /tmp/u.md"}}'
run_ledger "$WS20" "$json"; assert_rc $? 0 "uniq LEDGER ELSEWHERE -> allow (ledger is the input)"

# K-14: the monorepo topology, same defect as stop-gate's case DD. This gate's
# armed-check (.active) and replay lookup (runs/) are cwd-relative too, so a
# session started in a subpackage of a monorepo found neither and allowed every
# write — including the one this gate exists to deny, a VERIFIED stamp with no
# replay footprint behind it. Failing OPEN is the dangerous direction here: the
# ledger is what every later claim in the run rests on.
MONOL=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-monol.XXXXXX")
trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$WS14" "$WS15" "$WS16" "$WS17" "$OTHER17" "$WS18" "$WS19" "$BINL" "$WS20" "$WS21" "$WS22" "$WS23" "$NOPY" "$WS24" "$WS25" "$MONOL"' EXIT
git init -q "$MONOL" >/dev/null 2>&1
mkdir -p "$MONOL/pkgs/app" "$MONOL/docs/looptesting/runs"
printf '# ISSUES\n' > "$MONOL/docs/looptesting/ISSUES.md"
: > "$MONOL/docs/looptesting/.active"
if [ ! -d "$MONOL/pkgs/app/docs/looptesting" ] \
   && [ -n "$( cd "$MONOL/pkgs/app" && git rev-parse --show-toplevel 2>/dev/null )" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); echo "  FAIL: fixture: subpackage must be evidence-free and inside a git repo" >&2
fi
json="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$(issues_path "$MONOL")\",\"new_string\":\"### ISSUE-042 | P0 | VERIFIED | no replay behind this\"}}"
( cd "$MONOL/pkgs/app" && printf '%s' "$json" | CLAUDE_PROJECT_DIR="$MONOL/pkgs/app" bash "$LEDGER" ) >/dev/null 2>&1
assert_rc $? 2 "monorepo subpackage: armed toplevel ledger still denies VERIFIED w/o footprint (K-14)"
# Control: with the replay footprint at the toplevel it must allow again, or the
# walk-up would have turned the gate into a blanket deny from every subdirectory.
echo "replayed ISSUE-042: steps -> pass" > "$MONOL/docs/looptesting/runs/round-7.md"
( cd "$MONOL/pkgs/app" && printf '%s' "$json" | CLAUDE_PROJECT_DIR="$MONOL/pkgs/app" bash "$LEDGER" ) >/dev/null 2>&1
assert_rc $? 0 "monorepo subpackage: the toplevel replay footprint is found too -> allow"
# The Bash leg reaches the same decision by a different route: the ledger operand
# is recognised by path SUFFIX (cwd-independent), but the replay footprint is
# looked up under a cwd-relative docs/looptesting/runs/. From the subpackage that
# directory does not exist, so a VERIFIED write that IS backed by a replay at the
# toplevel gets denied — the H-01 direction (false deny), reached through the same
# anchoring gap as the fail-open above.
json_bash="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo '### ISSUE-042 | P0 | VERIFIED | replayed' >> $MONOL/docs/looptesting/ISSUES.md\"}}"
( cd "$MONOL/pkgs/app" && printf '%s' "$json_bash" | CLAUDE_PROJECT_DIR="$MONOL/pkgs/app" bash "$LEDGER" ) >/dev/null 2>&1
assert_rc $? 0 "monorepo subpackage, Bash leg: a replayed VERIFIED write is not false-denied (K-14)"
# And the deny must survive the walk-up: same command, an ID with no replay.
json_bash2="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo '### ISSUE-099 | P0 | VERIFIED | thin air' >> $MONOL/docs/looptesting/ISSUES.md\"}}"
( cd "$MONOL/pkgs/app" && printf '%s' "$json_bash2" | CLAUDE_PROJECT_DIR="$MONOL/pkgs/app" bash "$LEDGER" ) >/dev/null 2>&1
assert_rc $? 2 "monorepo subpackage, Bash leg: an unreplayed VERIFIED write is still denied"

report "ledger-gate.test.sh"
