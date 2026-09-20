#!/usr/bin/env bash
# Shutdown must stop the CHILD SESSION before releasing the lock (audit D-01).
#
# `timeout` (GNU and uutils alike) calls setpgid(0,0), so every session runs in
# its own process group; the driver ran it as a foreground subshell, so a signal
# to the driver's process group killed the driver, released .driver.lock, and
# left the session — running with bypassPermissions / danger-full-access —
# alive and writing. A driver started afterwards then raced it for the same
# STATE.md and worktree. The earlier shutdown tests (driver-limits P,
# codex-limits T) only asserted that the driver PID died, which is exactly the
# half that always worked.
#
# Signalling the session is not enough on its own: `timeout` forwards SIGTERM
# and only escalates to SIGKILL after its own `-k 15`, so a driver that signals
# and exits leaves the lock free while a full-permission session is still
# shutting down — the same race, narrower. The load-bearing assertion here is
# therefore an ORDERING one: at the instant .driver.lock disappears, the session
# pid must already be gone.
#
# Fixture: the "agent" is a heartbeat stub that appends a line every 200 ms
# forever. The stubborn variant additionally ignores SIGTERM, which is what a
# real agent flushing a transcript looks like from the outside, and forces the
# driver's SIGKILL escalation (LOOP_TESTING_STOP_GRACE shortens the derived 20 s
# bound so the test costs seconds).
#
# SAFETY: mktemp project, stub binary, --no-protect on the codex side so the
# real ~/.codex is never touched. Every survivor is killed on exit.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
CODEX_DRIVER="$REPO_ROOT/skills/loop-testing/scripts/unattended-codex.sh"

WS_ALL=""
KILL_ON_EXIT=""
cleanup_all() {
  # Kill anything still beating in a fixture before removing it.
  for ws in $WS_ALL; do
    for p in $(pgrep -f "$ws/heartbeat-stub.sh" 2>/dev/null) $(pgrep -f "$ws/stubborn-stub.sh" 2>/dev/null); do
      pg=$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')
      [ -n "$pg" ] && kill -KILL -- -"$pg" 2>/dev/null
      kill -KILL "$p" 2>/dev/null
    done
  done
  for p in $KILL_ON_EXIT; do kill -KILL "$p" 2>/dev/null; done
  [ -n "$WS_ALL" ] && rm -rf $WS_ALL   # word-split on purpose
  return 0
}
trap cleanup_all EXIT

write_heartbeat_stub() { # ws -> path
  local stub="$1/heartbeat-stub.sh"
  cat > "$stub" <<'STUB'
#!/usr/bin/env bash
printf '# STATE\nround: 0\nconverged_streak: 0\nstatus: RUNNING\nmax_rounds: 12\n' > docs/looptesting/STATE.md
while :; do date +%s >> docs/looptesting/heartbeat; sleep 0.2; done
STUB
  chmod +x "$stub"; echo "$stub"
}

# A session that does NOT die on SIGTERM. It does not have to ignore the signal
# forever to matter — it only has to take longer to exit than the microseconds a
# signal-and-go handler gives it.
write_stubborn_stub() { # ws -> path
  local stub="$1/stubborn-stub.sh"
  cat > "$stub" <<'STUB'
#!/usr/bin/env bash
trap '' TERM
printf '# STATE\nround: 0\nconverged_streak: 0\nstatus: RUNNING\nmax_rounds: 12\n' > docs/looptesting/STATE.md
while :; do date +%s >> docs/looptesting/heartbeat; sleep 0.2; done
STUB
  chmod +x "$stub"; echo "$stub"
}

hb_lines() { [ -f "$1/docs/looptesting/heartbeat" ] && wc -l < "$1/docs/looptesting/heartbeat" | tr -d ' ' || echo 0; }

wait_lock_pid() { # ws -> prints the driver pid once the lock names it (≤15s)
  local pid=""
  for _ in $(seq 1 60); do
    [ -f "$1/docs/looptesting/.driver.lock/pid" ] && read -r pid < "$1/docs/looptesting/.driver.lock/pid" 2>/dev/null
    case "$pid" in ''|*[!0-9]*) pid="" ;; *) echo "$pid"; return 0 ;; esac
    sleep 0.25
  done
  return 1
}

