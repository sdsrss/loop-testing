#!/usr/bin/env bash
# unattended-codex.sh — outer resume-driver for the loop-testing QA loop on Codex.
#
# WHY THIS EXISTS: `codex exec` is single-shot (no --max-turns) and one session
# can end before the QA loop converges — the same "single invocation ends before
# the loop is done" failure family that unattended-loop.sh solves for `claude -p`
# (F4). Codex has no mechanism-layer stop-gate, so the loop's continuation relies
# on prompt discipline PLUS this outer driver: it repeatedly launches a `codex
# exec` session that RESUMES from docs/looptesting/STATE.md (the skill's own
# resume protocol) until STATE reports a terminal status, and fail-closes on
# stuck loops / limits.
#
# Codex specifics vs the Claude driver:
#   - `codex exec -s danger-full-access` + `-C <project>` cwd containment. The
#     read-only/workspace-write bwrap sandboxes fail in containers lacking user
#     namespaces (RTM_NEWADDR); full-access + cwd containment + skill-dir
#     write-protection is the working combination.
#   - The installed skill dir has its OWNER write bit cleared for the run and
#     restored on EXIT. This is a SPEED BUMP against the full-access session
#     casually rewriting the skill it is executing, not a guarantee: the session
#     runs as the owner, so `chmod -R u+w` undoes it in one command, and under
#     root the bits are ignored outright. A real control needs a read-only bind
#     mount or a different uid. Group/other bits are left untouched.
#
# Usage:
#   unattended-codex.sh --project <dir> [--max-sessions 15] [--max-minutes 90]
#                       [--session-minutes 40] [--codex-bin codex]
#                       [--skill-dir ~/.codex/skills/loop-testing] [--no-protect]
#                       [--no-watchdog]
#
# Shutdown: SIGINT (Ctrl-C) hits the whole process group and stops the child
# session immediately. A bare `kill -TERM <driver-pid>` is honored only BETWEEN
# sessions — bash defers the trap while the foreground child runs, so the
# worst-case latency is the remaining session budget (--session-minutes,
# watchdog-bounded). For prompt programmatic shutdown, signal the process
# group: `kill -TERM -- -<driver-pgid>`. (audit DR-6)
#
# Exit codes (mirror unattended-loop.sh):
#   0  STATE reached a terminal status (CONVERGED / INCOMPLETE / BLOCKED).
#   2  usage / argument error.
#   3  hit --max-sessions before terminal (driver-declared INCOMPLETE).
#   4  hit --max-minutes before terminal (driver-declared INCOMPLETE).
#   5  NO_PROGRESS: two consecutive sessions with no change in the composite
#      progress fingerprint (round | issues | converged_streak | runs count+bytes |
#      round-0 bootstrap bytes).
set -u

PROJECT=""
MAX_SESSIONS=15
MAX_MINUTES=90
SESSION_MINUTES=40
CODEX_BIN="codex"
SKILL_DIR="${CODEX_HOME:-$HOME/.codex}/skills/loop-testing"
PROTECT=1
NO_WATCHDOG=0

die() { echo "unattended-codex: $*" >&2; exit 2; }
is_uint() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --project)         PROJECT="${2:-}"; shift; shift;;
    --max-sessions)    MAX_SESSIONS="${2:-}"; shift; shift;;
    --max-minutes)     MAX_MINUTES="${2:-}"; shift; shift;;
    --session-minutes) SESSION_MINUTES="${2:-}"; shift; shift;;
    --codex-bin)       CODEX_BIN="${2:-}"; shift; shift;;
    --skill-dir)       SKILL_DIR="${2:-}"; shift; shift;;
    --no-protect)      PROTECT=0; shift 1;;
    --no-watchdog)     NO_WATCHDOG=1; shift 1;;
    -h|--help)         awk 'NR>1{if(/^#/)print;else exit}' "$0"; exit 0;;
    *) die "unknown argument: $1";;
  esac
done

