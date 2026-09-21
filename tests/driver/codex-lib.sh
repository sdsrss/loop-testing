#!/usr/bin/env bash
# Shared helpers for unattended-codex.sh (driver) tests. Source, don't execute.
#
# SAFETY: tests use a mktemp project + a STUB codex binary (--codex-bin). The
# real ~/.codex/skills is never chmod'd: tests either pass --no-protect, or
# (protect-path cases) point --skill-dir at a mktemp FAKE dir. The real `codex`
# is NEVER invoked here. Each test cleans its own workspace.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
CODEX_DRIVER="$REPO_ROOT/skills/loop-testing/scripts/unattended-codex.sh"
export CODEX_DRIVER

PASS=0
FAIL=0

mk_proj() {
  local ws
  # Unchecked, an empty $ws turns the mkdir below into `mkdir -p /docs/…` and
  # every later path into an absolute one outside any fixture.
  ws=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-cxdriver.XXXXXX") || return 1
  mkdir -p "$ws/docs/looptesting"
  echo "$ws"
}

write_state() { # ws status round
  cat > "$1/docs/looptesting/STATE.md" <<EOF
# STATE
round: $3
converged_streak: 0
status: $2
max_rounds: 12
EOF
}

# write_stub <ws> : a fake `codex` that ignores its `exec -s ... -C ... <prompt>`
# args and advances STATE per invocation (cwd is the project, set by the driver).
#   env STUB_CONVERGE_AT=N -> set status=CONVERGED once round reaches N
#   env STUB_NO_PROGRESS=1  -> keep round/issues unchanged (RUNNING)
#   env STUB_EXIT=N         -> exit code (default 0)
write_stub() {
  local ws="$1" stub="$1/stub-codex.sh"
  cat > "$stub" <<'STUB'
#!/usr/bin/env bash
set -u
# Ignore all Codex CLI args (exec, -s, -C, prompt); operate on cwd's ledger.
LT="docs/looptesting"; mkdir -p "$LT/runs" "$LT/decisions"
STATE="$LT/STATE.md"; ISS="$LT/ISSUES.md"
if [ "${STUB_NO_STATE:-0}" = "1" ]; then echo "stub-codex: intentionally wrote no STATE"; exit "${STUB_EXIT:-0}"; fi
round=-1
[ -f "$STATE" ] && round=$(grep -aE '^round:' "$STATE" | head -1 | sed 's/[^0-9-]//g')
case "$round" in ''|*[!0-9-]*) round=-1 ;; esac
streak=0
if [ "${STUB_BOOTSTRAP:-0}" = "1" ]; then
  # Round-0 progress: round / issue count / converged_streak stay static and NO
  # runs/round-N.md is created, but PLAN.md + FEATURE_MATRIX.md grow each call
  # (the project-analysis phase before the loop proper). Exercises PL-2.
  new_round=$round; [ "$new_round" -lt 0 ] && new_round=0
  printf 'plan detail line for session\n' >> "$LT/PLAN.md"
  printf '| feature | entry | scenario | PASS | R0 |\n' >> "$LT/FEATURE_MATRIX.md"
  status=RUNNING
elif [ "${STUB_STREAK_ONLY:-0}" = "1" ]; then
  # Progress via convergence + evidence only: round and issue count stay static,
  # but converged_streak advances and a runs/ evidence file grows each call.
  new_round=$round; [ "$new_round" -lt 0 ] && new_round=0
  [ -f "$STATE" ] && streak=$(grep -aE '^converged_streak:' "$STATE" | head -1 | sed 's/[^0-9]//g')
  case "$streak" in ''|*[!0-9]*) streak=0 ;; esac
  streak=$(( streak + 1 ))
  printf 'evidence for session (streak now %s)\n' "$streak" >> "$LT/runs/round-${new_round}.md"
  status=RUNNING
elif [ "${STUB_NO_PROGRESS:-0}" = "1" ]; then
  new_round=$round; [ "$new_round" -lt 0 ] && new_round=0
  status=RUNNING
else
  new_round=$(( round + 1 ))
  printf '### ISSUE-%03d | P2 | OPEN | stub issue %s\n' "$new_round" "$new_round" >> "$ISS"
  if [ "$new_round" -ge "${STUB_CONVERGE_AT:-9999}" ]; then status=CONVERGED; else status=RUNNING; fi
