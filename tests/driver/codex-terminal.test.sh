#!/usr/bin/env bash
# unattended-codex.sh: stop immediately on a terminal STATE; drive RUNNING to
# CONVERGED; write per-session driver.log lines. Uses a stub codex + --no-protect.
set -u
. "$(cd "$(dirname "$0")" && pwd)/codex-lib.sh"

# A. terminal status already present -> exit 0, launch zero sessions
WS=$(mk_proj); trap 'rm -rf "$WS"' EXIT
stub=$(write_stub "$WS")
write_state "$WS" CONVERGED 4
bash "$CODEX_DRIVER" --project "$WS" --codex-bin "$stub" --no-protect >/dev/null 2>&1
assert_rc $? 0 "terminal STATE -> exit 0"
assert_eq "0" "$(sessions_in_log "$WS")" "no session launched when already terminal"

# B. RUNNING -> converge at round 2 (two sessions), exit 0
WS2=$(mk_proj); trap 'rm -rf "$WS" "$WS2"' EXIT
stub=$(write_stub "$WS2")
write_state "$WS2" RUNNING 0
STUB_CONVERGE_AT=2 bash "$CODEX_DRIVER" --project "$WS2" --codex-bin "$stub" --no-protect >/dev/null 2>&1
assert_rc $? 0 "RUNNING driven to CONVERGED -> exit 0"
assert_eq "2" "$(sessions_in_log "$WS2")" "exactly 2 sessions to converge"
assert_eq "CONVERGED" "$(grep -aE '^status:' "$WS2/docs/looptesting/STATE.md" | sed 's/^status:[[:space:]]*//' | tr -d '[:space:]')" "final STATE is CONVERGED"

# C. driver.log line format + append
assert_file_contains "$WS2/docs/looptesting/driver.log" "session 1: exit=0 round=1 issues=1 status=RUNNING" "driver.log session-1 line"
assert_file_contains "$WS2/docs/looptesting/driver.log" "session 2: exit=0 round=2 issues=2 status=CONVERGED" "driver.log session-2 line"
assert_file_contains "$WS2/docs/looptesting/driver.log" "driver end:" "driver.log end line"

# D. protect path restores skill-dir writability on normal exit (C18). Uses a
#    mktemp FAKE skill-dir (NEVER the real ~/.codex) with PROTECT on (no --no-protect).
WS3=$(mk_proj); FAKE=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-fakeskill.XXXXXX")
trap 'chmod -R u+w "$FAKE" 2>/dev/null; rm -rf "$WS" "$WS2" "$WS3" "$FAKE"' EXIT
printf 'SKILL\n' > "$FAKE/SKILL.md"
stub=$(write_stub "$WS3")
write_state "$WS3" CONVERGED 1   # terminal on entry: driver applies protect, then exits 0
bash "$CODEX_DRIVER" --project "$WS3" --codex-bin "$stub" --skill-dir "$FAKE" >/dev/null 2>&1
if [ -w "$FAKE/SKILL.md" ]; then
  PASS=$((PASS+1)); echo "  ok: protect restores skill-dir writability on normal exit"
else FAIL=$((FAIL+1)); echo "  FAIL: skill-dir left read-only after normal exit" >&2; fi

# E. the restore trap is wired for signal interrupts (INT/TERM), not just EXIT (C18).
if grep -qE "trap .* EXIT INT TERM" "$CODEX_DRIVER"; then
  PASS=$((PASS+1)); echo "  ok: protect restore trap covers EXIT INT TERM"
else FAIL=$((FAIL+1)); echo "  FAIL: protect trap not wired for INT/TERM" >&2; fi

report "codex-terminal.test.sh"