[ -n "$PROJECT" ] || die "--project <dir> is required"
[ -d "$PROJECT" ] || die "--project is not a directory: $PROJECT"
for v in MAX_SESSIONS MAX_MINUTES SESSION_MINUTES; do
  # Name the flag the user typed (--max-minutes), not the variable (MAX_MINUTES).
  # `tr`, not ${v,,} + ${flag//_/-}: case-modification expansion is bash 4.0+ and a
  # FATAL bad substitution on stock macOS bash 3.2 — and this line runs on every
  # invocation, not just the error path (tests/portability/bash3.test.sh guards it).
  eval "val=\$$v"; flag=$(printf '%s' "$v" | tr 'A-Z_' 'a-z-')
  is_uint "$val" || die "--$flag must be a non-negative integer, got: $val"
done

LT="$PROJECT/docs/looptesting"
STATE="$LT/STATE.md"
ISSUES="$LT/ISSUES.md"
DLOG="$LT/driver.log"
mkdir -p "$LT"
: >> "$DLOG" || die "cannot write driver.log at $DLOG"

# Concurrency guard: refuse to run a second driver on the same target — two drivers
# would race STATE.md / driver.log / ISSUES.md / the worktree and corrupt the
# progress fingerprint and ledger. Portable atomic lock via mkdir (no flock — it is
# absent on macOS). A crashed driver's lock (holder PID no longer alive) is stolen; a
# live holder is refused (audit DR-4). Kept identical to unattended-loop.sh.
LOCK_DIR="$LT/.driver.lock"
LOCK_OWNED=0
release_lock() { [ "$LOCK_OWNED" = 1 ] && rm -rf "$LOCK_DIR" 2>/dev/null; LOCK_OWNED=0; }
acquire_lock() {
  # LOCK_OWNED before the pid write at both mkdir sites (see unattended-loop.sh):
  # a signal in that window terminates, and an unset flag would leave a pid-less
  # lock dir that later runs read as a live holder and refuse forever.
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

# Protect the installed skill from the full-access session; always restore. Set the
# combined cleanup trap (skill-dir restore + lock release) BEFORE the chmod so a
# signal in between can't leave the dir read-only. Trap EXIT + INT + TERM explicitly
# (don't rely on bash's implicit EXIT-on-signal, which is version/platform-dependent);
# only SIGKILL, which skips traps, can leave it read-only — unavoidable.
# The restore is gated on DID_PROTECT, not PROTECT alone: a driver refused by
# acquire_lock (another driver live on this project) never protected anything,
# and must NOT chmod the RUNNING driver's skill dir back to writable on its way
# out — that would strip the live run's protection (audit CX-1; same ownership
# gating release_lock already has via LOCK_OWNED).
DID_PROTECT=0
RO_SNAPSHOT=""   # paths under SKILL_DIR that were ALREADY non-owner-writable
CLEANED=0
cleanup() {
  # Idempotent: the INT/TERM handlers exit, which fires the EXIT trap too, so this
  # runs TWICE on every Ctrl-C. A second blanket `chmod -R u+w` after the snapshot
  # has been consumed would silently re-grant write to files the user froze.
  # The flag is set only AFTER the restore completes, so an interrupted pass still
  # retries rather than being skipped.
  if [ "$CLEANED" = "1" ]; then release_lock; return 0; fi
  if [ "$DID_PROTECT" = "1" ] && [ -d "$SKILL_DIR" ]; then
    chmod -R u+w "$SKILL_DIR" 2>/dev/null
    # Blanket restore first (guaranteed half: a failure there can only leave the
    # dir writable, never locked), then put back the owner-read-only bits the
    # user had set before the run — a 0444 file coming back 0644 is a permission
    # grant nobody asked for.
    if [ -n "$RO_SNAPSHOT" ] && [ -f "$RO_SNAPSHOT" ]; then
      while IFS= read -r -d '' p; do
        [ -e "$p" ] && chmod u-w "$p" 2>/dev/null
      done < "$RO_SNAPSHOT"
    fi
  fi
  CLEANED=1
  [ -n "$RO_SNAPSHOT" ] && rm -f "$RO_SNAPSHOT" 2>/dev/null
  release_lock
}
# A bash trap handler RETURNS into the interrupted flow, so `trap cleanup INT
# TERM` un-protected the skill dir and dropped the lock while the loop kept
# launching full-access sessions. Clean up, then terminate with the conventional
# 128+n status. cleanup is idempotent, so the EXIT trap after these is a no-op.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
acquire_lock
if [ "$PROTECT" = "1" ] && [ -d "$SKILL_DIR" ]; then
  # Arm the restore BEFORE the chmod, not after: the INT/TERM handlers now exit,
  # so a signal delivered while `chmod -R` is still walking the tree would reach
  # cleanup with DID_PROTECT=0, skip the restore, and leave the installed skill
  # dir read-only for good. Setting it first can only over-restore (a no-op
  # chmod +w on a dir we never took write off).
  DID_PROTECT=1
  # Snapshot what was already read-only BEFORE clearing anything, so the restore
  # can be faithful instead of blanket. Absent mktemp -> skip the fidelity half,
  # never the restore itself.
  RO_SNAPSHOT="$(mktemp "${TMPDIR:-/tmp}/loop-testing-ro.XXXXXX" 2>/dev/null || echo "")"
  [ -n "$RO_SNAPSHOT" ] && find "$SKILL_DIR" ! -perm -u+w -print0 > "$RO_SNAPSHOT" 2>/dev/null
  # `u-w`, not `a-w`: the session runs as THIS user, and POSIX checks the owner
  # bits for the owner, so clearing owner-write is what actually blocks it. `a-w`
  # additionally cleared group/other write, which the `u+w` restore cannot give
  # back — silently downgrading a shared, group-writable install on every run.
  chmod -R u-w "$SKILL_DIR" 2>/dev/null || true
fi

RESUME_PROMPT='使用 loop-testing 技能：读取 docs/looptesting/STATE.md，从断点继续执行自测循环（若 STATE 不存在则从第 0 轮开始）。若需从第 0 轮建沙箱：必须经 sandbox-setup.sh 用 worktree 模式隔离，禁止手动 git switch/checkout/branch 或以任何方式切换用户主工作树所在分支（改代码前先核验 docs/looptesting/.sandbox/ownership.env 存在且主树仍在原分支）。在当前会话内联执行整个循环，不要把循环委派给别的 agent 或 Task 工具。本会话尽量多完成整轮（选场景→像真实用户使用→发现即立案/复现/分级→修复+回归→复验+轮末结算），每轮末更新 STATE.md 的机器判读字段（round/converged_streak/status）。若已满足收敛判据（连续2轮收敛低风险轮）或保险停止条件，按 references/exit-and-report.md 写入终态（CONVERGED/INCOMPLETE/BLOCKED）并停止；否则显式声明「继续第 N+1 轮」。'

state_field() { grep -aE "^$1:" "$STATE" 2>/dev/null | head -1 | sed "s/^$1:[[:space:]]*//" | tr -d '[:space:]'; }
# First integer RUN in `round:`, not "every non-digit stripped" — the latter glued
# `round: 3 of 12` into 312, a round that never existed. Kept identical to unattended-loop.sh.
round_of()  { local r; r=$(state_field round | sed -n 's/^[^0-9-]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p'); [ -n "$r" ] && echo "$r" || echo -1; }
issue_count() { [ -f "$ISSUES" ] && { grep -acE '^### ISSUE-' "$ISSUES" 2>/dev/null || true; } || echo 0; }
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
  local s; s="$(state_field converged_streak)"; [ -n "$s" ] || s=-1
  printf '%s|%s|%s|%s|%s' "$(round_of)" "$(issue_count)" "$s" "$(runs_sig)" "$(bootstrap_sig)"
}

