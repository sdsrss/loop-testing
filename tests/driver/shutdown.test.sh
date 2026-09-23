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
# This suite drains stdin (pty work and backgrounded subshells that inherit it).
# A caller that feeds its own work list on stdin — tests/run-all.sh does exactly
# that — loses the rest of the list, so it stops early while still reporting
# green. The runner now also redirects, but a suite should not be a hazard to
# whoever runs it, so detach here too.
exec </dev/null
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# Without timeout/gtimeout the driver refuses to start (DR-7), so every case here
# would measure that refusal; skip the file whole via the run-all protocol.
require_watchdog_binary
CODEX_DRIVER="$REPO_ROOT/skills/loop-testing/scripts/unattended-codex.sh"

WS_ALL=()
track_ws() { WS_ALL+=("$1"); }
# This suite's own process group. `script -q -c "… --claude-bin <stub>"`, the
# pty launcher, stays in OUR group (only its child gets a new session), and its
# command line names the stub — so every "pgrep -f <stub>, then SIGKILL that
# group" sweep below killed the suite itself whenever a pty-case driver was
# still up. Measured: LOOP_TESTING_TEST_WAIT=0 ended rc 137 after the report,
# before `rm -rf`, leaving 30 fixture dirs, 20 session-err files and 14
# drivers running. Under
# run-all, which runs suites without job control, that group is the runner's.
SELF_PG=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
case "$SELF_PG" in
  ''|*[!0-9]*) echo "FAILED: cannot read this suite's own process group — every cleanup below would risk killing it" >&2; exit 1 ;;
