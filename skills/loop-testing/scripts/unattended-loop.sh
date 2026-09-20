#!/usr/bin/env bash
# unattended-loop.sh — outer resume-driver for the loop-testing QA loop.
#
# WHY THIS EXISTS (F4): under `claude -p` (non-interactive/headless), a single
# session can end before the QA loop converges — most notably when the model
# delegates the loop to a sub-agent, which the print-mode background-wait ceiling
# (CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS, default 600000ms) then terminates. This
# driver makes headless runs robust: it repeatedly launches `claude -p` to RESUME
# the loop from docs/looptesting/STATE.md (the skill's own resume protocol) until
# STATE reports a terminal status, and it fail-closes on stuck loops / limits.
#
# It is NOT needed for interactive `claude` or Codex; those keep one session
# alive. See README "Known limitations / F4".
#
# Usage:
#   unattended-loop.sh --project <dir> [--max-sessions 15] [--max-minutes 240]
#                      [--plugin-dir <path>] [--max-turns 300] [--claude-bin claude]
#                      [--session-minutes 50] [--no-watchdog]
#
# Shutdown: SIGINT (Ctrl-C), SIGTERM, SIGHUP or SIGQUIT to the driver — bare pid
# or process group — stops the driver AND the running session, and the driver
# does not release .driver.lock until the session is gone. The session is
# launched in the background and awaited with `wait`, which a trapped signal
# interrupts immediately; the handler then signals the session's own process
# group and WAITS for it. That group is distinct from the driver's: `timeout`
# (GNU and uutils) calls setpgid(0,0), so `kill -TERM -- -<driver-pgid>` alone
# killed the driver, freed the lock, and left a bypassPermissions session
# running for a later driver to race (audit D-01).
#
# Why the wait is bounded at 20 s (derived — please do not "tune" it): the
# session runs under `timeout -k 15`, which already guarantees SIGKILL 15 s
# after the SIGTERM the handler sends. Past ~16 s the watchdog has failed or
# something has left the group, so the bound is that guarantee plus margin for
# a loaded machine. At the bound the handler sends one SIGKILL to the session's
# group, re-polls for 2 s, and then decides on the SESSION pid alone:
#   - session gone  -> release the lock; any straggler is a grandchild that
#     ignored SIGTERM or escaped via setsid. It cannot advance STATE.md as the
#     session, so it is named in driver.log rather than blocking the project.
#   - session alive (kernel-uninterruptible) -> KEEP the lock, rewrite its pid
#     file to name the surviving session, and exit non-zero. A loud stale lock
#     refuses the next driver by design; a released one would silently permit a
#     second full-permission session on the same STATE.md.
#
# A SECOND stop signal during that wait does not cancel it — it collapses the
# deadline, so the SIGKILL escalation happens at once. The wait announces itself
# on stderr with the session pid and the bound, because a silent pause after a
# Ctrl-C reads as a hang and invites exactly that second press.
#
# Known limits (all pre-existing, none closed here):
#   - SIGKILL to the DRIVER skips every handler: the session keeps running and
#     the lock stays behind naming a dead holder, which the next driver steals.
#     Use one of the signals above instead.
#   - A grandchild that calls setsid() leaves the session's process group and is
#     reachable by neither `timeout -k` nor the handler — and, because the
#     straggler search is `pgrep -g`, it is not named in driver.log either.
#   - `timeout -k` is not a group reaper on every build: measured here, uutils
#     0.8.0 signals only its direct child, so a TERM-ignoring grandchild in the
#     same group survives it (GNU's timeout does signal the group).
#
# Exit codes:
#   0  STATE reached a terminal status (CONVERGED / INCOMPLETE / BLOCKED) — the
#      loop ended on its own terms; the honest verdict is in STATE.md.
#   2  usage / argument error.
#   3  hit --max-sessions before terminal (driver-declared INCOMPLETE).
#   4  hit --max-minutes before terminal (driver-declared INCOMPLETE).
#   5  NO_PROGRESS: two consecutive sessions with no change in the composite
#      progress fingerprint (round | issues | converged_streak | runs count+bytes |
#      round-0 bootstrap bytes).
#   129 / 130 / 131 / 143  stopped by SIGHUP / SIGINT / SIGQUIT / SIGTERM; the
#      session was stopped first. The lock is released unless the session itself
#      outlived SIGKILL, which the message on stderr names.
set -u

PROJECT=""
MAX_SESSIONS=15
MAX_MINUTES=240
SESSION_MINUTES=50
MAX_TURNS=300
CLAUDE_BIN="claude"
PLUGIN_DIR=""
NO_WATCHDOG=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

