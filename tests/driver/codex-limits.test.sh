#!/usr/bin/env bash
# unattended-codex.sh: fail-closed limits — no-progress breaker, max-sessions,
# max-minutes, argument validation. Stub codex + --no-protect throughout.
set -u
. "$(cd "$(dirname "$0")" && pwd)/codex-lib.sh"

# A. no-progress: two consecutive sessions with no change -> exit 5
WS=$(mk_proj); trap 'rm -rf "$WS"' EXIT
stub=$(write_stub "$WS")
write_state "$WS" RUNNING 1
STUB_NO_PROGRESS=1 bash "$CODEX_DRIVER" --project "$WS" --codex-bin "$stub" --no-protect >/dev/null 2>&1
assert_rc $? 5 "no-progress breaker -> exit 5"
assert_file_contains "$WS/docs/looptesting/driver.log" "NO_PROGRESS" "driver.log records NO_PROGRESS"

# B. max-sessions before terminal -> exit 3, launches exactly N sessions
WS2=$(mk_proj); trap 'rm -rf "$WS" "$WS2"' EXIT
stub=$(write_stub "$WS2")
write_state "$WS2" RUNNING 0
# stub advances round each call but never converges (STUB_CONVERGE_AT unset=9999)
bash "$CODEX_DRIVER" --project "$WS2" --codex-bin "$stub" --no-protect --max-sessions 3 >/dev/null 2>&1
assert_rc $? 3 "max-sessions cap -> exit 3"
assert_eq "3" "$(sessions_in_log "$WS2")" "exactly 3 sessions before cap"

# C. max-minutes=0 -> exit 4 immediately, zero sessions
WS3=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3"' EXIT
stub=$(write_stub "$WS3")
write_state "$WS3" RUNNING 0
bash "$CODEX_DRIVER" --project "$WS3" --codex-bin "$stub" --no-protect --max-minutes 0 >/dev/null 2>&1
assert_rc $? 4 "max-minutes=0 -> exit 4"
assert_eq "0" "$(sessions_in_log "$WS3")" "no session launched when out of time"

# D. missing --project -> usage error exit 2
bash "$CODEX_DRIVER" --codex-bin /bin/true --no-protect >/dev/null 2>&1
assert_rc $? 2 "missing --project -> exit 2"

# E. non-integer --max-minutes -> usage error exit 2
WS4=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4"' EXIT
bash "$CODEX_DRIVER" --project "$WS4" --codex-bin /bin/true --no-protect --max-minutes abc >/dev/null 2>&1
assert_rc $? 2 "non-integer --max-minutes -> exit 2"
# The message must name the REAL flag (--max-minutes), not the internal variable
# lowercased (--max_minutes), which is not a flag this driver accepts.
OUT=$(bash "$CODEX_DRIVER" --project "$WS4" --codex-bin /bin/true --no-protect --max-minutes abc 2>&1)
case "$OUT" in
  *"--max-minutes"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: validation error must name --max-minutes — got: $OUT" >&2 ;;
esac

# F. value-taking flag as the LAST token must fail-closed (exit 2), never hang.
# (Regression guard: `shift 2` on a 1-arg tail is a no-op -> infinite loop.)
bounded 10 bash "$CODEX_DRIVER" --project >/dev/null 2>&1
assert_rc $? 2 "trailing --project -> exit 2 (no hang)"
bounded 10 bash "$CODEX_DRIVER" --project "$WS4" --max-sessions >/dev/null 2>&1
assert_rc $? 2 "trailing --max-sessions -> exit 2 (no hang)"

# F2. That line used to pass `--project /tmp` — a real host directory handed to a
# driver that also protects and restores a skill dir, on the assumption that
# argument validation runs first. Same treatment as driver-limits E3: aim it at a
# throwaway project that has run nothing, and assert the assumption.
assert_eq "0" "$(sessions_in_log "$WS4")" "a usage error launches no session in the project it was aimed at"
if [ -e "$WS4/docs/looptesting/.driver.lock" ]; then
  FAIL=$((FAIL+1)); echo "  FAIL: a usage error acquired the project's driver lock" >&2
else PASS=$((PASS+1)); fi