log() { echo "$*" >> "$DLOG"; }

START=$(date +%s)
DEADLINE=$(( START + MAX_MINUTES * 60 ))
session=0
noprog=0
prev_sig="$(progress_sig)"
log "driver start: project=$PROJECT max_sessions=$MAX_SESSIONS max_minutes=$MAX_MINUTES session_minutes=$SESSION_MINUTES bin=$CODEX_BIN skill_dir=$SKILL_DIR protect=$PROTECT"

summary_exit() {
  local code="$1" msg="$2"
  log "driver end: $msg sessions=$session round=$(round_of) status=$(state_field status) issues=$(issue_count)"
  echo "unattended-codex: $msg (sessions=$session, round=$(round_of), status=$(state_field status), issues=$(issue_count))"
  exit "$code"
}

# Watchdog binary: GNU coreutils ships it as `timeout`, macOS/Homebrew as
# `gtimeout`. Detect both (kept identical to unattended-loop.sh) so the wall-clock
# breaker isn't silently lost where only gtimeout exists — otherwise a single hung
# `codex exec` would hang the driver forever (--max-minutes is only checked between
# sessions).
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN=gtimeout; fi

# DR-7: without a watchdog binary a single hung session would hang the driver
# forever (--max-minutes is only checked BETWEEN sessions). Refuse to start
# unless the caller explicitly accepts unbounded sessions. Kept identical to
# unattended-loop.sh.
if [ -z "$TIMEOUT_BIN" ]; then
  if [ "$NO_WATCHDOG" = "1" ]; then
    log "WARNING: no timeout/gtimeout on PATH and --no-watchdog given — sessions run unbounded (wall-clock watchdog disabled)"
  else
    die "no timeout/gtimeout on PATH — the wall-clock watchdog cannot run (a hung session would hang the driver); install coreutils or pass --no-watchdog to accept unbounded sessions"
  fi