die() { echo "unattended-loop: $*" >&2; exit 2; }
is_uint() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --project)         PROJECT="${2:-}"; shift; shift;;
    --max-sessions)    MAX_SESSIONS="${2:-}"; shift; shift;;
    --max-minutes)     MAX_MINUTES="${2:-}"; shift; shift;;
    --session-minutes) SESSION_MINUTES="${2:-}"; shift; shift;;
    --max-turns)       MAX_TURNS="${2:-}"; shift; shift;;
    --plugin-dir)      PLUGIN_DIR="${2:-}"; shift; shift;;
    --claude-bin)      CLAUDE_BIN="${2:-}"; shift; shift;;
    --no-watchdog)     NO_WATCHDOG=1; shift 1;;
    -h|--help)         awk 'NR>1{if(/^#/)print;else exit}' "$0"; exit 0;;
    *) die "unknown argument: $1";;
  esac
done

[ -n "$PROJECT" ] || die "--project <dir> is required"
[ -d "$PROJECT" ] || die "--project is not a directory: $PROJECT"
for v in MAX_SESSIONS MAX_MINUTES SESSION_MINUTES MAX_TURNS; do
  # Name the flag the user typed (--max-sessions), not the variable (MAX_SESSIONS).
  # `tr`, not ${v,,} + ${flag//_/-}: case-modification expansion is bash 4.0+ and a
  # FATAL bad substitution on stock macOS bash 3.2 — and this line runs on every
  # invocation, not just the error path (tests/portability/bash3.test.sh guards it).
  eval "val=\$$v"; flag=$(printf '%s' "$v" | tr 'A-Z_' 'a-z-')
  # shellcheck disable=SC2154  # val is assigned by the eval above
  is_uint "$val" || die "--$flag must be a non-negative integer, got: $val"
done
# Default plugin-dir = this plugin's repo root (scripts/ -> loop-testing/ -> skills/ -> root).
[ -n "$PLUGIN_DIR" ] || PLUGIN_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PROJECT="$(cd "$PROJECT" && pwd)"
LT="$PROJECT/docs/looptesting"
STATE="$LT/STATE.md"
ISSUES="$LT/ISSUES.md"
DRIVER_LOG="$LT/driver.log"

RESUME_PROMPT='使用 loop-testing 技能：读取 docs/looptesting/STATE.md，从断点继续执行自测循环（若 STATE 不存在则从第 0 轮开始）。若需从第 0 轮建沙箱：必须经 sandbox-setup.sh 用 worktree 模式隔离，禁止手动 git switch/checkout/branch 或以任何方式切换用户主工作树所在分支（改代码前先核验 docs/looptesting/.sandbox/ownership.env 存在且主树仍在原分支）。重要：在当前会话内联执行整个循环，禁止把循环委派给 sub-agent 或 Task 工具。本会话尽量多完成整轮（选场景→像真实用户使用→发现即立案/复现/分级→修复+回归→复验+轮末结算），每轮末更新 STATE.md 的机器判读字段。若已满足收敛判据或保险停止条件，按 references/exit-and-report.md 写入终态（CONVERGED/INCOMPLETE/BLOCKED）并停止。'