# G. Watchdog binary detection falls back to `gtimeout` when GNU `timeout` is
# absent (macOS/Homebrew coreutils). Evaluate the detection logic under a PATH
# where only a stub gtimeout exists, then assert the driver actually carries the
# fallback branch (kept identical to unattended-loop.sh).
WS5=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5"' EXIT
mkdir -p "$WS5/bin"; printf '#!/bin/sh\nexit 0\n' > "$WS5/bin/gtimeout"; chmod +x "$WS5/bin/gtimeout"
# Subshell with PATH restricted to the stub dir; command/echo are builtins so no
# real coreutils are needed to resolve them.
got=$(
  PATH="$WS5/bin"
  TIMEOUT_BIN=""
  if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN=timeout
  elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN=gtimeout; fi
  echo "$TIMEOUT_BIN"
)
assert_eq "gtimeout" "$got" "watchdog detection falls back to gtimeout when timeout absent"
assert_file_contains "$CODEX_DRIVER" "elif command -v gtimeout" "codex driver carries the gtimeout fallback branch"

# H. Progress via convergence + evidence only (round/issues static, streak + runs/
#    evidence advance) must NOT trip NO_PROGRESS (audit A3). Mirrors loop driver F.
WS6=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6"' EXIT
stub=$(write_stub "$WS6")
write_state "$WS6" RUNNING 1
STUB_STREAK_ONLY=1 bash "$CODEX_DRIVER" --project "$WS6" --codex-bin "$stub" --no-protect --max-sessions 3 >/dev/null 2>&1
assert_rc $? 3 "streak+evidence progress (round/issues static) -> max-sessions, not NO_PROGRESS"

# I. STATE.md never created -> fail fast after exactly 1 session, not 2 (audit C9).
WS7=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7"' EXIT
stub=$(write_stub "$WS7")
STUB_NO_STATE=1 bash "$CODEX_DRIVER" --project "$WS7" --codex-bin "$stub" --no-protect --max-sessions 5 >/dev/null 2>&1
assert_rc $? 5 "absent STATE.md -> exit 5"
assert_eq "1" "$(sessions_in_log "$WS7")" "exits after exactly 1 STATE-less session (not 2)"

# J. Round-0 progress: round/issues/streak static and NO runs/ file, but PLAN.md +
#    FEATURE_MATRIX.md grow each session. Must NOT trip NO_PROGRESS (audit PL-2).
#    Mirrors loop driver H.
WS8=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8"' EXIT
stub=$(write_stub "$WS8")
write_state "$WS8" RUNNING 0
STUB_BOOTSTRAP=1 bash "$CODEX_DRIVER" --project "$WS8" --codex-bin "$stub" --no-protect --max-sessions 3 >/dev/null 2>&1
assert_rc $? 3 "round-0 bootstrap progress (PLAN/FEATURE_MATRIX grow) -> max-sessions, not NO_PROGRESS"

# K. driver.log not writable -> die exit 2 BEFORE any session (parity with the loop
#    driver's writability guard; R16 gained this for codex but had no dedicated test).
WS9=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9"' EXIT
mkdir "$WS9/docs/looptesting/driver.log"   # append to a directory fails -> guard fires
stub=$(write_stub "$WS9")
bash "$CODEX_DRIVER" --project "$WS9" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_rc $? 2 "unwritable driver.log -> die exit 2"
assert_eq "0" "$(sessions_in_log "$WS9")" "no session launched when driver.log is unwritable"

# L. Concurrency guard: a second codex driver is refused while a LIVE holder holds
#    the lock -> exit 2 (audit DR-4; mirrors loop driver J). Live holder = $$.
WS10=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10"' EXIT
mkdir -p "$WS10/docs/looptesting/.driver.lock"
echo "$$" > "$WS10/docs/looptesting/.driver.lock/pid"
stub=$(write_stub "$WS10"); write_state "$WS10" RUNNING 0
bash "$CODEX_DRIVER" --project "$WS10" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_rc $? 2 "live driver holds the lock -> concurrent codex run refused (exit 2)"
assert_eq "0" "$(sessions_in_log "$WS10")" "no session launched while the lock is held"

# M. Stale lock (dead holder) stolen; run proceeds and releases the lock on exit
#    (audit DR-4; mirrors loop driver K). Dead holder = a just-exited child PID.
WS11=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11"' EXIT
mkdir -p "$WS11/docs/looptesting/.driver.lock"
echo "$(bash -c 'echo $$')" > "$WS11/docs/looptesting/.driver.lock/pid"
stub=$(write_stub "$WS11"); write_state "$WS11" RUNNING 0
STUB_CONVERGE_AT=1 bash "$CODEX_DRIVER" --project "$WS11" --codex-bin "$stub" --no-protect --max-sessions 3 >/dev/null 2>&1
assert_rc $? 0 "stale lock stolen -> run proceeds to convergence (exit 0)"
if [ -e "$WS11/docs/looptesting/.driver.lock" ]; then FAIL=$((FAIL+1)); echo "  FAIL: lock not released on normal exit" >&2; else PASS=$((PASS+1)); fi