esac
# kill_group_of <pid>: SIGKILL the process group <pid> is in, unless that group
# is this suite's own — then only <pid> itself.
kill_group_of() {
  local pg; pg=$(ps -o pgid= -p "$1" 2>/dev/null | tr -d ' ')
  case "$pg" in
    ''|0|1|"$SELF_PG") ;;
    *) kill -KILL -- -"$pg" 2>/dev/null ;;
  esac
  kill -KILL "$1" 2>/dev/null
}
KILL_ON_EXIT=""
cleanup_all() {
  # Kill anything still beating in a fixture before removing it.
  #
  # The count guard is not decoration and the quotes are not style (review
  # T-1 / P-03). WS_ALL became an array in 2371122 and this consumer was left
  # reading it bare, which expands to element 0 ALONE — so the sweep covered the
  # first of ~30 fixtures and said nothing. It is also `set -u`-fatal when the
  # array is empty, and an error here aborts the whole EXIT trap, taking the
  # `rm -rf` below with it. Measured on the verbatim body over three fixtures
  # each holding a live stub: bare form leaves 2 alive, quoted form leaves 0.
  if [ "${#WS_ALL[@]}" -gt 0 ]; then
    for ws in "${WS_ALL[@]}"; do
      for p in $(pgrep -f "$ws/heartbeat-stub.sh" 2>/dev/null) $(pgrep -f "$ws/stubborn-stub.sh" 2>/dev/null); do
        kill_group_of "$p"
      done
    done
  fi
  for p in $KILL_ON_EXIT; do kill -KILL "$p" 2>/dev/null; done
  if [ "${#WS_ALL[@]}" -gt 0 ]; then rm -rf -- "${WS_ALL[@]}"; fi
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

# wait_lock_pid comes from lib.sh. It used to be redefined here, nine lines
# below the `. lib.sh` that provides it, and the later definition won — so this
# suite quietly kept the pre-T-08 version and two repairs from that round were
# void in the one place they mattered most (review T-4, delta review):
#   * LOOP_TESTING_TEST_WAIT is documented as the way to survive a slow host,
#     and the heaviest suite in the tree — real drivers, pty sessions, 154
#     assertions — never consulted it;
#   * the local copy had no `0` arm on the pid, and this is the only suite that
#     feeds that pid to `ps -o pgid=` and `kill -KILL -- -"$pg"`.
# Deleting it was enough: same signature, same stdout contract, and `$( )`
# strips the newline `echo` added, so all three call sites are unchanged. The
# budget goes 15s -> 30s, i.e. only more patient.
#
# `wait_heartbeat` below has no twin in lib.sh and keeps its own loop.

wait_heartbeat() { # ws -> 0 once the stub has beaten at least 3 times, 1 past the budget
  local end; end=$(( $(date +%s) + $(test_wait_budget) ))
  until [ "$(hb_lines "$1")" -ge 3 ]; do
    [ "$(date +%s)" -lt "$end" ] || return 1
    sleep 0.25
  done
  return 0
}

# After a signal, every wait in a case shares ONE deadline. Waiting on each in
# turn stacked 30 + 30 s, which reaches the session's own watchdog
# (--session-minutes 1 = 60 s): a driver that IGNORED the signal then had its
# session killed by the watchdog instead, and "child session kept running" /
# "orphaned session processes" passed on that kill. The shared deadline is the
# budget, capped at two thirds of the session watchdog. The cap counts from
# the signal while the watchdog counts from session launch, so it holds that
# margin only when the wait before the signal (lock pid, 3 heartbeats) is
# short — normally well under a second; a slow start narrows it.
post_budget() { # session-watchdog-seconds -> seconds
  local b cap; b=$(test_wait_budget); cap=$(( $1 * 2 / 3 ))
  [ "$b" -le "$cap" ] && echo "$b" || echo "$cap"
}

# watch_lock_release <lock> <session-pid> <deadline-epoch> -> sets saw=1 once
# the lock is gone, raced=1 if the session was still alive at that instant.
# The lock is tested every pass, the clock only every tenth: the race it looks
# for lasts ~50 ms, and a `date` fork per pass stretched the period ~10 %.
watch_lock_release() {
  local i=0; saw=0; raced=0
  while :; do
    if [ ! -e "$1" ]; then saw=1; kill -0 "$2" 2>/dev/null && raced=1; return 0; fi
    i=$((i + 1))
    if [ $((i % 10)) -eq 0 ] || [ "$i" -eq 1 ]; then [ "$(date +%s)" -lt "$3" ] || return 0; fi
    sleep 0.05
  done
}

# gone_by <pid> <deadline-epoch> -> 0 once the pid is gone, 1 at the deadline.
gone_by() {
  while kill -0 "$1" 2>/dev/null; do
    [ "$(date +%s)" -lt "$2" ] || return 1
    sleep 0.25
  done
  return 0
}

# Premise failures say so. A case that never reached the state it is about
# (no lock pid, no heartbeat, no session group) is not evidence about the
# driver in either direction, and must not read like a verdict on it.
premise_msg() { # label what
  echo "  FAIL: $1 — $2 within $(test_wait_budget)s; this run never reached the state the case is about, so it is not evidence about shutdown either way (audit T-08)" >&2
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
  local ws stub drv sess pgid n1 n2 lock pb pend
  ws=$(mk_proj); track_ws "$ws"
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
      # `script -c` takes ONE string that a shell re-splits, so the argv has to
      # be re-quoted rather than joined: `"$*"` glues the arguments with spaces
      # and a $TMPDIR containing one turned `--project /tmp/sp ace/ws1` into two
      # arguments. The driver then got a --project that does not exist, never
      # wrote a lock pid, and the case reported "driver never wrote its lock
      # pid" — the harness blaming the driver for the harness, which is the
      # shape T-08 is about. The non-pty arm below passes argv straight through
      # and was always correct, which is why only this arm failed.
      # SHELL is pinned to the bash running this suite (delta review T-E).
      # `script -c` hands its string to $SHELL, and `printf '%q '` emits bash's
      # $'…' ANSI-C quoting for control characters, which dash does not parse —
      # measured: a $TMPDIR containing a TAB round-trips correctly under bash
      # and arrives corrupt under /bin/sh or with SHELL unset. Space, quote and
      # leading-dash survive either way, so this widens the fix rather than
      # being the fix.
      # The `${BASH:-…}` fallback is near-unreachable by measurement: bash sets
      # $BASH in every invocation tried, including `env -i /bin/bash` and
      # --posix; only an explicit `unset BASH`, which nothing here does, clears
      # it. The literal is a belt-and-braces default, not a supported path —
      # and if it ever DID fire into a bash 3.2 consumer, whether 3.2 parses
      # bash 5's `%q` output is REASONED, not measured: `$'…'` predates bash
      # 3.2 and is not a bash-4 construct, but no 3.x was available to run it
      # on. Three things must stack for it to bite — `unset BASH`, a 3.2
      # consumer, and a control character in $TMPDIR — so it is noted, not
      # guarded.
      ptycmd=$(printf '%q ' "$@")
      ( ( trap - INT QUIT; exec env SHELL="${BASH:-/bin/bash}" script -q -c "$ptycmd" /dev/null < "$ws/tty-in" > "$ws/driver.err" 2>&1 ) & )
      ;;
    *)
      ( ( trap - INT QUIT; exec setsid "$@" > /dev/null 2> "$ws/driver.err" ) & )
      ;;
  esac
  drv=$(wait_lock_pid "$ws") || { FAIL=$((FAIL+1)); echo "  FAIL: $label — no lock pid appeared within $(test_wait_budget)s; this run never reached the state the case is about, so it is not evidence about shutdown either way (audit T-08)" >&2; [ "$method" = pty ] && exec 3>&-; return 0; }
  wait_heartbeat "$ws" || { FAIL=$((FAIL+1)); premise_msg "$label" "the session produced no 3 heartbeats"; [ "$method" = pty ] && exec 3>&-; return 0; }
  sess=$(session_pid "$drv") || { FAIL=$((FAIL+1)); premise_msg "$label" "no session process group appeared under the driver"; [ "$method" = pty ] && exec 3>&-; return 0; }
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
  pb=$(post_budget 60); pend=$(( $(date +%s) + pb ))
  watch_lock_release "$lock" "$sess" "$pend"
  if [ "$saw" = 1 ] && [ "$raced" = 0 ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1))
    if [ "$saw" = 0 ]; then echo "  FAIL: $label — .driver.lock was not released within ${pb}s of the signal" >&2
    else echo "  FAIL: $label — lock released while session pid $sess was still alive" >&2; fi
  fi

  # The driver itself must go (this half always passed).
  gone_by "$drv" "$pend" || :
  if kill -0 "$drv" 2>/dev/null; then
    FAIL=$((FAIL+1)); echo "  FAIL: $label — driver still alive ${pb}s after the signal" >&2
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
    for p in $(pgrep -f "$stub"); do kill_group_of "$p"; done
  else PASS=$((PASS+1)); fi
  # The wait must announce itself: a silent pause of up to the bound reads as a
  # hang, and the user's next move is a second signal.
  if grep -qF "stopping session pid $sess" "$ws/driver.err" 2>/dev/null; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $label — the driver never said it was stopping session pid $sess" >&2; fi
  [ "$method" = pty ] && exec 3>&-
  return 0
}

