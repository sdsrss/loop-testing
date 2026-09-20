#!/usr/bin/env bash
# Shutdown must stop the CHILD SESSION, not just the driver (audit D-01).
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
# Fixture: the "agent" is a heartbeat stub that appends a line every 200 ms
# forever. After the shutdown signal the assertion is on the heartbeat file:
# it must stop growing. Three delivery paths per driver — SIGTERM to the
# process group (the README's documented command), SIGHUP to the process group
# (a closed terminal / lost SSH session), and, when util-linux `script` can
# hand us a pty, a real Ctrl-C.
#
# SAFETY: mktemp project, stub binary, --no-protect on the codex side so the
# real ~/.codex is never touched. Every survivor is killed on exit.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
CODEX_DRIVER="$REPO_ROOT/skills/loop-testing/scripts/unattended-codex.sh"

WS_ALL=""
cleanup_all() {
  # Kill anything still beating in a fixture before removing it.
  for ws in $WS_ALL; do
    for p in $(pgrep -f "$ws/heartbeat-stub.sh" 2>/dev/null); do
      pg=$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')
      [ -n "$pg" ] && kill -KILL -- -"$pg" 2>/dev/null
      kill -KILL "$p" 2>/dev/null
    done
  done
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

# run_case <label> <kind: claude|codex> <method: term|hup|pty>
run_case() {
  local label="$1" kind="$2" method="$3" ws stub drv pgid pid n1 n2
  ws=$(mk_proj); WS_ALL="$WS_ALL $ws"
  stub=$(write_heartbeat_stub "$ws")
  write_state "$ws" RUNNING 0
  if [ "$kind" = codex ]; then
    set -- bash "$CODEX_DRIVER" --project "$ws" --codex-bin "$stub" --no-protect --max-sessions 3 --max-minutes 5 --session-minutes 1
  else
    set -- bash "$DRIVER" --project "$ws" --claude-bin "$stub" --max-sessions 3 --max-minutes 5 --session-minutes 1
  fi
  # Every launch is an async list of a non-interactive shell, which hands it
  # SIGINT ignored — and an ignored-on-entry SIGINT can never be trapped by the
  # driver, so a ^C would test nothing. `trap - INT` as the FIRST statement of
  # the async subshell (not of a wrapper around it: each `&` re-ignores) gives
  # the driver what a user's terminal would. The outer `( )` keeps bash's
  # "Hangup" job notice out of the test output.
  case "$method" in
    pty)
      # A real terminal: `script` allocates a pty, the driver is its foreground
      # job, and a ^C byte written to the pty's input becomes SIGINT to that
      # foreground process group — the same path as a user's Ctrl-C.
      mkfifo "$ws/tty-in"
      exec 3<>"$ws/tty-in"
      ( ( trap - INT; exec script -q -c "$*" /dev/null < "$ws/tty-in" > /dev/null 2>&1 ) & )
      ;;
    *)
      ( ( trap - INT; exec setsid "$@" > /dev/null 2>&1 ) & )
      ;;
  esac
  drv=$(wait_lock_pid "$ws") || { FAIL=$((FAIL+1)); echo "  FAIL: $label — driver never wrote its lock pid" >&2; [ "$method" = pty ] && exec 3>&-; return; }
  wait_heartbeat "$ws" || { FAIL=$((FAIL+1)); echo "  FAIL: $label — child session never started beating" >&2; [ "$method" = pty ] && exec 3>&-; return; }
  case "$method" in
    term) pgid=$(ps -o pgid= -p "$drv" | tr -d ' '); kill -TERM -- -"$pgid" 2>/dev/null ;;
    hup)  pgid=$(ps -o pgid= -p "$drv" | tr -d ' '); kill -HUP  -- -"$pgid" 2>/dev/null ;;
    pty)  printf '\003' >&3 ;;
  esac
  # The driver itself must go (this half always passed).
  for _ in $(seq 1 40); do kill -0 "$drv" 2>/dev/null || break; sleep 0.25; done
  if kill -0 "$drv" 2>/dev/null; then
    FAIL=$((FAIL+1)); echo "  FAIL: $label — driver still alive after the signal" >&2
    kill -KILL "$drv" 2>/dev/null
  else PASS=$((PASS+1)); fi
  # The lock must be released (this half always passed too).
  if [ -e "$ws/docs/looptesting/.driver.lock" ]; then
    FAIL=$((FAIL+1)); echo "  FAIL: $label — .driver.lock left behind" >&2
  else PASS=$((PASS+1)); fi
  # THE assertion: the child session stops. Give SIGTERM propagation a moment,
  # then sample the heartbeat twice a second apart — any growth means the
  # session outlived its driver.
  sleep 1
  n1=$(hb_lines "$ws"); sleep 1; n2=$(hb_lines "$ws")
  if [ "$n1" -eq "$n2" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $label — child session kept running after the driver died (heartbeat $n1 -> $n2)" >&2
  fi
  # And nothing from this fixture is left in the process table.
  if pgrep -f "$stub" > /dev/null 2>&1; then
    FAIL=$((FAIL+1)); echo "  FAIL: $label — orphaned session processes: $(pgrep -f "$stub" | tr '\n' ' ')" >&2
    for pid in $(pgrep -f "$stub"); do pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' '); [ -n "$pgid" ] && kill -KILL -- -"$pgid" 2>/dev/null; done
  else PASS=$((PASS+1)); fi
  [ "$method" = pty ] && exec 3>&-
  return 0
}

if ! command -v setsid > /dev/null 2>&1; then
  echo "  skip: setsid unavailable — shutdown tests need a fresh process group"
  report "shutdown.test.sh"; exit $?
fi

run_case "claude driver, SIGTERM to the process group" claude term
run_case "claude driver, SIGHUP to the process group"  claude hup
run_case "codex driver, SIGTERM to the process group"  codex  term
run_case "codex driver, SIGHUP to the process group"   codex  hup

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
# "loop ended" (0) or "limits" (3-5). The session budget is 60 s, so the
# elapsed-time bound is what makes this case discriminating: the old driver
# also exited 143 — after the watchdog had ended the session for it.
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
sleep 1; n1=$(hb_lines "$WS"); sleep 1; n2=$(hb_lines "$WS")
assert_eq "$n1" "$n2" "a bare kill -TERM <driver-pid> also stops the child session"

report "shutdown.test.sh"