# N. Fail-closed: a lock dir whose holder PID is unreadable/absent must be REFUSED,
#    not stolen (DR-4 hardening from code review; mirrors loop driver L).
WS12=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12"' EXIT
mkdir -p "$WS12/docs/looptesting/.driver.lock"   # lock dir present, NO pid file
stub=$(write_stub "$WS12"); write_state "$WS12" RUNNING 0
bash "$CODEX_DRIVER" --project "$WS12" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_rc $? 2 "lock with no readable holder PID -> refused (fail-closed), not stolen"
assert_eq "0" "$(sessions_in_log "$WS12")" "no session launched on an ambiguous lock"

# O. A REFUSED concurrent driver must not un-protect the running driver's skill
#    dir (CX-1). Driver A is simulated by a live-holder lock ($$ — no background
#    jobs, see DR-4 fixture lesson) plus an already read-only FAKE skill dir
#    (mktemp, NEVER the real ~/.codex). Driver B runs WITHOUT --no-protect against
#    that dir: it must exit 2 AND leave the dir non-writable — the old cleanup
#    chmod'd it back to u+w on the way out of the refused run.
WS13=$(mk_proj); FAKE13=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-fakeskill.XXXXXX")
trap 'chmod -R u+w "$FAKE13" 2>/dev/null; rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$FAKE13"' EXIT
printf 'SKILL\n' > "$FAKE13/SKILL.md"
chmod -R a-w "$FAKE13"                                    # driver A's protection in effect
mkdir -p "$WS13/docs/looptesting/.driver.lock"
echo "$$" > "$WS13/docs/looptesting/.driver.lock/pid"     # live holder = this test
stub=$(write_stub "$WS13"); write_state "$WS13" RUNNING 0
bash "$CODEX_DRIVER" --project "$WS13" --codex-bin "$stub" --skill-dir "$FAKE13" --max-sessions 1 >/dev/null 2>&1
assert_rc $? 2 "live lock + protect on -> concurrent run still refused (exit 2)"
if [ -w "$FAKE13/SKILL.md" ]; then
  FAIL=$((FAIL+1)); echo "  FAIL: refused driver un-protected the running driver's skill dir (CX-1)" >&2
else
  PASS=$((PASS+1)); echo "  ok: refused concurrent driver leaves skill-dir protection intact (CX-1)"
fi

# P. DR-7: neither `timeout` nor `gtimeout` on PATH -> refuse to start (exit 2,
#    zero sessions) instead of running sessions unbounded. Mirrors loop driver M.
WS14=$(mk_proj); BINF=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-nowd.XXXXXX")
trap 'chmod -R u+w "$FAKE13" 2>/dev/null; rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$FAKE13" "$WS14" "$BINF"' EXIT
for p in /bin/* /usr/bin/*; do [ -x "$p" ] && ln -sf "$p" "$BINF/${p##*/}" 2>/dev/null; done
rm -f "$BINF/timeout" "$BINF/gtimeout"
stub=$(write_stub "$WS14"); write_state "$WS14" RUNNING 0
( PATH="$BINF" bash "$CODEX_DRIVER" --project "$WS14" --codex-bin "$stub" --no-protect --max-sessions 1 ) >/dev/null 2>&1
assert_rc $? 2 "no watchdog binary -> refuse to start (exit 2) (DR-7)"
assert_eq "0" "$(sessions_in_log "$WS14")" "no session launched without a watchdog"

# Q. DR-7: --no-watchdog accepts unbounded sessions -> run proceeds + WARNING in
#    driver.log. Mirrors loop driver N.
WS15=$(mk_proj); trap 'chmod -R u+w "$FAKE13" 2>/dev/null; rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$FAKE13" "$WS14" "$BINF" "$WS15"' EXIT
stub=$(write_stub "$WS15"); write_state "$WS15" RUNNING 0
( PATH="$BINF" STUB_CONVERGE_AT=1 bash "$CODEX_DRIVER" --project "$WS15" --codex-bin "$stub" --no-protect --no-watchdog --max-sessions 3 ) >/dev/null 2>&1
assert_rc $? 0 "--no-watchdog: run proceeds to convergence without a watchdog binary"
assert_file_contains "$WS15/docs/looptesting/driver.log" "WARNING: no timeout/gtimeout" "driver.log warns that the watchdog is disabled"