# A SECOND signal during the wait must not cancel it. The first handler owns the
# sequence; the nested one only collapses the deadline. The stub ignores SIGTERM
# so the wait is real, and the bound is left at its 20 s default so the window
# is as wide as a user would meet it.
# run_double <label> <kind: claude|codex> <first> <second>   signals: TERM INT HUP QUIT pty
run_double() {
  local label="$1" kind="$2" first="$3" second="$4"
  local ws stub drv sess lock pgid saw raced t0 tdead pb pend
  ws=$(mk_proj); track_ws "$ws"
  stub=$(write_stubborn_stub "$ws")
  write_state "$ws" RUNNING 0
  lock="$ws/docs/looptesting/.driver.lock"
  if [ "$kind" = codex ]; then
    set -- bash "$CODEX_DRIVER" --project "$ws" --codex-bin "$stub" --no-protect --max-sessions 3 --max-minutes 5 --session-minutes 2
  else
    set -- bash "$DRIVER" --project "$ws" --claude-bin "$stub" --max-sessions 3 --max-minutes 5 --session-minutes 2
  fi
  if [ "$first" = pty ]; then
    mkfifo "$ws/tty-in"; exec 3<>"$ws/tty-in"
    # Second copy of the pty launch, and it needed the same re-quoting as the
    # one in run_case — fixing only that one left these two cases failing under
    # a $TMPDIR with a space, which is how a sibling path announces itself here.
    # SHELL pinned for the same reason as the run_case arm (T-E).
    ptycmd=$(printf '%q ' "$@")
    ( ( trap - INT QUIT; exec env SHELL="${BASH:-/bin/bash}" script -q -c "$ptycmd" /dev/null < "$ws/tty-in" > "$ws/driver.err" 2>&1 ) & )
  else
    ( ( trap - INT QUIT; exec setsid "$@" > /dev/null 2> "$ws/driver.err" ) & )
  fi
  drv=$(wait_lock_pid "$ws") || { FAIL=$((FAIL+1)); echo "  FAIL: $label — no lock pid appeared within $(test_wait_budget)s; this run never reached the state the case is about, so it is not evidence about shutdown either way (audit T-08)" >&2; [ "$first" = pty ] && exec 3>&-; return 0; }
  wait_heartbeat "$ws" || { FAIL=$((FAIL+1)); premise_msg "$label" "the session produced no 3 heartbeats"; [ "$first" = pty ] && exec 3>&-; return 0; }
  sess=$(session_pid "$drv") || { FAIL=$((FAIL+1)); premise_msg "$label" "no session process group appeared under the driver"; [ "$first" = pty ] && exec 3>&-; return 0; }
  pgid=$(ps -o pgid= -p "$drv" | tr -d ' ')
  send_sig "$first" "$drv" "$pgid"
  sleep 2   # the first handler is now inside its wait
  # Mid-wait: the driver is holding the line. If any of this is already false the
  # wait is not happening and the second-signal case below would prove nothing.
  if kill -0 "$drv" 2>/dev/null && kill -0 "$sess" 2>/dev/null && [ -e "$lock" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $label — mid-wait state wrong (driver $(kill -0 "$drv" 2>/dev/null && echo alive || echo dead), session $(kill -0 "$sess" 2>/dev/null && echo alive || echo dead), lock $([ -e "$lock" ] && echo present || echo absent))" >&2; fi
  t0=$(date +%s)
  send_sig "$second" "$drv" "$pgid"
  # THE invariant: the lock may never be absent while the session lives.
  pb=$(post_budget 120); pend=$(( t0 + pb ))
  watch_lock_release "$lock" "$sess" "$pend"
  if [ "$saw" = 1 ] && [ "$raced" = 0 ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1))
    if [ "$saw" = 0 ]; then echo "  FAIL: $label — .driver.lock was not released within ${pb}s of the second signal" >&2
    else echo "  FAIL: $label — second signal released the lock with session pid $sess still alive" >&2; fi
  fi
  # And the second signal is USEFUL: it collapses the deadline, so the session
  # dies now rather than at the 20 s bound.
  gone_by "$sess" "$pend" || :
  tdead=$(( $(date +%s) - t0 ))
  if kill -0 "$sess" 2>/dev/null; then
    FAIL=$((FAIL+1)); echo "  FAIL: $label — session still alive ${tdead}s after the second signal" >&2
  elif [ "$tdead" -le 10 ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $label — second signal did not escalate (session took ${tdead}s to die)" >&2; fi
  gone_by "$drv" "$pend" || :
  if kill -0 "$drv" 2>/dev/null; then
    FAIL=$((FAIL+1)); echo "  FAIL: $label — driver still alive ${pb}s after the second signal" >&2; kill -KILL "$drv" 2>/dev/null
  else PASS=$((PASS+1)); fi
  if pgrep -f "$stub" > /dev/null 2>&1; then
    FAIL=$((FAIL+1)); echo "  FAIL: $label — orphaned session processes: $(pgrep -f "$stub" | tr '\n' ' ')" >&2
    for p in $(pgrep -f "$stub"); do kill_group_of "$p"; done
  else PASS=$((PASS+1)); fi
  if grep -qF "second stop signal" "$ws/driver.err" 2>/dev/null; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $label — the second signal was not acknowledged on stderr" >&2; fi
  [ "$first" = pty ] && exec 3>&-
  return 0
}

# run_broken_ps <label> <kind> <ps-behavior>
# The wait decides whether the session is still alive by pairing `kill -0` with
# the pid's start time from `ps`. If a failing `ps` is read as "the process is
# gone", the driver releases the lock on top of a live full-permission session —
# the guarantee inverted by the very tool used to check it. A session that can
# exhaust forks can make `ps` fail INTERMITTENTLY, so each behavior below is
# applied while the real PATH is otherwise intact.
run_broken_ps() {
  local label="$1" kind="$2" behavior="$3"
  local ws stub drv sess lock pgid shim saw raced pb pend
  ws=$(mk_proj); track_ws "$ws"
  stub=$(write_stubborn_stub "$ws")
  write_state "$ws" RUNNING 0
  lock="$ws/docs/looptesting/.driver.lock"
  shim="$ws/shim"; mkdir -p "$shim"
  # The hazard is an INTERMITTENT ps, not an absent one: a ps that fails from the
  # start leaves CHILD_START empty and the pid-only fallback engages, which is
  # safe. So this shim passes everything through until the test drops a sentinel
  # (just before the stop signal), and after that fails ONLY the start-time query
  # the wait loop depends on — the process-group query still works, so what is
  # being measured is the liveness verdict and nothing else.
  case "$behavior" in
    rc127)   PS_FAIL='exit 127' ;;
    rc1)     PS_FAIL='exit 1' ;;
    garbage) PS_FAIL='echo "not a date at all"; exit 0' ;;
    normal)  PS_FAIL=':' ;;
  esac
  cat > "$shim/ps" <<PSSHIM