state_field() { # key -> value (trimmed) ; empty if absent/unparseable
  [ -f "$STATE" ] || return 0
  grep -aE "^$1:" "$STATE" 2>/dev/null | head -1 | sed "s/^$1:[[:space:]]*//" | tr -d '[:space:]'
}
round_of() { # first integer in `round:` (tolerates an annotation); -1 if none
  # Take the first integer RUN, don't strip every non-digit: `round: 3 of 12`
  # glued both numbers into 312 — a round that never existed, reported as fact
  # in driver.log and the summary line.
  local r; r=$(state_field round | sed -n 's/^[^0-9-]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p')
  [ -n "$r" ] && echo "$r" || echo -1
}
issue_count() {
  [ -f "$ISSUES" ] || { echo 0; return; }
  # grep -c always prints the count (0 on no match) but exits 1 then; swallow the
  # exit WITHOUT a second echo (|| echo 0 would double-print "0").
  grep -acE '^### ISSUE-' "$ISSUES" 2>/dev/null || true
}
runs_sig() { # "<file-count>:<total-bytes>" of runs/*.md — evidence-growth signal
  local d="$LT/runs" n b
  [ -d "$d" ] || { echo "0:0"; return; }
  n=$(find "$d" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
  # Byte total via wc on the PATHS (a stat, not a full content read — audit DR-8;
  # `cat | wc -c` re-read every evidence byte each session). Multi-file output
  # ends with a "total" line, single-file has none: take the last line's leading
  # number either way; empty (glob no-match) -> 0.
  b=$(wc -c "$d"/*.md 2>/dev/null | tail -1 | sed -n 's/^[[:space:]]*\([0-9][0-9]*\).*/\1/p')
  [ -n "$b" ] || b=0
  echo "$n:$b"
}
bootstrap_sig() { # bytes of round-0 artifacts (PLAN + FEATURE_MATRIX)
  # Round 0 fills PLAN.md + FEATURE_MATRIX.md BEFORE any runs/round-N.md exists, so
  # without this a round 0 that spans sessions on a large target fingerprints as
  # static (round/issues/streak/runs all 0) and false-trips NO_PROGRESS (audit PL-2).
  local b
  b=$(wc -c "$LT/PLAN.md" "$LT/FEATURE_MATRIX.md" 2>/dev/null | tail -1 | sed -n 's/^[[:space:]]*\([0-9][0-9]*\).*/\1/p')
  [ -n "$b" ] || b=0
  echo "$b"
}
progress_sig() { # composite fingerprint: round|issues|streak|runsN:runsB|bootstrapB
  local s
  s="$(state_field converged_streak)"; [ -n "$s" ] || s=-1
  printf '%s|%s|%s|%s|%s' "$(round_of)" "$(issue_count)" "$s" "$(runs_sig)" "$(bootstrap_sig)"
}

# Ownership handshake with sandbox-setup.sh (audit D-03; kept identical to
# unattended-codex.sh). The driver needs docs/looptesting for driver.log and the
# lock BEFORE the first session runs setup, so on a fresh project setup found the
# dir already present, recorded it as the user's, and --purge kept it forever —
# saying it held files that were already theirs. Setup treats the
# `.sandbox/created-dirs.env` breadcrumb as the authority on who made the dir
# and never overwrites one; the driver is the process that knows, so it writes
# the breadcrumb when it is the one that created the dir — and only then. A dir
# that was there before the driver stays the user's; an existing breadcrumb
# (an earlier lifecycle's answer) is left as written.
LT_EXISTED=1; [ -d "$LT" ] || LT_EXISTED=0
mkdir -p "$LT"
: >> "$DRIVER_LOG" || die "cannot write driver.log at $DRIVER_LOG"
if [ "$LT_EXISTED" = 0 ] && [ ! -f "$LT/.sandbox/created-dirs.env" ]; then
  mkdir -p "$LT/.sandbox" 2>/dev/null \
    && printf 'MADE_LOOPTESTING_DIR=1\n' > "$LT/.sandbox/created-dirs.env" 2>/dev/null
fi

# Concurrency guard: refuse to run a second driver on the same target — two drivers
# would race STATE.md / driver.log / ISSUES.md / the worktree and corrupt the
# progress fingerprint and ledger. Portable atomic lock via mkdir (no flock — it is
# absent on macOS). A crashed driver's lock (holder PID no longer alive) is stolen; a
# live holder is refused (audit DR-4). Kept identical to unattended-codex.sh.
LOCK_DIR="$LT/.driver.lock"
LOCK_OWNED=0
release_lock() { [ "$LOCK_OWNED" = 1 ] && rm -rf "$LOCK_DIR" 2>/dev/null; LOCK_OWNED=0; }
acquire_lock() {
  # LOCK_OWNED is set BEFORE the pid write, at both mkdir sites: a signal landing
  # between them now terminates (the handlers exit), and with the flag still unset
  # release_lock would skip its rm — leaving a pid-less lock dir that every later
  # run reads as a live holder and refuses, locking the project out until a human
  # deletes it by hand. The pid file is advisory; this flag authorises cleanup.
  if mkdir "$LOCK_DIR" 2>/dev/null; then LOCK_OWNED=1; echo "$$" > "$LOCK_DIR/pid"; return 0; fi
  local holder=""; [ -f "$LOCK_DIR/pid" ] && read -r holder < "$LOCK_DIR/pid" 2>/dev/null
  case "$holder" in ''|*[!0-9]*) holder="" ;; esac
  # Fail-closed: steal a present lock ONLY when its holder PID is readable AND
  # confirmed no longer alive (a crashed driver). An unreadable/empty holder is
  # treated as live and refused — never steal on ambiguity. (Two drivers starting in
  # the same sub-ms window could still both steal a genuinely-stale lock; this is a
  # best-effort accidental-double-launch guard, not a hard mutex — see README.)
  if [ -z "$holder" ] || kill -0 "$holder" 2>/dev/null; then
    die "another loop-testing driver is running on this project (lock held${holder:+ by pid $holder}); refusing to run concurrently — remove $LOCK_DIR by hand only if you are sure no driver is live"
  fi
  rm -rf "$LOCK_DIR" 2>/dev/null   # holder PID confirmed dead (crashed driver) — steal
  if mkdir "$LOCK_DIR" 2>/dev/null; then LOCK_OWNED=1; echo "$$" > "$LOCK_DIR/pid"; return 0; fi
  die "could not acquire driver lock at $LOCK_DIR"
}
# A bash trap handler RETURNS into the interrupted flow — `trap release_lock INT
# TERM` therefore only dropped the lock and let the loop keep launching sessions:
# the documented process-group shutdown never stopped anything, and the
# concurrency guard was silently void while the driver ran on. Clean up, then
# terminate with the conventional 128+n status (same shape as install-codex.sh).
# release_lock is idempotent (LOCK_OWNED=0), so the EXIT trap firing after these
# is a no-op.
#
# The session is stopped FIRST, and stop_child does not return until it is gone
# (audit D-01). It runs under `timeout`, which puts itself and the agent in a
# process group of its own (pgid == its pid), so a signal aimed at the driver —
# or at the driver's whole group — never reached it: the driver died, the lock
# was freed, and the session ran on. The child pid is known because the session
# is launched with `&` and awaited with `wait` (which a trapped signal
# interrupts at once, unlike a foreground child), so the handler can signal the
# session's group by that pid. Signalling only ASKS; the wait is what makes the
# lock's absence mean the session's absence. See the bound's derivation in the
# file header.
# LOOP_TESTING_STOP_GRACE overrides the derived 20 s bound. It exists so the
# tests can exercise the SIGKILL escalation in seconds instead of waiting out
# the real bound; a non-numeric value falls back to the default rather than
# disabling the wait.
STOP_GRACE="${LOOP_TESTING_STOP_GRACE:-20}"
case "$STOP_GRACE" in ''|*[!0-9]*) STOP_GRACE=20 ;; esac
STOP_KILL_GRACE=2
STOP_DEADLINE=0       # global so a SECOND signal can collapse it (see shutdown_handler)
STOPPING=0            # a shutdown is in progress (re-entrancy, not idempotency)
STOP_DONE=0           # a shutdown has completed (idempotency, not re-entrancy)
CHILD=""              # pid of the running session (the watchdog leads its group)
SESSION_ERR=""        # this session's stderr capture file (audit D-05)
CHILD_START=""        # its start time — a pid alone is not an identity
CHILD_SURVIVED=""     # set only when that pid outlives SIGKILL
POLL_STEP=auto
poll_sleep() {
  local rc
  if [ "$POLL_STEP" = auto ]; then
    sleep 0.2 2>/dev/null; rc=$?
    # Exit >= 128 means the sleep was INTERRUPTED by a second stop signal, not
    # that this platform rejects a fractional argument — only the latter should
    # downgrade the poll to whole seconds.
    if [ "$rc" -eq 0 ] || [ "$rc" -ge 128 ]; then POLL_STEP=0.2; else POLL_STEP=1; sleep 1; fi
    return 0
  fi
  sleep "$POLL_STEP" 2>/dev/null || true
}
# The kernel reuses pids. Across a 20 s wait the session's number could come
# back as an unrelated process, and this code signals a whole process GROUP at
# the bound — so pair the pid with its start time and read a mismatch as "the
# session is gone", never as "something to kill".
proc_start() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' ' '; }
child_alive() { # pid start-time
  local st
  kill -0 "$1" 2>/dev/null || return 1
  [ -n "$2" ] || return 0            # no start time recorded: pid-only, as before
  # "Cannot tell" is NOT "mismatch". An empty answer means `ps` failed — and a
  # full-permission agent session can exhaust forks and make it fail
  # intermittently — so fall back to what kill -0 just proved rather than
  # reporting a live session as gone and releasing the lock on top of it. A
  # REUSED pid still yields a different non-empty start, so the guard below
  # keeps working.
  st="$(proc_start "$1")"
  [ -n "$st" ] || return 0
  # A non-empty start time that does NOT match means this pid is no longer the
  # process we launched. The session is then treated as gone and nothing further
  # is signalled — the realistic cause is pid reuse, and SIGKILLing a process
  # group under a pid that now belongs to someone else is the worse failure.
  [ "$st" = "$2" ] || return 1
  return 0
}
stop_child() {
  [ -n "$CHILD" ] || return 0
  local c start pg grp kdeadline left
  c="$CHILD"; start="$CHILD_START"
  # Address the session's process group only when the child actually LEADS one
  # (it does whenever a watchdog wraps it). Without a watchdog the agent is a
  # direct child in the driver's own group, and `-<pid>` could name some
  # unrelated group — identity first, never a bare name.
  pg="$(ps -o pgid= -p "$c" 2>/dev/null | tr -d ' ')"
  if [ "$pg" = "$c" ]; then grp=1; else grp=0; fi
  if [ "$grp" = 1 ]; then kill -TERM -- -"$c" 2>/dev/null; else kill -TERM "$c" 2>/dev/null; fi
  # Say so. A silent wait of up to 20 s after a Ctrl-C reads as a hang, and the
  # user's next move is another Ctrl-C — which is precisely the signal this
  # handler must survive, so tell them what it will do.
  echo "unattended-loop: stopping session pid $c — waiting up to ${STOP_GRACE}s for it to exit, then SIGKILL. Signal again to escalate now." >&2
  STOP_DEADLINE=$(( $(date +%s) + STOP_GRACE ))
  while child_alive "$c" "$start"; do
    [ "$(date +%s)" -ge "$STOP_DEADLINE" ] && break
    poll_sleep
  done
  if child_alive "$c" "$start"; then
    if [ "$grp" = 1 ]; then kill -KILL -- -"$c" 2>/dev/null; else kill -KILL "$c" 2>/dev/null; fi
    # Deliberately a LOCAL deadline: a third signal must not be able to cut the
    # post-SIGKILL settle short and have a session that was 0.2 s from death
    # recorded as a survivor.
    kdeadline=$(( $(date +%s) + STOP_KILL_GRACE ))
    while child_alive "$c" "$start"; do
      [ "$(date +%s)" -ge "$kdeadline" ] && break
      poll_sleep
    done
  fi
  if child_alive "$c" "$start"; then
    CHILD_SURVIVED="$c"
    CHILD=""; CHILD_START=""
    return 1
  fi
  # The session is down. Decide on the session pid alone: a straggler left in
  # the group is a grandchild, which cannot advance STATE.md or hold the
  # worktree as the session — name it, do not hold the project hostage to it.
  # Only the group is searched, so a grandchild that escaped via setsid() is
  # neither stopped nor named here (see Known limits in the header).
  if [ "$grp" = 1 ]; then
    left="$(pgrep -g "$c" 2>/dev/null | tr '\n' ' ')"
    [ -n "$left" ] && log_line "shutdown: session $c stopped; still in its process group (grandchildren, not the session): $left"
  fi
  CHILD=""; CHILD_START=""
  return 0
}
LOCK_HOLD_WARNED=0
release_lock_or_hold() {
  if [ -n "$CHILD_SURVIVED" ]; then
    if [ "$LOCK_HOLD_WARNED" = 0 ]; then
      LOCK_HOLD_WARNED=1
      # acquire_lock steals a lock whose holder pid is dead — and this driver's
      # pid is about to be. Hand the lock to the process that IS still running,
      # so the next driver's existing fail-closed check reads a live holder and
      # refuses, instead of stealing the lock and starting a second session on
      # the same STATE.md.
      [ "$LOCK_OWNED" = 1 ] && echo "$CHILD_SURVIVED" > "$LOCK_DIR/pid" 2>/dev/null
      echo "unattended-loop: session pid $CHILD_SURVIVED outlived SIGTERM and SIGKILL — KEEPING the driver lock $LOCK_DIR (now naming that pid) so no second driver starts on this project. Stop that process, then remove the lock dir." >&2
      log_line "shutdown: session $CHILD_SURVIVED survived SIGKILL; lock kept and holder rewritten to $CHILD_SURVIVED"
    fi
    return 0
  fi
  release_lock
}
# One shutdown at a time, and a SECOND signal must not cancel the first.
# `CHILD` used to carry both duties: stop_child cleared it on entry, so a signal
# arriving while the first handler was still waiting found it empty, returned
# at once, released the lock and exited — out from under a session that was
# still alive. That is reachable by an ordinary impatient Ctrl-C, not just by an
# adversary, which is why the two duties are now separate flags:
#   STOPPING  — a handler is inside the wait (re-entrancy)
#   STOP_DONE — a handler finished (idempotency, for the EXIT trap)
# The nested call neither releases nor exits. It collapses the deadline instead,
# so pressing the stop key twice means "escalate to SIGKILL now" — which is what
# the user is asking for — and the FIRST handler still owns the sequence.
shutdown_handler() { # [exit-code]
  if [ "$STOPPING" = 1 ]; then
    STOP_DEADLINE=0
    echo "unattended-loop: second stop signal — escalating to SIGKILL now." >&2
    return 0
  fi
  [ "$STOP_DONE" = 1 ] && return 0
  STOPPING=1
  stop_child
  release_lock_or_hold
  [ -n "$SESSION_ERR" ] && rm -f "$SESSION_ERR" "$SESSION_ERR.part"
  SESSION_ERR=""
  STOP_DONE=1
  STOPPING=0
  # EXIT passes no code: exiting from the EXIT trap would re-enter it.
  [ $# -ge 1 ] && [ -n "$1" ] && exit "$1"
  return 0
}
# EXIT routes through the same stop-then-release sequence: a terminating path
# outside INT/TERM/HUP/QUIT must not free the lock and orphan the session.
trap 'shutdown_handler' EXIT
trap 'shutdown_handler 130' INT
trap 'shutdown_handler 143' TERM
trap 'shutdown_handler 129' HUP
trap 'shutdown_handler 131' QUIT
acquire_lock

START_EPOCH=$(date +%s)
DEADLINE=$(( START_EPOCH + MAX_MINUTES * 60 ))

TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN=gtimeout; fi

session=0
no_progress=0
prev_sig="$(progress_sig)"

log_line() { printf '%s\n' "$1" >> "$DRIVER_LOG"; }

# --- session stderr capture (audit D-05) -------------------------------------
# The agent's stdout is its transcript and STAYS on /dev/null: capturing it would
# grow the evidence directory without bound. Its stderr is where an expired key,
# a rate limit, an unknown flag and a bad working directory say what happened —
# all of which reached this log as `exit=N` and the no-progress verdict, with
# nothing to tell them apart. D-02 survived to the audit for exactly that reason.
#
# Redaction is best effort, NOT a guarantee: driver.log lives in the evidence
# directory a user is told to read and attach, so known credential shapes are
# masked before the tail is written, and LOOP_TESTING_DISABLE_SESSION_STDERR=1
# turns the capture off entirely for anyone who would rather have none of it.
SESSION_ERR_LINES=20
SESSION_ERR_BYTES=4000
session_err_open() {   # truncate (or create) this session's capture file
  [ "${LOOP_TESTING_DISABLE_SESSION_STDERR:-0}" != "1" ] || { SESSION_ERR=""; return 0; }
  if [ -n "$SESSION_ERR" ]; then rm -f "$SESSION_ERR" "$SESSION_ERR.part" 2>/dev/null; return 0; fi
  SESSION_ERR="$(mktemp "${TMPDIR:-/tmp}/loop-testing-session-err.XXXXXX" 2>/dev/null)" || SESSION_ERR=""
  # Absolutise it. mktemp honours a RELATIVE $TMPDIR, and this path is used in a
  # redirect evaluated inside the subshell AFTER `cd "$PROJECT"` — where it no
  # longer resolves, so the subshell dies before exec and the session never runs
  # at all. Same shape as a relative script path handed to a subshell that cd's.
  case "$SESSION_ERR" in ''|/*) ;; *) SESSION_ERR="$PWD/$SESSION_ERR" ;; esac
  # mktemp created it; remove it so that its REAPPEARANCE (by rename, below) is
  # the bounded writer's completion signal. `wait` returns when the session
  # exits, which is before the writer has seen EOF and flushed.
  rm -f "$SESSION_ERR" "$SESSION_ERR.part" 2>/dev/null
  return 0
}
session_err_redact() {
  # Order matters: specific shapes first so a partially masked value cannot
  # re-match. A pre-ship review put real lines through the first version of this
  # and got the credentials back out, so each rule below names what it is for.
  local q="'" dq='"'
  sed -E \
    -e 's/(sk-[A-Za-z0-9_-]{4})[A-Za-z0-9_-]+/\1***REDACTED***/g' \
    -e 's/(gh[pousr]_)[A-Za-z0-9]{8,}/\1***REDACTED***/g' \
    -e 's/(xox[baprs]-)[A-Za-z0-9-]{8,}/\1***REDACTED***/g' \
    -e 's/AKIA[0-9A-Z]{16}/AKIA***REDACTED***/g' \
    `# userinfo in a URL: https://ci-bot:glpat-…@host — no rule covered this` \
    -e "s#(://[^/[:space:]:@]+:)[^@[:space:]/]+@#\\1***REDACTED***@#g" \
    `# any whitespace after the scheme word, not a literal space (a TAB got through)` \
    -e 's#([Bb]earer[[:space:]]+)[A-Za-z0-9._~+/-]{8,}=*#\1***REDACTED***#g' \
    `# Authorization: take the REST OF THE LINE past an optional scheme word.` \
    `# The old rule took the next token, so it redacted "Basic" and published the` \
    `# base64 that follows it. Case-insensitive: headers are printed as sent.` \
    -e 's/([Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*([A-Za-z]+[[:space:]]+)?).*/\1***REDACTED***/' \
    `# name=value where the NAME says secret/token/password/key — covers` \
    `# X-Api-Key:, "api_key":"…", AWS_SECRET_ACCESS_KEY= (whose value has / and +` \
    `# and so never formed a long enough opaque run to be caught generically)` \
    -e "s#([A-Za-z0-9_.-]*([Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Kk][Ee][Yy])[A-Za-z0-9_.-]*[$dq$q]?[[:space:]]*[:=][[:space:]]*[$dq$q]?)[A-Za-z0-9._~+/=-]+#\\1***REDACTED***#g" \
    `# last resort: an unlabelled opaque run. 32, not 24: at 24 it ate ordinary` \
    `# path segments and branch names out of the diagnostics this exists to keep.` \
    -e 's#[A-Za-z0-9_+=-]{32,}#***REDACTED***#g' 2>/dev/null
}
session_err_log() { # <session-number>
  [ -n "$SESSION_ERR" ] || return 0
  # The writer flushes at EOF, which happens after `wait` has already returned.
  # Bounded, and it does NOT tax a quiet session: a session that wrote nothing
  # still renames an empty file immediately, so this falls through at once.
  local waited=0
  while [ ! -e "$SESSION_ERR" ] && [ "$waited" -lt 20 ]; do
    sleep 0.1 2>/dev/null || sleep 1
    waited=$((waited + 1))
  done
  [ -s "$SESSION_ERR" ] || return 0
  log_line "session $1 stderr (last $SESSION_ERR_LINES lines, redacted — best effort, not a guarantee):"
  # Bounded twice: bytes first, so one runaway line cannot be read whole.
  tail -c "$SESSION_ERR_BYTES" "$SESSION_ERR" 2>/dev/null | tail -n "$SESSION_ERR_LINES" 2>/dev/null \
    | session_err_redact \
    | while IFS= read -r eline || [ -n "$eline" ]; do log_line "  | $eline"; done
  rm -f "$SESSION_ERR" 2>/dev/null
  return 0
}

summary_exit() { # code, verdict
  # round via round_of (normalized), not the raw field — parity with unattended-codex.sh
  # and with the per-session log lines below, which already use round_of.
  echo "unattended-loop: $2 (sessions=$session, elapsed=$(( ($(date +%s) - START_EPOCH) / 60 ))m, round=$(round_of), status=$(state_field status), issues=$(issue_count))"
  log_line "driver end: $2 sessions=$session round=$(round_of) status=$(state_field status) issues=$(issue_count)"
  exit "$1"
}

log_line "driver start: project=$PROJECT max_sessions=$MAX_SESSIONS max_minutes=$MAX_MINUTES max_turns=$MAX_TURNS plugin_dir=$PLUGIN_DIR bin=$CLAUDE_BIN"

# DR-7: without a watchdog binary a single hung session would hang the driver
# forever (--max-minutes is only checked BETWEEN sessions). Refuse to start
# unless the caller explicitly accepts unbounded sessions. Kept identical to
# unattended-codex.sh.
if [ -z "$TIMEOUT_BIN" ]; then
  if [ "$NO_WATCHDOG" = "1" ]; then
    log_line "WARNING: no timeout/gtimeout on PATH and --no-watchdog given — sessions run unbounded (wall-clock watchdog disabled)"
  else
    die "no timeout/gtimeout on PATH — the wall-clock watchdog cannot run (a hung session would hang the driver); install coreutils or pass --no-watchdog to accept unbounded sessions"
  fi
fi

# The agent binary gets the same treatment as the watchdog: check it BEFORE the
# loop, not by launching it. An absent or misspelled $CLAUDE_BIN used to run the
# full session loop, produce no STATE.md, and surface as the no-progress circuit
# breaker — "agent likely failed before round 0" — which blames the loop for a
# missing executable and sends the user looking in the wrong place.
command -v "$CLAUDE_BIN" >/dev/null 2>&1 \
  || die "claude binary not found: '$CLAUDE_BIN' is neither an executable path nor a command on PATH — install Claude Code or pass --claude-bin <path>"

while true; do
  # 1. Terminal? (STATE must exist AND status be a terminal value.)
  st="$(state_field status)"
  case "$st" in
    CONVERGED|INCOMPLETE|BLOCKED) summary_exit 0 "loop reached terminal status=$st" ;;
  esac

  # 2. Limits (checked before launching another session).
  if [ "$session" -ge "$MAX_SESSIONS" ]; then
    summary_exit 3 "INCOMPLETE: hit --max-sessions=$MAX_SESSIONS without convergence"
  fi
  now=$(date +%s)
  if [ "$now" -ge "$DEADLINE" ]; then
    summary_exit 4 "INCOMPLETE: hit --max-minutes=$MAX_MINUTES without convergence"
  fi

  # 3. Launch one resume session, bounded by a wall-clock watchdog below the
  #    remaining budget. CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 stops the print
  #    background ceiling from guillotining a delegated loop mid-flight; the
  #    watchdog is the real bound.
  session=$(( session + 1 ))
  remaining=$(( DEADLINE - now ))
  sess_budget=$(( SESSION_MINUTES * 60 ))
  [ "$sess_budget" -gt "$remaining" ] && sess_budget="$remaining"
  [ "$sess_budget" -lt 1 ] && sess_budget=1

  # Run the session with the project as cwd (the skill operates on ./docs/looptesting).
  # F6: when the driver itself is launched from inside a Claude Code session
  # (agent-teams/coordinator context), the child inherits env vars that boot it
  # in coordinator mode with ORCHESTRATION-ONLY tools (Agent/SendMessage/
  # TaskStop/Workflow — no Read/Bash/Edit/Write), so it can only delegate (F4)
  # or honestly BLOCK. Unset them so the child gets the standard tool set.
  # Verified empirically 2026-07-11: inherited env → 4 orchestration tools;
  # sanitized → full set incl. Bash/Edit/Read/Write/Skill.
  SANITIZE_ENV=(env -u CLAUDE_CODE_COORDINATOR_MODE -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
                -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID)
  # Background + `wait`, never a foreground subshell: see the shutdown note above
  # the traps. `exec` makes $! the watchdog's own pid (and therefore its pgid),
  # so stop_child can address the session's whole process group. `timeout` stays
  # in its default (non --foreground) mode because that group is what makes the
  # session addressable at all — NOT because `-k` reaps it: measured here, uutils
  # 0.8.0 signals only its direct child, so a TERM-ignoring grandchild in the
  # same group survives `-k` (GNU's timeout does signal the group). stop_child's
  # own SIGKILL is what empties the group.
  # An async list in a non-interactive shell gets stdin from /dev/null and SIGINT
  # AND SIGQUIT ignored; `<&0` and `trap - INT QUIT` hand the session the same
  # stdin and dispositions the old foreground subshell gave it. The output
  # redirections stay on the exec'd command rather than the subshell, so a
  # failing `cd "$PROJECT"` still says so.
  session_err_open
  # When capture is off this resolves to /dev/null.part -> /dev/null, which is
  # a write to a file nobody reads; the tail is still bounded, so it cannot grow.
  ERR_SINK=/dev/null; [ -n "$SESSION_ERR" ] && ERR_SINK="$SESSION_ERR"
  if [ -n "$TIMEOUT_BIN" ]; then
    ( trap - INT QUIT; cd "$PROJECT" && export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 && exec "$TIMEOUT_BIN" -k 15 "$sess_budget" \
      "${SANITIZE_ENV[@]}" "$CLAUDE_BIN" -p "$RESUME_PROMPT" \
      --plugin-dir "$PLUGIN_DIR" --permission-mode bypassPermissions --max-turns "$MAX_TURNS" >/dev/null 2> >(tail -c "$SESSION_ERR_BYTES" > "$ERR_SINK.part" 2>/dev/null; mv -f "$ERR_SINK.part" "$ERR_SINK" 2>/dev/null) ) \
      <&0 &
  else
    ( trap - INT QUIT; cd "$PROJECT" && export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 && exec \
      "${SANITIZE_ENV[@]}" "$CLAUDE_BIN" -p "$RESUME_PROMPT" \
      --plugin-dir "$PLUGIN_DIR" --permission-mode bypassPermissions --max-turns "$MAX_TURNS" >/dev/null 2> >(tail -c "$SESSION_ERR_BYTES" > "$ERR_SINK.part" 2>/dev/null; mv -f "$ERR_SINK.part" "$ERR_SINK" 2>/dev/null) ) \
      <&0 &
  fi
  CHILD=$!
  CHILD_START="$(proc_start "$CHILD")"
  wait "$CHILD"
  rc=$?
  CHILD=""; CHILD_START=""

  cur_round="$(round_of)"
  cur_issues="$(issue_count)"
  cur_status="$(state_field status)"; [ -n "$cur_status" ] || cur_status="?"
  cur_sig="$(progress_sig)"
  log_line "session $session: exit=$rc round=$cur_round issues=$cur_issues status=$cur_status sig=$cur_sig"
  session_err_log "$session"

  # C9: a session that didn't even create STATE.md made no progress and resuming
  # can't help — fail fast instead of waiting out the 2-session no-progress window.
  if [ ! -f "$STATE" ]; then
    summary_exit 5 "NO_PROGRESS: session $session produced no STATE.md (agent likely failed before round 0)"
  fi

  # 4. No-progress circuit breaker. Progress = ANY change in the composite signal
  #    (round, issue count, converged_streak, runs/ evidence bytes+count, or round-0
  #    bootstrap bytes). These catch a long round that spans sessions appending
  #    evidence before `round` ticks, progress made by advancing convergence, and a
  #    round 0 filling PLAN/FEATURE_MATRIX before any runs/ file exists — cases the
  #    old round+issues-only signal misread as stuck (audit A3 / PL-2).
  if [ "$cur_sig" = "$prev_sig" ]; then
    no_progress=$(( no_progress + 1 ))
  else
    no_progress=0
  fi
  prev_sig="$cur_sig"
  if [ "$no_progress" -ge 2 ]; then
    summary_exit 5 "NO_PROGRESS: 2 consecutive sessions with no change in round/issues/streak/runs/bootstrap (stuck)"
  fi
done