# R. Watchdog KILL path (R49): a hung codex session is killed by the wall-clock
#    watchdog (rc 124 in driver.log); two static sessions trip NO_PROGRESS.
#    Mirrors loop driver O.
WS16=$(mk_proj); trap 'chmod -R u+w "$FAKE13" 2>/dev/null; rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$FAKE13" "$WS14" "$BINF" "$WS15" "$WS16"' EXIT
printf '#!/usr/bin/env bash\nsleep 300\n' > "$WS16/hang-stub.sh"; chmod +x "$WS16/hang-stub.sh"
write_state "$WS16" RUNNING 1
bash "$CODEX_DRIVER" --project "$WS16" --codex-bin "$WS16/hang-stub.sh" --no-protect --session-minutes 0 --max-sessions 5 >/dev/null 2>&1
assert_rc $? 5 "hung sessions killed by the watchdog -> NO_PROGRESS exit 5"
assert_eq "2" "$(sessions_in_log "$WS16")" "watchdog bounded exactly 2 hung sessions"
assert_file_contains "$WS16/docs/looptesting/driver.log" "exit=124" "driver.log records the watchdog kill (rc 124)"

# R2. D-07: --no-watchdog waives the refusal in P and nothing else. With a
#     watchdog binary on PATH it grants nothing — the hung session is still
#     killed — and that used to happen in silence, while the flag's name and the
#     refusal text both read as a promise of unbounded sessions. Mirrors loop N2.
WS16B=$(mk_proj)
trap 'chmod -R u+w "$FAKE13" 2>/dev/null; rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$FAKE13" "$WS14" "$BINF" "$WS15" "$WS16" "$WS16B"' EXIT
# Premise checked, not assumed — see the note on driver-limits N2 (review P-04):
# without a watchdog binary the flag waives the refusal for real, the 300s stub
# runs twice, and the headline rc-5 assertion passes in both worlds anyway.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  printf '#!/usr/bin/env bash\nsleep 300\n' > "$WS16B/hang-stub.sh"; chmod +x "$WS16B/hang-stub.sh"
  write_state "$WS16B" RUNNING 1
  bash "$CODEX_DRIVER" --project "$WS16B" --codex-bin "$WS16B/hang-stub.sh" --no-protect --no-watchdog \
    --session-minutes 0 --max-sessions 5 >/dev/null 2>&1
  assert_rc $? 5 "--no-watchdog with a watchdog binary present: hung sessions still bounded (exit 5)"
  assert_file_contains "$WS16B/docs/looptesting/driver.log" "exit=124" "--no-watchdog does not disable the wall-clock kill (D-07)"
  assert_file_contains "$WS16B/docs/looptesting/driver.log" "no effect" "driver.log states the flag does not apply when a watchdog binary exists (D-07)"
else
  echo "  skip: no timeout/gtimeout on PATH — R2 is about the host that HAS one"
fi