fi
cat > "$STATE" <<EOS
# STATE
round: $new_round
converged_streak: $streak
status: $status
max_rounds: 12
EOS
# D-05 fixtures: STUB_STDERR is emitted verbatim on stderr, STUB_STDERR_LINES
# repeats a numbered line that many times (tail-cap cases).
[ -n "${STUB_STDERR:-}" ] && printf '%s\n' "$STUB_STDERR" >&2
if [ -n "${STUB_STDERR_LINES:-}" ]; then
  i=1; while [ "$i" -le "$STUB_STDERR_LINES" ]; do printf 'stderr line %s.\n' "$i" >&2; i=$((i+1)); done
fi
# STUB_STDERR_BLANK: a capture holding one newline and nothing else — the other
# way session_err_log's body comes out empty, which must not be reported as a
# line longer than the byte cap.
[ -n "${STUB_STDERR_BLANK:-}" ] && printf '\n' >&2
# STUB_GRANDCHILD: the cross-session fd-2 fixture. Session 1 pushes the shared
# offset past the tail window and leaves a background process holding fd 2;
# session 2 prints its own error and lingers long enough for that process to
# write. Branches on the round it READ, so one env var drives both sessions.
if [ -n "${STUB_GRANDCHILD:-}" ]; then
  if [ "$round" -le 0 ]; then
    i=1; while [ "$i" -le 400 ]; do printf 'padding line %s.\n' "$i" >&2; i=$((i+1)); done
    # `gc-done` is the self-probe: if the timing ever stops overlapping, both of
    # the case's assertions pass against a BROKEN driver, and a false PASS is the
    # failure mode nobody notices. The test asserts this file exists, the same
    # way tests/portability/bash3.test.sh self-probes its own detector.
    ( sleep 1; printf 'LATE WRITE FROM SESSION ONE GRANDCHILD\n' >&2; : > gc-done ) &
  else
    printf 'THE REAL ERROR OF SESSION 2 WAS AN EXPIRED KEY\n' >&2
    sleep 2
  fi
fi
# STUB_STDERR_LONGLINE: ONE line longer than the driver's 4000-byte cap, with a
# labelled credential positioned so that cap's cut lands INSIDE the value — the
# shape that amputated `"api_key":"` and published the surviving suffix.
if [ -n "${STUB_STDERR_LONGLINE:-}" ]; then
  lval='LEAKCANARY9876543210ABCDEFGHIJK'
  lhead='HTTP 401 request dump {"url":"https://api.example.com/v1/messages","api_key":"'
  ltail='","body":"'
  # Solve for the padding so the driver's 4000-byte cut lands exactly 12
  # characters into the value. Every literal on the line has to be in this sum —
  # adding the ENDOFLONGLINE marker without subtracting it moved the cut 13 bytes
  # and left the leak assertion asserting a fragment that was never at risk.
  lmark='ENDOFLONGLINE'
  lfill=$(( 4000 + 12 - ${#lval} - ${#ltail} - ${#lmark} - 2 ))
  lpad=$(awk -v n="$lfill" 'BEGIN{s="";while(length(s)<n)s=s "x";print substr(s,1,n)}')
  printf '%s%s%s%s%s"}\n' "$lhead" "$lval" "$ltail" "$lpad" "$lmark" >&2
fi
echo "stub-codex: round=$new_round streak=$streak status=$status"
exit "${STUB_EXIT:-0}"
STUB
  chmod +x "$stub"
  echo "$stub"
}

sessions_in_log() {
  local f="$1/docs/looptesting/driver.log"
  [ -f "$f" ] || { echo 0; return; }
  grep -acE '^session [0-9]+:' "$f" 2>/dev/null || true
}

assert_rc()  { if [ "$1" -eq "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $3 — expected rc $2 got $1" >&2; fi; }
assert_eq()  { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $3 — expected [$1] got [$2]" >&2; fi; }
assert_file_contains() { if grep -qaF -- "$2" "$1" 2>/dev/null; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $3 — $1 lacks [$2]" >&2; fi; }
assert_file_lacks() { if grep -qaF -- "$2" "$1" 2>/dev/null; then FAIL=$((FAIL+1)); echo "  FAIL: $3 — $1 still contains [$2]" >&2; else PASS=$((PASS+1)); fi; }
report() { echo "$1: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; }
