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
# --no-protect is mandatory here (codex-lib.sh contract): the driver's
# `chmod -R u-w "$SKILL_DIR"` runs BEFORE the binary preflight, and SKILL_DIR
# defaults to the user's REAL ~/.codex/skills/loop-testing. Without the flag this
# test write-protected (then restored) a real install on any machine that has one
# (audit 2026-09-20 T-01; reproduced with CODEX_HOME=<fixture> + a chmod shim).
WS3=$(mk_proj); write_state "$WS3" RUNNING 0
# Lock it: point CODEX_HOME at a fixture that HAS a skills/loop-testing dir and put
# a logging chmod shim first on PATH. If --no-protect is ever dropped again, the
# driver chmods the fixture and the log appears.
mkdir -p "$WS3/codexhome/skills/loop-testing" "$WS3/shim"
printf '#!/usr/bin/env bash\necho "chmod $*" >> "%s/chmod.log"\nexec /bin/chmod "$@"\n' "$WS3" > "$WS3/shim/chmod"
chmod +x "$WS3/shim/chmod"
out=$(CODEX_HOME="$WS3/codexhome" PATH="$WS3/shim:$PATH" \
      bash "$CODEX_DRIVER" --project "$WS3" --codex-bin "$WS3/definitely-not-here" \
        --max-sessions 3 --no-watchdog --no-protect 2>&1); rc=$?
assert_rc "$rc" 2 "codex driver: missing --codex-bin refuses to start"
if [ -e "$WS3/chmod.log" ]; then
  FAIL=$((FAIL+1)); echo "  FAIL: the preflight test chmod'd the skills dir: $(tr '\n' ';' < "$WS3/chmod.log") — pass --no-protect (T-01)" >&2
else PASS=$((PASS+1)); fi
printf '%s' "$out" | grep -qF 'definitely-not-here' \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: codex message must name the missing binary" >&2; }
assert_eq 0 "$(sessions_in_log "$WS3")" "codex driver: no session is launched on preflight failure"
rm -rf "$WS3"

report "agent-binary-preflight.test.sh"