#!/usr/bin/env bash
if [ -e "$ws/ps-broken" ]; then
  for a in "\$@"; do
    case "\$a" in lstart*) $PS_FAIL ;; esac
  done
fi
exec $(command -v ps) "\$@"
PSSHIM
  chmod +x "$shim/ps"
  if [ "$kind" = codex ]; then
    set -- env PATH="$shim:$PATH" LOOP_TESTING_STOP_GRACE=3 bash "$CODEX_DRIVER" --project "$ws" --codex-bin "$stub" --no-protect --max-sessions 3 --max-minutes 5 --session-minutes 2
  else
    set -- env PATH="$shim:$PATH" LOOP_TESTING_STOP_GRACE=3 bash "$DRIVER" --project "$ws" --claude-bin "$stub" --max-sessions 3 --max-minutes 5 --session-minutes 2
  fi
  ( ( trap - INT QUIT; exec setsid "$@" > /dev/null 2> "$ws/driver.err" ) & )
  drv=$(wait_lock_pid "$ws") || { FAIL=$((FAIL+1)); echo "  FAIL: $label — no lock pid appeared within $(test_wait_budget)s; this run never reached the state the case is about, so it is not evidence about shutdown either way (audit T-08)" >&2; return 0; }
  wait_heartbeat "$ws" || { FAIL=$((FAIL+1)); premise_msg "$label" "the session produced no 3 heartbeats"; return 0; }
  # The test's own view of the process table is never shimmed.
  sess=$(session_pid "$drv") || { FAIL=$((FAIL+1)); premise_msg "$label" "no session process group appeared under the driver"; return 0; }
  pgid=$(ps -o pgid= -p "$drv" | tr -d ' ')
  : > "$ws/ps-broken"          # ps starts failing exactly as the wait begins
  kill -TERM -- -"$pgid" 2>/dev/null
  pb=$(post_budget 120); pend=$(( $(date +%s) + pb ))
  watch_lock_release "$lock" "$sess" "$pend"
  if [ "$behavior" = garbage ]; then
    # A ps that answers in a DIFFERENT FORMAT is not "cannot tell" — it is a
    # non-empty start time that does not match, which is exactly what a REUSED
    # pid looks like. The rule is deliberate and asymmetric: a mismatch reads as
    # "this pid is no longer our session", and nothing further is signalled,
    # because SIGKILLing a process group under a pid that now belongs to someone
    # else is the worse failure. So the guarantee to pin here is that the driver
    # kills NOTHING under that pid — the session is still standing afterwards.
    if [ "$saw" = 1 ] && kill -0 "$sess" 2>/dev/null; then PASS=$((PASS+1)); else
      FAIL=$((FAIL+1)); echo "  FAIL: $label — a start-time MISMATCH must be read as 'not our session' and signalled no further (pid reuse), but the session was killed" >&2
    fi
  else
    if [ "$saw" = 1 ] && [ "$raced" = 0 ]; then PASS=$((PASS+1)); else
      FAIL=$((FAIL+1))
      if [ "$saw" = 0 ]; then echo "  FAIL: $label — .driver.lock was not released within ${pb}s of the signal" >&2
      else echo "  FAIL: $label — a broken ps made the driver release the lock with session pid $sess still alive" >&2; fi
    fi
  fi
  gone_by "$drv" "$pend" || :
  kill -KILL "$drv" 2>/dev/null
  if [ "$behavior" = garbage ]; then
    # The session this case deliberately leaves standing is the fixture's, so
    # reap it here rather than reporting it as an orphan.
    for p in $(pgrep -f "$stub" 2>/dev/null); do
      kill_group_of "$p"
    done
    PASS=$((PASS+1))
  elif pgrep -f "$stub" > /dev/null 2>&1; then
    FAIL=$((FAIL+1)); echo "  FAIL: $label — orphaned session processes: $(pgrep -f "$stub" | tr '\n' ' ')" >&2
    for p in $(pgrep -f "$stub"); do kill_group_of "$p"; done
  else PASS=$((PASS+1)); fi
  return 0
}

