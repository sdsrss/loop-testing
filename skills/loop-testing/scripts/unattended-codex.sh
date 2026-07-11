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
#   - The installed skill dir is chmod'd read-only for the run and restored on
#     EXIT, so a full-access session cannot rewrite the skill it is executing.
#
# Usage:
#   unattended-codex.sh --project <dir> [--max-sessions 15] [--max-minutes 90]
#                       [--session-minutes 40] [--codex-bin codex]
#                       [--skill-dir ~/.codex/skills/loop-testing] [--no-protect]
#
# Exit codes (mirror unattended-loop.sh):
#   0  STATE reached a terminal status (CONVERGED / INCOMPLETE / BLOCKED).
#   2  usage / argument error.
#   3  hit --max-sessions before terminal (driver-declared INCOMPLETE).
#   4  hit --max-minutes before terminal (driver-declared INCOMPLETE).
#   5  NO_PROGRESS: two consecutive sessions with no change in round AND issues.
set -u

PROJECT=""
MAX_SESSIONS=15
MAX_MINUTES=90
SESSION_MINUTES=40
CODEX_BIN="codex"
SKILL_DIR="${CODEX_HOME:-$HOME/.codex}/skills/loop-testing"
PROTECT=1

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
    -h|--help)         sed -n '2,31p' "$0"; exit 0;;
    *) die "unknown argument: $1";;
  esac
done

[ -n "$PROJECT" ] || die "--project <dir> is required"
[ -d "$PROJECT" ] || die "--project is not a directory: $PROJECT"
for v in MAX_SESSIONS MAX_MINUTES SESSION_MINUTES; do
  eval "val=\$$v"; is_uint "$val" || die "--${v,,} must be a non-negative integer, got: $val"
done

LT="$PROJECT/docs/looptesting"
STATE="$LT/STATE.md"
ISSUES="$LT/ISSUES.md"
DLOG="$LT/driver.log"
mkdir -p "$LT"
: >> "$DLOG"

# Protect the installed skill from the full-access session; always restore.
# Set the restore trap BEFORE the chmod so a signal in between can't leave the
# dir read-only (only SIGKILL, which skips traps, can — unavoidable).
if [ "$PROTECT" = "1" ] && [ -d "$SKILL_DIR" ]; then
  trap 'chmod -R u+w "$SKILL_DIR" 2>/dev/null || true' EXIT
  chmod -R a-w "$SKILL_DIR" 2>/dev/null || true
fi

RESUME_PROMPT='使用 loop-testing 技能：读取 docs/looptesting/STATE.md，从断点继续执行自测循环（若 STATE 不存在则从第 0 轮开始）。在当前会话内联执行整个循环，不要把循环委派给别的 agent 或 Task 工具。本会话尽量多完成整轮（选场景→像真实用户使用→发现即立案/复现/分级→修复+回归→复验+轮末结算），每轮末更新 STATE.md 的机器判读字段（round/converged_streak/status）。若已满足收敛判据（连续2轮收敛低风险轮）或保险停止条件，按 references/exit-and-report.md 写入终态（CONVERGED/INCOMPLETE/BLOCKED）并停止；否则显式声明「继续第 N+1 轮」。'

state_field() { grep -aE "^$1:" "$STATE" 2>/dev/null | head -1 | sed "s/^$1:[[:space:]]*//" | tr -d '[:space:]'; }
round_of()  { local r; r=$(state_field round | sed 's/[^0-9-]//g'); [ -n "$r" ] && echo "$r" || echo -1; }
issue_count() { [ -f "$ISSUES" ] && { grep -acE '^### ISSUE-' "$ISSUES" 2>/dev/null || true; } || echo 0; }
runs_sig() { # "<file-count>:<total-bytes>" of runs/*.md — evidence-growth signal
  local d="$LT/runs" n b
  [ -d "$d" ] || { echo "0:0"; return; }
  n=$(find "$d" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
  b=$(cat "$d"/*.md 2>/dev/null | wc -c | tr -d ' ')
  echo "$n:$b"
}
progress_sig() { # composite fingerprint: round|issues|streak|runsN:runsB
  local s; s="$(state_field converged_streak)"; [ -n "$s" ] || s=-1
  printf '%s|%s|%s|%s' "$(round_of)" "$(issue_count)" "$s" "$(runs_sig)"
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
    ( cd "$PROJECT" && "$TIMEOUT_BIN" -k 20 "$sess_budget" \
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

  # No-progress breaker: ANY change in the composite signal (round, issue count,
  # converged_streak, runs/ evidence bytes+count) counts as progress — catches a
  # long round spanning sessions and convergence progress the old round+issues
  # signal misread as stuck (audit A3). Kept identical to unattended-loop.sh.
  if [ "$cur_sig" = "$prev_sig" ]; then
    noprog=$(( noprog + 1 ))
  else
    noprog=0
  fi
  prev_sig="$cur_sig"

  if [ "$noprog" -ge 2 ]; then
    summary_exit 5 "NO_PROGRESS: two consecutive sessions with no change in round/issues/streak/runs"
  fi
done