wait_heartbeat() { # ws -> 0 once the stub has beaten at least 3 times (≤15s)
  for _ in $(seq 1 60); do [ "$(hb_lines "$1")" -ge 3 ] && return 0; sleep 0.25; done
  return 1
}

# The session pid is the driver child that LEADS its own process group — the
# same identity test the driver itself uses, so a transient command-substitution
# child can never be mistaken for the session.
session_pid() { # driver-pid
  local p pg
  for p in $(pgrep -P "$1" 2>/dev/null); do
    pg=$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')
    [ "$pg" = "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

# run_case <label> <kind: claude|codex> <method: pg-term|pg-hup|pg-quit|bare-int|pty> [stub: normal|stubborn]
run_case() {
  local label="$1" kind="$2" method="$3" stubkind="${4:-normal}"
  local ws stub drv sess pgid n1 n2 lock saw_gone raced
  ws=$(mk_proj); WS_ALL="$WS_ALL $ws"
  if [ "$stubkind" = stubborn ]; then stub=$(write_stubborn_stub "$ws"); else stub=$(write_heartbeat_stub "$ws"); fi
  write_state "$ws" RUNNING 0
  lock="$ws/docs/looptesting/.driver.lock"
  # LOOP_TESTING_STOP_GRACE=2 keeps the SIGKILL escalation inside a test's
  # patience; the derived 20 s default is asserted structurally below.
  if [ "$kind" = codex ]; then
    set -- env LOOP_TESTING_STOP_GRACE=2 bash "$CODEX_DRIVER" --project "$ws" --codex-bin "$stub" --no-protect --max-sessions 3 --max-minutes 5 --session-minutes 1
  else
    set -- env LOOP_TESTING_STOP_GRACE=2 bash "$DRIVER" --project "$ws" --claude-bin "$stub" --max-sessions 3 --max-minutes 5 --session-minutes 1
  fi
  # Every launch is an async list of a non-interactive shell, which hands it
  # SIGINT and SIGQUIT ignored — and an ignored-on-entry signal can never be
  # trapped by the driver. `trap - INT QUIT` as the FIRST statement of the async
  # subshell (not of a wrapper around it: each `&` re-ignores) gives the driver
  # what a user's terminal would. The outer `( )` keeps bash's "Hangup" job
  # notice out of the test output.
  case "$method" in
    pty)
      # A real terminal: `script` allocates a pty, the driver is its foreground
      # job, and a ^C byte written to the pty's input becomes SIGINT to that
      # foreground process group — the same path as a user's Ctrl-C.
      mkfifo "$ws/tty-in"
      exec 3<>"$ws/tty-in"
      ( ( trap - INT QUIT; exec script -q -c "$*" /dev/null < "$ws/tty-in" > /dev/null 2>&1 ) & )
      ;;
    *)
      ( ( trap - INT QUIT; exec setsid "$@" > /dev/null 2>&1 ) & )
      ;;
  esac
  drv=$(wait_lock_pid "$ws") || { FAIL=$((FAIL+1)); echo "  FAIL: $label — driver never wrote its lock pid" >&2; [ "$method" = pty ] && exec 3>&-; return 0; }
  wait_heartbeat "$ws" || { FAIL=$((FAIL+1)); echo "  FAIL: $label — child session never started beating" >&2; [ "$method" = pty ] && exec 3>&-; return 0; }
  sess=$(session_pid "$drv") || { FAIL=$((FAIL+1)); echo "  FAIL: $label — no session process group found under the driver" >&2; [ "$method" = pty ] && exec 3>&-; return 0; }
  pgid=$(ps -o pgid= -p "$drv" | tr -d ' ')
  case "$method" in
    pg-term)  kill -TERM -- -"$pgid" 2>/dev/null ;;
    pg-hup)   kill -HUP  -- -"$pgid" 2>/dev/null ;;
    pg-quit)  kill -QUIT -- -"$pgid" 2>/dev/null ;;
    bare-int) kill -INT  "$drv"      2>/dev/null ;;
    pty)      printf '\003' >&3 ;;
  esac

  # THE assertion (audit D-01): the lock may not be released while the session
  # is alive. Watch for the lock to disappear and sample the session pid at that
  # instant — a signal-and-go handler frees it in ~50 ms with the session still
  # running, and a second driver can start right there.
  saw_gone=0; raced=0
  for _ in $(seq 1 600); do
    if [ ! -e "$lock" ]; then
      saw_gone=1
      kill -0 "$sess" 2>/dev/null && raced=1
      break
    fi
    sleep 0.05
  done
  if [ "$saw_gone" = 1 ] && [ "$raced" = 0 ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1))
    if [ "$saw_gone" = 0 ]; then echo "  FAIL: $label — .driver.lock was never released" >&2
    else echo "  FAIL: $label — lock released while session pid $sess was still alive" >&2; fi
  fi

  # The driver itself must go (this half always passed).
  for _ in $(seq 1 40); do kill -0 "$drv" 2>/dev/null || break; sleep 0.25; done
  if kill -0 "$drv" 2>/dev/null; then
    FAIL=$((FAIL+1)); echo "  FAIL: $label — driver still alive after the signal" >&2
    kill -KILL "$drv" 2>/dev/null
  else PASS=$((PASS+1)); fi
  if [ -e "$lock" ]; then
    FAIL=$((FAIL+1)); echo "  FAIL: $label — .driver.lock left behind" >&2
  else PASS=$((PASS+1)); fi
  # The session stops: sample the heartbeat twice a second apart.
  n1=$(hb_lines "$ws"); sleep 1; n2=$(hb_lines "$ws")
  if [ "$n1" -eq "$n2" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $label — child session kept running after the driver died (heartbeat $n1 -> $n2)" >&2
  fi
  # And nothing from this fixture is left in the process table.
  if pgrep -f "$stub" > /dev/null 2>&1; then
    FAIL=$((FAIL+1)); echo "  FAIL: $label — orphaned session processes: $(pgrep -f "$stub" | tr '\n' ' ')" >&2
    for p in $(pgrep -f "$stub"); do pg=$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' '); [ -n "$pg" ] && kill -KILL -- -"$pg" 2>/dev/null; done
  else PASS=$((PASS+1)); fi
  [ "$method" = pty ] && exec 3>&-
  return 0
}