send_sig() { # signal driver-pid driver-pgid
  case "$1" in
    TERM) kill -TERM -- -"$3" 2>/dev/null ;;
    INT)  kill -INT  -- -"$3" 2>/dev/null ;;
    HUP)  kill -HUP  -- -"$3" 2>/dev/null ;;
    QUIT) kill -QUIT -- -"$3" 2>/dev/null ;;
    pty)  printf '\003' >&3 ;;
  esac
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

# A second signal mid-wait: the impatient user, and the reason the wait has to
# announce itself. Every ordering, both drivers.
for k in claude codex; do
  run_double "$k driver, SIGTERM then SIGTERM"  "$k" TERM TERM
  run_double "$k driver, SIGTERM then SIGINT"   "$k" TERM INT
  run_double "$k driver, SIGTERM then SIGHUP"   "$k" TERM HUP
  run_double "$k driver, SIGTERM then SIGQUIT"  "$k" TERM QUIT
  if command -v script > /dev/null 2>&1 && script -q -c true /dev/null > /dev/null 2>&1; then
    run_double "$k driver, two Ctrl-C on a pty" "$k" pty pty
  fi
done

# A bare `kill -TERM <driver-pid>` — no process group — must be honored WHILE a
# session runs, not deferred to the session boundary (bash only defers a trap
# for a foreground child; `wait` is interruptible), and the exit status must be
# the conventional 128+n so a supervisor can tell "stopped by the operator" from
# "loop ended" (0) or "limits" (3-5). The elapsed bound is what discriminates:
# the old driver also exited 143 — after the 60 s watchdog had ended the session
# for it — so a heartbeat check here would pass on the unfixed driver too.
WS=$(mk_proj); track_ws "$WS"
stub=$(write_heartbeat_stub "$WS"); write_state "$WS" RUNNING 0
# The signaller records that it SENT the signal. Without that, a run where the
# lock pid never appeared sent nothing, the driver ran on to its limits, and the
# two assertions below read that as "the driver ignored a bare TERM" — a verdict
# on the driver from a case that never reached its state (the T-08 shape).
# The marker holds WHEN the signal went out: the elapsed bound is about the
# driver's response, so the signaller's own waiting must not count against it.
( pid=$(wait_lock_pid "$WS") && wait_heartbeat "$WS" && kill -TERM "$pid" 2>/dev/null \
    && date +%s > "$WS/term-sent" ) &
