#!/usr/bin/env bash
# unattended-loop.sh fail-closed limits: no-progress breaker, max-sessions cap,
# max-minutes cap.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# A. NO_PROGRESS: two consecutive sessions with no change -> exit 5
WS=$(mk_proj); trap 'rm -rf "$WS"' EXIT
stub=$(write_stub "$WS")
write_state "$WS" RUNNING 0
STUB_NO_PROGRESS=1 bash "$DRIVER" --project "$WS" --claude-bin "$stub" --max-sessions 10 >/dev/null 2>&1
assert_rc $? 5 "no-progress circuit breaker -> exit 5"
assert_eq "2" "$(sessions_in_log "$WS")" "breaker fires after 2 stuck sessions"
assert_file_contains "$WS/docs/looptesting/driver.log" "NO_PROGRESS" "driver.log records NO_PROGRESS"

# B. max-sessions cap without convergence -> exit 3
WS2=$(mk_proj); trap 'rm -rf "$WS" "$WS2"' EXIT
stub=$(write_stub "$WS2")
write_state "$WS2" RUNNING 0
# stub advances round each call (never converges) so no-progress never fires
bash "$DRIVER" --project "$WS2" --claude-bin "$stub" --max-sessions 3 >/dev/null 2>&1
assert_rc $? 3 "hit --max-sessions -> exit 3"
assert_eq "3" "$(sessions_in_log "$WS2")" "exactly max-sessions sessions ran"
assert_file_contains "$WS2/docs/looptesting/driver.log" "hit --max-sessions" "driver.log records max-sessions INCOMPLETE"

# C. max-minutes cap (0 minutes) -> exit 4 before any session
WS3=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3"' EXIT
stub=$(write_stub "$WS3")
write_state "$WS3" RUNNING 0
bash "$DRIVER" --project "$WS3" --claude-bin "$stub" --max-minutes 0 >/dev/null 2>&1
assert_rc $? 4 "hit --max-minutes -> exit 4"
assert_eq "0" "$(sessions_in_log "$WS3")" "no session launched past the time budget"

# D. usage error: missing --project -> exit 2
bash "$DRIVER" --claude-bin /bin/true >/dev/null 2>&1
assert_rc $? 2 "missing --project -> exit 2"

# E. value-taking flag as the LAST token must fail-closed (exit 2), never hang.
# (Regression guard: `shift 2` on a 1-arg tail is a no-op -> infinite loop.)
timeout 10 bash "$DRIVER" --project >/dev/null 2>&1
assert_rc $? 2 "trailing --project -> exit 2 (no hang)"
timeout 10 bash "$DRIVER" --project /tmp --max-turns >/dev/null 2>&1
assert_rc $? 2 "trailing --max-turns -> exit 2 (no hang)"

# F. Progress via convergence + evidence only (round AND issue count static, but
#    converged_streak advances and runs/ evidence grows) must NOT trip NO_PROGRESS
#    — the old round+issues-only signal misread this as stuck (audit A3).
WS4=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4"' EXIT
stub=$(write_stub "$WS4")
write_state "$WS4" RUNNING 1
STUB_STREAK_ONLY=1 bash "$DRIVER" --project "$WS4" --claude-bin "$stub" --max-sessions 3 >/dev/null 2>&1
assert_rc $? 3 "streak+evidence progress (round/issues static) -> runs to max-sessions, not NO_PROGRESS"

# G. STATE.md never created -> fail fast after exactly 1 session, not 2 (audit C9).
WS5=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5"' EXIT
stub=$(write_stub "$WS5")   # no write_state: STATE.md stays absent; stub writes none
STUB_NO_STATE=1 bash "$DRIVER" --project "$WS5" --claude-bin "$stub" --max-sessions 5 >/dev/null 2>&1
assert_rc $? 5 "absent STATE.md -> exit 5"
assert_eq "1" "$(sessions_in_log "$WS5")" "exits after exactly 1 STATE-less session (not 2)"