# S. The skill-dir protection must RESTORE the original mode, not just u+w. The
#    header promises "restored on EXIT"; protecting with `a-w` and restoring with
#    `u+w` silently strips group/other write bits from the user's installed skill
#    dir (~/.codex/skills/loop-testing) on every run — permanent on a shared,
#    group-writable install.
WS17=$(mk_proj); FAKE17=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-fakeskill.XXXXXX")
trap 'chmod -R u+w "$FAKE13" "$FAKE17" 2>/dev/null; rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$FAKE13" "$WS14" "$BINF" "$WS15" "$WS16" "$WS16B" "$WS17" "$FAKE17"' EXIT
mkdir -p "$FAKE17/scripts"
printf 'SKILL\n' > "$FAKE17/SKILL.md"
printf 'x\n' > "$FAKE17/scripts/a.sh"
chmod -R 775 "$FAKE17"                                    # group-writable shared install
printf 'locked\n' > "$FAKE17/frozen.txt"
chmod 444 "$FAKE17/frozen.txt"                            # deliberately read-only BEFORE the run
write_state "$WS17" CONVERGED 1                           # terminal at once: protect -> exit
bash "$CODEX_DRIVER" --project "$WS17" --codex-bin /bin/true --skill-dir "$FAKE17" >/dev/null 2>&1
assert_rc $? 0 "terminal STATE with protection on -> exit 0"
assert_eq "775" "$(stat -c '%a' "$FAKE17" 2>/dev/null || stat -f '%Lp' "$FAKE17")" "skill dir mode restored exactly"
assert_eq "775" "$(stat -c '%a' "$FAKE17/SKILL.md" 2>/dev/null || stat -f '%Lp' "$FAKE17/SKILL.md")" "skill file mode restored exactly"
assert_eq "775" "$(stat -c '%a' "$FAKE17/scripts/a.sh" 2>/dev/null || stat -f '%Lp' "$FAKE17/scripts/a.sh")" "nested skill file mode restored exactly"
# The blanket `chmod -R u+w` restore also hands owner-write to files that were
# deliberately read-only before the run — a permission grant the user never made.
assert_eq "444" "$(stat -c '%a' "$FAKE17/frozen.txt" 2>/dev/null || stat -f '%Lp' "$FAKE17/frozen.txt")" "an already-read-only file stays read-only"

# T. Documented shutdown, codex side: a signal to the process group must STOP the
#    driver. `trap cleanup EXIT INT TERM` returned into the loop, so the signal
#    only un-protected the skill dir and dropped the lock while full-access
#    sessions kept launching. Mirrors loop driver P.
if command -v setsid >/dev/null 2>&1; then
  WS18=$(mk_proj); FAKE18=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-fakeskill.XXXXXX")
  trap 'chmod -R u+w "$FAKE13" "$FAKE17" "$FAKE18" 2>/dev/null; rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$FAKE13" "$WS14" "$BINF" "$WS15" "$WS16" "$WS16B" "$WS17" "$FAKE17" "$WS18" "$FAKE18"' EXIT
  printf 'SKILL\n' > "$FAKE18/SKILL.md"
  LT18="$WS18/docs/looptesting"; mkdir -p "$LT18/runs"
  cat > "$WS18/slow-stub.sh" <<'SLOW'
#!/usr/bin/env bash
sleep 2
printf '# STATE\nround: 0\nconverged_streak: 0\nstatus: RUNNING\n' > docs/looptesting/STATE.md
printf 'evidence %s\n' "$(date +%s%N)" >> docs/looptesting/runs/round-0.md
SLOW
  chmod +x "$WS18/slow-stub.sh"
  write_state "$WS18" RUNNING 0
  setsid bash "$CODEX_DRIVER" --project "$WS18" --codex-bin "$WS18/slow-stub.sh" \
    --skill-dir "$FAKE18" --max-sessions 50 --max-minutes 5 >/dev/null 2>&1 &
  DRV18="$(wait_lock_pid "$WS18")"
  if [ -n "$DRV18" ]; then
    PGID18=$(ps -o pgid= -p "$DRV18" 2>/dev/null | tr -d ' ')
    kill -TERM -- -"$PGID18" 2>/dev/null
    wait_pid_gone "$DRV18" || :
    if kill -0 "$DRV18" 2>/dev/null; then
      FAIL=$((FAIL+1)); echo "  FAIL: SIGTERM to the codex driver process group did not stop it" >&2
      kill -9 "$DRV18" 2>/dev/null
      for c in $(pgrep -P "$DRV18" 2>/dev/null); do kill -9 "$c" 2>/dev/null; done
    else
      PASS=$((PASS+1))
      # The shutdown path must still restore the skill dir it protected.
      if [ -w "$FAKE18/SKILL.md" ]; then PASS=$((PASS+1)); else
        FAIL=$((FAIL+1)); echo "  FAIL: signal shutdown left the skill dir read-only" >&2; fi
    fi
  else
    FAIL=$((FAIL+1))
    echo "  FAIL: no lock pid appeared within $(test_wait_budget)s — this run never reached the state the case is about, so it is not evidence about the shutdown path in either direction (audit T-08)" >&2
  fi
else
  echo "  skip: setsid unavailable — process-group shutdown test not run"
fi