bash "$DRIVER" --project "$WS" --claude-bin "$stub" --max-sessions 3 --max-minutes 5 --session-minutes 1 > /dev/null 2>&1
rc=$?
tend=$(date +%s)
wait 2>/dev/null
if [ -s "$WS/term-sent" ]; then
  read -r tsent < "$WS/term-sent"; elapsed=$(( tend - tsent ))
  assert_rc "$rc" 143 "a bare kill -TERM <driver-pid> during a session exits 143"
  if [ "$elapsed" -lt 20 ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: bare kill -TERM was deferred to the session boundary (driver ran ${elapsed}s after the TERM)" >&2; fi
else
  # Two failures, as on the reached path two assertions: a constant count.
  FAIL=$((FAIL+1)); premise_msg "bare kill -TERM" "the signaller saw no lock pid and 3 heartbeats, so it sent no TERM,"
  FAIL=$((FAIL+1)); echo "  FAIL: bare kill -TERM — the deferral bound is unevaluated for the same reason" >&2
fi

# A `ps` that cannot answer must never be read as "the session is gone".
for k in claude codex; do
  run_broken_ps "$k driver, ps exits 127 (absent-like)" "$k" rc127
  run_broken_ps "$k driver, ps exits 1"                 "$k" rc1
  run_broken_ps "$k driver, ps prints another format"   "$k" garbage
  run_broken_ps "$k driver, ps normal (control)"        "$k" normal
done

# ── the two branches a test cannot stage ──────────────────────────────────────
# A process that outlives SIGKILL needs an uninterruptible kernel state, so the
# hold branch is asserted structurally; its CONSEQUENCE is exercised below.
for d in "$DRIVER" "$CODEX_DRIVER"; do
  n="$(basename "$d")"
  if grep -qE "^trap 'shutdown_handler' EXIT" "$d"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $n — the EXIT trap must stop the session before releasing the lock" >&2; fi
  if grep -qE "^trap 'shutdown_handler 131' QUIT" "$d"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $n — SIGQUIT must be handled like the other stop signals" >&2; fi
  # Re-entrancy and idempotency must be separate flags: one variable doing both
  # is what let a second signal return early and release the lock mid-wait.
  if grep -qF 'if [ "$STOPPING" = 1 ]; then' "$d" && grep -qF 'STOP_DEADLINE=0' "$d"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $n — a second stop signal must collapse the deadline, not cancel the wait" >&2; fi
  if grep -qF 'CHILD_START="$(proc_start "$CHILD")"' "$d"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $n — the session must be identified by pid AND start time before it is SIGKILLed" >&2; fi
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
WSH=$(mk_proj); track_ws "$WSH"
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
