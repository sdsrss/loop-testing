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
#                      [--session-minutes 50]
#
# Exit codes:
#   0  STATE reached a terminal status (CONVERGED / INCOMPLETE / BLOCKED) — the
#      loop ended on its own terms; the honest verdict is in STATE.md.
#   2  usage / argument error.
#   3  hit --max-sessions before terminal (driver-declared INCOMPLETE).
#   4  hit --max-minutes before terminal (driver-declared INCOMPLETE).
#   5  NO_PROGRESS: two consecutive sessions with no change in round AND issues.
set -u

PROJECT=""
MAX_SESSIONS=15
MAX_MINUTES=240
SESSION_MINUTES=50
MAX_TURNS=300
CLAUDE_BIN="claude"
PLUGIN_DIR=""

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
    -h|--help)         sed -n '2,30p' "$0"; exit 0;;
    *) die "unknown argument: $1";;
  esac
done

[ -n "$PROJECT" ] || die "--project <dir> is required"
[ -d "$PROJECT" ] || die "--project is not a directory: $PROJECT"
for v in MAX_SESSIONS MAX_MINUTES SESSION_MINUTES MAX_TURNS; do
  eval "val=\$$v"; is_uint "$val" || die "--${v,,} must be a non-negative integer, got: $val"
done
# Default plugin-dir = this plugin's repo root (scripts/ -> loop-testing/ -> skills/ -> root).
[ -n "$PLUGIN_DIR" ] || PLUGIN_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PROJECT="$(cd "$PROJECT" && pwd)"
LT="$PROJECT/docs/looptesting"
STATE="$LT/STATE.md"
ISSUES="$LT/ISSUES.md"
DRIVER_LOG="$LT/driver.log"

RESUME_PROMPT='使用 loop-testing 技能：读取 docs/looptesting/STATE.md，从断点继续执行自测循环（若 STATE 不存在则从第 0 轮开始）。重要：在当前会话内联执行整个循环，禁止把循环委派给 sub-agent 或 Task 工具。本会话尽量多完成整轮（选场景→像真实用户使用→发现即立案/复现/分级→修复+回归→复验+轮末结算），每轮末更新 STATE.md 的机器判读字段。若已满足收敛判据或保险停止条件，按 references/exit-and-report.md 写入终态（CONVERGED/INCOMPLETE/BLOCKED）并停止。'

state_field() { # key -> value (trimmed) ; empty if absent/unparseable
  [ -f "$STATE" ] || return 0
  grep -aE "^$1:" "$STATE" 2>/dev/null | head -1 | sed "s/^$1:[[:space:]]*//" | tr -d '[:space:]'
}
round_of() { # normalized integer round (tolerates a trailing annotation); -1 if none
  local r; r=$(state_field round | sed 's/[^0-9-]//g'); [ -n "$r" ] && echo "$r" || echo -1;
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
  b=$(cat "$d"/*.md 2>/dev/null | wc -c | tr -d ' ')
  echo "$n:$b"
}
progress_sig() { # composite progress fingerprint: round|issues|streak|runsN:runsB
  local s
  s="$(state_field converged_streak)"; [ -n "$s" ] || s=-1
  printf '%s|%s|%s|%s' "$(round_of)" "$(issue_count)" "$s" "$(runs_sig)"
}

mkdir -p "$LT"
: >> "$DRIVER_LOG" || die "cannot write driver.log at $DRIVER_LOG"

START_EPOCH=$(date +%s)
DEADLINE=$(( START_EPOCH + MAX_MINUTES * 60 ))

TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN=gtimeout; fi

session=0
no_progress=0
prev_sig="$(progress_sig)"

log_line() { printf '%s\n' "$1" >> "$DRIVER_LOG"; }
summary_exit() { # code, verdict
  echo "unattended-loop: $2 (sessions=$session, elapsed=$(( ($(date +%s) - START_EPOCH) / 60 ))m, round=$(state_field round), status=$(state_field status), issues=$(issue_count))"
  log_line "driver end: $2 sessions=$session round=$(state_field round) status=$(state_field status) issues=$(issue_count)"
  exit "$1"
}

log_line "driver start: project=$PROJECT max_sessions=$MAX_SESSIONS max_minutes=$MAX_MINUTES max_turns=$MAX_TURNS plugin_dir=$PLUGIN_DIR bin=$CLAUDE_BIN"

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
  if [ -n "$TIMEOUT_BIN" ]; then
    ( cd "$PROJECT" && CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 "$TIMEOUT_BIN" -k 15 "$sess_budget" \
      "${SANITIZE_ENV[@]}" "$CLAUDE_BIN" -p "$RESUME_PROMPT" \
      --plugin-dir "$PLUGIN_DIR" --permission-mode bypassPermissions --max-turns "$MAX_TURNS" \
      >/dev/null 2>&1 )
    rc=$?
  else
    ( cd "$PROJECT" && CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
      "${SANITIZE_ENV[@]}" "$CLAUDE_BIN" -p "$RESUME_PROMPT" \
      --plugin-dir "$PLUGIN_DIR" --permission-mode bypassPermissions --max-turns "$MAX_TURNS" \
      >/dev/null 2>&1 )
    rc=$?
  fi

  cur_round="$(round_of)"
  cur_issues="$(issue_count)"
  cur_status="$(state_field status)"; [ -n "$cur_status" ] || cur_status="?"
  cur_sig="$(progress_sig)"
  log_line "session $session: exit=$rc round=$cur_round issues=$cur_issues status=$cur_status sig=$cur_sig"

  # C9: a session that didn't even create STATE.md made no progress and resuming
  # can't help — fail fast instead of waiting out the 2-session no-progress window.
  if [ ! -f "$STATE" ]; then
    summary_exit 5 "NO_PROGRESS: session $session produced no STATE.md (agent likely failed before round 0)"
  fi

  # 4. No-progress circuit breaker. Progress = ANY change in the composite signal
  #    (round, issue count, converged_streak, or runs/ evidence bytes+count). The
  #    last two catch a long round that spans sessions appending evidence before
  #    `round` ticks, and progress made by advancing convergence — cases the old
  #    round+issues-only signal misread as stuck (audit A3).
  if [ "$cur_sig" = "$prev_sig" ]; then
    no_progress=$(( no_progress + 1 ))
  else
    no_progress=0
  fi
  prev_sig="$cur_sig"
  if [ "$no_progress" -ge 2 ]; then
    summary_exit 5 "NO_PROGRESS: 2 consecutive sessions with no change in round/issues/streak/runs (stuck)"
  fi
done
