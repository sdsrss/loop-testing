#!/usr/bin/env bash
# agent-binary-preflight.test.sh — a driver must refuse to start when the agent
# binary it is going to launch does not exist.
#
# The bug this locks: both drivers preflight the WATCHDOG binary carefully
# (`die` with a precise message when timeout/gtimeout is absent), but never check
# $CLAUDE_BIN / $CODEX_BIN. A missing or misspelled binary therefore burned real
# session slots, and the failure surfaced as the circuit breaker's
#   "NO_PROGRESS: session N produced no STATE.md (agent likely failed before round 0)"
# — which blames the agent's behavior for what is a missing executable, and points
# the user at the loop instead of at their PATH.
#
# Contract asserted here: exit 2 (the drivers' argument/preflight error code, same
# as the watchdog refusal), a message naming the binary, and ZERO sessions started.
set -u

. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/codex-lib.sh"

WS=$(mk_proj)
trap 'rm -rf "$WS"' EXIT
write_state "$WS" RUNNING 0

# ── claude driver ─────────────────────────────────────────────────────────────
out=$(bash "$DRIVER" --project "$WS" --claude-bin "$WS/definitely-not-here" \
        --max-sessions 3 --no-watchdog 2>&1); rc=$?
assert_rc "$rc" 2 "claude driver: missing --claude-bin refuses to start"
printf '%s' "$out" | grep -qF 'definitely-not-here' \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: message must name the missing binary" >&2; }
assert_eq 0 "$(sessions_in_log "$WS")" "claude driver: no session is launched on preflight failure"
if printf '%s' "$out" | grep -qF 'NO_PROGRESS'; then
  FAIL=$((FAIL+1)); echo "  FAIL: a missing binary must not be reported as NO_PROGRESS" >&2
else PASS=$((PASS+1)); fi

# a bare NAME that is not on PATH is the misspelling case (--claude-bin claud)
out=$(bash "$DRIVER" --project "$WS" --claude-bin 'claud-typo-not-on-path' \
        --max-sessions 3 --no-watchdog 2>&1); rc=$?
assert_rc "$rc" 2 "claude driver: --claude-bin name absent from PATH refuses to start"

# control: a real (stub) binary still starts and runs to convergence
WS2=$(mk_proj); write_state "$WS2" RUNNING 0
stub=$(write_stub "$WS2")
STUB_CONVERGE_AT=1 bash "$DRIVER" --project "$WS2" --claude-bin "$stub" \
  --max-sessions 3 --no-watchdog >/dev/null 2>&1; rc=$?
assert_rc "$rc" 0 "claude driver: a present binary still runs (preflight is not over-strict)"
rm -rf "$WS2"

# ── codex driver ──────────────────────────────────────────────────────────────
WS3=$(mk_proj); write_state "$WS3" RUNNING 0
out=$(bash "$CODEX_DRIVER" --project "$WS3" --codex-bin "$WS3/definitely-not-here" \
        --max-sessions 3 --no-watchdog 2>&1); rc=$?
assert_rc "$rc" 2 "codex driver: missing --codex-bin refuses to start"
printf '%s' "$out" | grep -qF 'definitely-not-here' \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: codex message must name the missing binary" >&2; }
assert_eq 0 "$(sessions_in_log "$WS3")" "codex driver: no session is launched on preflight failure"
rm -rf "$WS3"

report "agent-binary-preflight.test.sh"