# H. Round-0 progress: round/issues/streak static and NO runs/ file, but PLAN.md +
#    FEATURE_MATRIX.md grow each session (project-analysis phase). Must NOT trip
#    NO_PROGRESS — the round+issues+streak+runs signal alone misread a multi-session
#    round 0 as stuck (audit PL-2).
WS6=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6"' EXIT
stub=$(write_stub "$WS6")
write_state "$WS6" RUNNING 0
STUB_BOOTSTRAP=1 bash "$DRIVER" --project "$WS6" --claude-bin "$stub" --max-sessions 3 >/dev/null 2>&1
assert_rc $? 3 "round-0 bootstrap progress (PLAN/FEATURE_MATRIX grow) -> runs to max-sessions, not NO_PROGRESS"

# I. F6 coordinator-mode env sanitization: vars that would boot the child session in
#    orchestration-only mode (Agent/SendMessage/TaskStop/Workflow, no Read/Bash/Edit/
#    Write) must NOT reach the child. The stub records which survived into its own env.
WS7=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7"' EXIT
cat > "$WS7/envstub.sh" <<'ESTUB'
#!/usr/bin/env bash
set -u
env | grep -aE '^CLAUDE_CODE_(COORDINATOR_MODE|EXPERIMENTAL_AGENT_TEAMS|CHILD_SESSION|SESSION_ID)=' \
  > docs/looptesting/child-env.txt || true
cat > docs/looptesting/STATE.md <<EOS
# STATE
round: 0
converged_streak: 2
status: CONVERGED
max_rounds: 12
EOS
exit 0
ESTUB
chmod +x "$WS7/envstub.sh"
CLAUDE_CODE_COORDINATOR_MODE=1 CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CODE_SESSION_ID=sess-abc \
  bash "$DRIVER" --project "$WS7" --claude-bin "$WS7/envstub.sh" --max-sessions 1 >/dev/null 2>&1
assert_rc $? 0 "converged after a sanitized session -> exit 0"
assert_eq "" "$(cat "$WS7/docs/looptesting/child-env.txt" 2>/dev/null)" "coordinator-mode env vars unset for the child (F6)"

# J. Concurrency guard: a second driver is refused while a LIVE holder holds the lock
#    (two drivers would race STATE/ledger/worktree) -> exit 2 (audit DR-4). The live
#    holder is THIS test process ($$), so no background fixture is needed.
WS8=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8"' EXIT
mkdir -p "$WS8/docs/looptesting/.driver.lock"
echo "$$" > "$WS8/docs/looptesting/.driver.lock/pid"
stub=$(write_stub "$WS8"); write_state "$WS8" RUNNING 0
bash "$DRIVER" --project "$WS8" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_rc $? 2 "live driver holds the lock -> concurrent run refused (exit 2)"
assert_eq "0" "$(sessions_in_log "$WS8")" "no session launched while the lock is held"

# K. A stale lock (holder PID no longer alive) is stolen; the run proceeds and the
#    lock is released on normal exit (audit DR-4). The dead PID is a just-exited
#    child ($(bash -c 'echo $$')) — no background job (which would inherit the EXIT
#    trap and delete the workspace mid-test).
WS9=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9"' EXIT
mkdir -p "$WS9/docs/looptesting/.driver.lock"
echo "$(bash -c 'echo $$')" > "$WS9/docs/looptesting/.driver.lock/pid"
stub=$(write_stub "$WS9"); write_state "$WS9" RUNNING 0
STUB_CONVERGE_AT=1 bash "$DRIVER" --project "$WS9" --claude-bin "$stub" --max-sessions 3 >/dev/null 2>&1
assert_rc $? 0 "stale lock (dead holder) stolen -> run proceeds to convergence (exit 0)"
if [ -e "$WS9/docs/looptesting/.driver.lock" ]; then FAIL=$((FAIL+1)); echo "  FAIL: lock not released on normal exit" >&2; else PASS=$((PASS+1)); fi

# L. Fail-closed: a lock dir whose holder PID is unreadable/absent must be REFUSED,
#    not stolen — never steal on ambiguity (DR-4 hardening from code review).
WS10=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10"' EXIT
mkdir -p "$WS10/docs/looptesting/.driver.lock"   # lock dir present, NO pid file
stub=$(write_stub "$WS10"); write_state "$WS10" RUNNING 0
bash "$DRIVER" --project "$WS10" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_rc $? 2 "lock with no readable holder PID -> refused (fail-closed), not stolen"
assert_eq "0" "$(sessions_in_log "$WS10")" "no session launched on an ambiguous lock"

report "driver-limits.test.sh"