if ! command -v setsid > /dev/null 2>&1; then
  echo "  skip: setsid unavailable — shutdown tests need a fresh process group"
  report "shutdown.test.sh"; exit $?
fi

run_case "claude driver, SIGTERM to the process group" claude pg-term
run_case "claude driver, SIGHUP to the process group"  claude pg-hup
run_case "claude driver, SIGQUIT to the process group" claude pg-quit
run_case "claude driver, bare kill -INT <driver-pid>"  claude bare-int
run_case "codex driver, SIGTERM to the process group"  codex  pg-term
run_case "codex driver, SIGHUP to the process group"   codex  pg-hup

# A session that does not die on SIGTERM is where signal-and-go shows: the
# watchdog's own `-k 15` would not SIGKILL it for fifteen more seconds.
run_case "claude driver, SIGTERM, session ignores SIGTERM" claude pg-term stubborn
run_case "codex driver, SIGTERM, session ignores SIGTERM"  codex  pg-term stubborn

if command -v script > /dev/null 2>&1 && script -q -c true /dev/null > /dev/null 2>&1; then
  run_case "claude driver, Ctrl-C on a pty" claude pty
  run_case "codex driver, Ctrl-C on a pty"  codex  pty
else
  echo "  skip: util-linux script unavailable — pty Ctrl-C cases not run"
fi