# U. The protect/restore WINDOW: DID_PROTECT must be armed BEFORE the chmod runs.
#    Setting it after means a signal delivered while `chmod -R` is still walking the
#    tree exits through a cleanup that sees DID_PROTECT=0, skips the restore, and
#    leaves the user's installed ~/.codex/skills/loop-testing permanently
#    non-owner-writable — the exact case the file's own comment says the trap
#    ordering exists to prevent. A slow `chmod` shim on PATH widens the window so
#    the race is deterministic instead of a ~60ms coin flip.
if command -v setsid >/dev/null 2>&1; then
  WS19=$(mk_proj)
  FAKE19=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-fakeskill.XXXXXX")
  SHIM19=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-shim.XXXXXX")
  trap 'chmod -R u+w "$FAKE13" "$FAKE17" "$FAKE18" "$FAKE19" 2>/dev/null; rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$WS11" "$WS12" "$WS13" "$FAKE13" "$WS14" "$BINF" "$WS15" "$WS16" "$WS16B" "$WS17" "$FAKE17" "$WS18" "$FAKE18" "$WS19" "$FAKE19" "$SHIM19"' EXIT
  mkdir -p "$FAKE19/scripts"
  printf 'SKILL\n' > "$FAKE19/SKILL.md"
  printf 'x\n' > "$FAKE19/scripts/a.sh"
  chmod -R 755 "$FAKE19"
  printf 'locked\n' > "$FAKE19/frozen.txt"
  chmod 444 "$FAKE19/frozen.txt"
  REAL_CHMOD19=$(command -v chmod)
  # Slow ONLY the first chmod — the protect call whose window this test targets.
  # Slowing every chmod also slows cleanup's blanket restore and each read-only
  # re-apply, stacking three shim sleeps into the shutdown path and making the
  # wait below load-sensitive (observed once as a full-suite-only failure).
  cat > "$SHIM19/chmod" <<SHIM
#!/usr/bin/env bash
if [ ! -e "$SHIM19/.fired" ]; then
  : > "$SHIM19/.fired"
  sleep 3
fi
exec "$REAL_CHMOD19" "\$@"
SHIM
  chmod +x "$SHIM19/chmod"
  write_state "$WS19" RUNNING 0
  stub19=$(write_stub "$WS19")
  setsid env PATH="$SHIM19:$PATH" bash "$CODEX_DRIVER" --project "$WS19" --codex-bin "$stub19" \
    --skill-dir "$FAKE19" --max-sessions 1 >/dev/null 2>&1 &
  DRV19="$(wait_lock_pid "$WS19")"
  if [ -n "$DRV19" ]; then
    # The lock is written immediately before the protect chmod, so the driver is
    # inside the (shimmed, slow) chmod right now.
    kill -TERM "$DRV19" 2>/dev/null
    # `|| :` here threw the expiry away (review T-5), and the two assertions
    # below then ran regardless: on a timeout the driver is SIGKILLed mid-cleanup
    # and blamed for a read-only skill dir, while the idempotence assertion
    # passes over a run in which cleanup never ran twice — or at all. That is
    # the half of T-08 85dbb80 claims to have closed, left open one line later.
    if wait_pid_gone "$DRV19"; then
      kill -9 "$DRV19" 2>/dev/null
      if [ -w "$FAKE19/SKILL.md" ] && [ -w "$FAKE19/scripts/a.sh" ]; then
        PASS=$((PASS+1))
      else
        FAIL=$((FAIL+1)); echo "  FAIL: signal during the protect chmod left the skill dir read-only (restore skipped)" >&2
      fi
      # The signal handler exits, which fires the EXIT trap too — so cleanup runs
      # TWICE. A second pass that re-runs the blanket `chmod -R u+w` after the
      # read-only snapshot has been consumed silently re-grants write.
      assert_eq "444" "$(stat -c '%a' "$FAKE19/frozen.txt" 2>/dev/null || stat -f '%Lp' "$FAKE19/frozen.txt")" \
        "cleanup is idempotent: the second pass does not re-grant write"
    else
      kill -9 "$DRV19" 2>/dev/null
      FAIL=$((FAIL+1))
      echo "  FAIL: the driver outlived $(test_wait_budget)s after SIGTERM — this run never left the protect window, so it is not evidence about the restore in either direction (audit T-08)" >&2
    fi
  else
    FAIL=$((FAIL+1))
    echo "  FAIL: no lock pid appeared within $(test_wait_budget)s — this run never reached the protect window, so it is not evidence about the restore in either direction (audit T-08)" >&2
  fi
else
  echo "  skip: setsid unavailable — protect-window test not run"
fi

report "codex-limits.test.sh"