fi

while true; do
  st="$(state_field status)"
  case "$st" in
    CONVERGED|INCOMPLETE|BLOCKED) summary_exit 0 "loop reached terminal status=$st";;
  esac

  if [ "$session" -ge "$MAX_SESSIONS" ]; then
    summary_exit 3 "INCOMPLETE: hit --max-sessions=$MAX_SESSIONS without convergence"
  fi
  now=$(date +%s)
  if [ "$now" -ge "$DEADLINE" ]; then
    summary_exit 4 "INCOMPLETE: hit --max-minutes=$MAX_MINUTES without convergence"
  fi

  session=$(( session + 1 ))
  remaining=$(( DEADLINE - now ))
  sess_budget=$(( SESSION_MINUTES * 60 ))
  [ "$sess_budget" -gt "$remaining" ] && sess_budget="$remaining"
  [ "$sess_budget" -lt 1 ] && sess_budget=1

  # Wall-clock watchdog around the single-shot codex session; cwd = project.
  if [ -n "$TIMEOUT_BIN" ]; then
    ( cd "$PROJECT" && "$TIMEOUT_BIN" -k 15 "$sess_budget" \
      "$CODEX_BIN" exec -s danger-full-access -C "$PROJECT" "$RESUME_PROMPT" \
      >/dev/null 2>&1 )
    rc=$?
  else
    ( cd "$PROJECT" && "$CODEX_BIN" exec -s danger-full-access -C "$PROJECT" "$RESUME_PROMPT" \
      >/dev/null 2>&1 )
    rc=$?
  fi

  cur_round="$(round_of)"
  cur_issues="$(issue_count)"
  cur_sig="$(progress_sig)"
  log "session $session: exit=$rc round=$cur_round issues=$cur_issues status=$(state_field status) sig=$cur_sig"

  # C9: a session that didn't even create STATE.md made no progress and resuming
  # can't help — fail fast instead of waiting out the 2-session no-progress window.
  if [ ! -f "$STATE" ]; then
    summary_exit 5 "NO_PROGRESS: session $session produced no STATE.md (agent likely failed before round 0)"
  fi

  # No-progress breaker: ANY change in the composite signal (round, issue count,
  # converged_streak, runs/ evidence bytes+count, round-0 bootstrap bytes) counts as
  # progress — catches a long round spanning sessions, convergence progress, and a
  # round 0 filling PLAN/FEATURE_MATRIX before any runs/ file, all of which the old
  # round+issues signal misread as stuck (audit A3 / PL-2). Identical to unattended-loop.sh.
  if [ "$cur_sig" = "$prev_sig" ]; then
    noprog=$(( noprog + 1 ))
  else
    noprog=0
  fi
  prev_sig="$cur_sig"

  if [ "$noprog" -ge 2 ]; then
    summary_exit 5 "NO_PROGRESS: two consecutive sessions with no change in round/issues/streak/runs/bootstrap"
  fi
done