# A bare `kill -TERM <driver-pid>` — no process group — must be honored WHILE a
# session runs, not deferred to the session boundary (bash only defers a trap
# for a foreground child; `wait` is interruptible), and the exit status must be
# the conventional 128+n so a supervisor can tell "stopped by the operator" from
# "loop ended" (0) or "limits" (3-5). The elapsed bound is what discriminates:
# the old driver also exited 143 — after the 60 s watchdog had ended the session
# for it — so a heartbeat check here would pass on the unfixed driver too.
WS=$(mk_proj); WS_ALL="$WS_ALL $WS"
stub=$(write_heartbeat_stub "$WS"); write_state "$WS" RUNNING 0
( pid=""; for _ in $(seq 1 60); do
    [ -f "$WS/docs/looptesting/.driver.lock/pid" ] && read -r pid < "$WS/docs/looptesting/.driver.lock/pid" 2>/dev/null
    case "$pid" in ''|*[!0-9]*) pid=""; sleep 0.25 ;; *) break ;; esac
  done
  for _ in $(seq 1 60); do [ "$(hb_lines "$WS")" -ge 3 ] && break; sleep 0.25; done
  [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null ) &
t0=$(date +%s)
bash "$DRIVER" --project "$WS" --claude-bin "$stub" --max-sessions 3 --max-minutes 5 --session-minutes 1 > /dev/null 2>&1
rc=$?
elapsed=$(( $(date +%s) - t0 ))
wait 2>/dev/null
assert_rc "$rc" 143 "a bare kill -TERM <driver-pid> during a session exits 143"
if [ "$elapsed" -lt 20 ]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: bare kill -TERM was deferred to the session boundary (driver ran ${elapsed}s)" >&2; fi

# ── the two branches a test cannot stage ──────────────────────────────────────
# A process that outlives SIGKILL needs an uninterruptible kernel state, so the
# hold branch is asserted structurally; its CONSEQUENCE is exercised below.
for d in "$DRIVER" "$CODEX_DRIVER"; do
  n="$(basename "$d")"
  if grep -qE "^trap 'stop_child; (release_lock_or_hold|cleanup)' EXIT" "$d"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $n — the EXIT trap must stop the session before releasing the lock" >&2; fi
  if grep -qE "^trap 'stop_child; (release_lock_or_hold|cleanup); exit 131' QUIT" "$d"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $n — SIGQUIT must be handled like the other stop signals" >&2; fi
  if grep -qF 'STOP_GRACE="${LOOP_TESTING_STOP_GRACE:-20}"' "$d"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $n — the derived 20 s shutdown bound is gone (see the header for why it is 20)" >&2; fi
  if grep -qF 'echo "$CHILD_SURVIVED" > "$LOCK_DIR/pid"' "$d"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $n — a held lock must be rewritten to name the surviving session, or the next driver steals it" >&2; fi
  if grep -qE 'trap - INT QUIT;' "$d"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $n — the session must inherit default SIGINT *and* SIGQUIT, not the async list's ignore" >&2; fi
done

# The state a held lock leaves behind: the lock dir names a LIVE pid (there, the
# surviving session; here, a process this test owns). The next driver must
# refuse rather than steal it — which is what makes holding worth doing.
WSH=$(mk_proj); WS_ALL="$WS_ALL $WSH"
# Started inside a subshell so it is not a job of THIS shell: a job would print
# bash's own "Killed" notice into the test output when it is reaped.
SURV=$( ( sleep 30 >/dev/null 2>&1 & echo $! ) ); KILL_ON_EXIT="$KILL_ON_EXIT $SURV"
mkdir -p "$WSH/docs/looptesting/.driver.lock"
echo "$SURV" > "$WSH/docs/looptesting/.driver.lock/pid"
stubh=$(write_heartbeat_stub "$WSH"); write_state "$WSH" RUNNING 0
bash "$DRIVER" --project "$WSH" --claude-bin "$stubh" --max-sessions 1 > /dev/null 2>&1
assert_rc $? 2 "a lock naming a live surviving session refuses the next driver (exit 2)"
assert_eq "0" "$(sessions_in_log "$WSH")" "no second session starts while the held lock names a live process"
kill -KILL "$SURV" 2>/dev/null

report "shutdown.test.sh"
