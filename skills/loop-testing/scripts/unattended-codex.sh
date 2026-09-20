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
#                       [--skill-dir ${CODEX_HOME:-~/.codex}/skills/loop-testing]
#                       [--no-protect]
#                       [--no-watchdog]
#
# Shutdown: SIGINT (Ctrl-C), SIGTERM, SIGHUP or SIGQUIT to the driver — bare pid
# or process group — stops the driver AND the running session, waits for it to
# be gone, and only then restores the skill dir and releases the lock. The
# session is launched in the background and awaited with `wait`, which a trapped
# signal interrupts immediately; the handler then signals the session's own
# process group, which `timeout` (GNU and uutils, via setpgid) keeps separate
# from the driver's — so a signal to the driver's group alone used to free the
# lock and leave a danger-full-access session running (audit D-01). The skill
# dir stays write-protected until that session is actually down.
#
# Why the wait is bounded at 20 s (derived — please do not "tune" it), what
# happens at the bound, and the known limits (SIGKILL to the driver, a setsid
# grandchild, `timeout -k` not being a group reaper on uutils): see the same
# block in unattended-loop.sh, which this file mirrors line for line.
#
# Exit codes (mirror unattended-loop.sh):
#   0  STATE reached a terminal status (CONVERGED / INCOMPLETE / BLOCKED).
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
# Absolutize (audit D-02; unattended-loop.sh already did). The path is used
# twice per session — `cd "$PROJECT"` and then `codex exec -C "$PROJECT"`, which
# Codex resolves against the cwd it now has — so `--project proj` became
# `proj/proj` for every session, each failed before reading the prompt, and the
# run ended as NO_PROGRESS exit 5 with the loop blamed for a path the driver
# itself had mangled.
PROJECT="$(cd "$PROJECT" && pwd)" || die "cannot enter --project: $PROJECT"
for v in MAX_SESSIONS MAX_MINUTES SESSION_MINUTES; do
  # Name the flag the user typed (--max-minutes), not the variable (MAX_MINUTES).
  # `tr`, not ${v,,} + ${flag//_/-}: case-modification expansion is bash 4.0+ and a
  # FATAL bad substitution on stock macOS bash 3.2 — and this line runs on every
  # invocation, not just the error path (tests/portability/bash3.test.sh guards it).
  eval "val=\$$v"; flag=$(printf '%s' "$v" | tr 'A-Z_' 'a-z-')
  # shellcheck disable=SC2154  # val is assigned by the eval above
  is_uint "$val" || die "--$flag must be a non-negative integer, got: $val"
done

LT="$PROJECT/docs/looptesting"
STATE="$LT/STATE.md"
ISSUES="$LT/ISSUES.md"
DLOG="$LT/driver.log"
# Ownership handshake with sandbox-setup.sh (audit D-03; kept identical to
# unattended-loop.sh). The driver needs docs/looptesting for driver.log and the
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
: >> "$DLOG" || die "cannot write driver.log at $DLOG"
if [ "$LT_EXISTED" = 0 ] && [ ! -f "$LT/.sandbox/created-dirs.env" ]; then
  mkdir -p "$LT/.sandbox" 2>/dev/null \
    && printf 'MADE_LOOPTESTING_DIR=1\n' > "$LT/.sandbox/created-dirs.env" 2>/dev/null
fi

# Concurrency guard: refuse to run a second driver on the same target — two drivers
# would race STATE.md / driver.log / ISSUES.md / the worktree and corrupt the
# progress fingerprint and ledger. Portable atomic lock via mkdir (no flock — it is
# absent on macOS). A crashed driver's lock (holder PID no longer alive) is stolen; a
# live holder is refused (audit DR-4). Kept identical to unattended-loop.sh.
LOCK_DIR="$LT/.driver.lock"
LOCK_OWNED=0
release_lock() { [ "$LOCK_OWNED" = 1 ] && rm -rf "$LOCK_DIR" 2>/dev/null; LOCK_OWNED=0; }
# Prints alive | gone | unknown for a PID. `kill -0` alone cannot answer this:
# it fails for ESRCH (the process is gone) AND for EPERM (it is alive, owned by
# another user), and reading the second as death stole the lock from a LIVE
# driver — two sessions with bypassPermissions then writing the same STATE.md,
# ISSUES.md and worktree, which is the one thing this guard exists to prevent
# (audit D-06). A holder owned by another account is ordinary: a driver started
# by root, by a systemd unit, or by a teammate on a shared box.
#
# procfs and `ps -p` answer "does this PID exist" without needing permission to
# signal it — the question actually being asked. `ps` is already required here
# (proc_start uses it). Where neither exists the answer is `unknown`, which this
# path refuses, because it has always refused ambiguity rather than stealing.
holder_state() { # pid
  kill -0 "$1" 2>/dev/null && { printf 'alive'; return; }
  if [ -d /proc/self ]; then
    if [ -e "/proc/$1" ]; then printf 'alive'; else printf 'gone'; fi
    return
  fi
  if command -v ps >/dev/null 2>&1; then
    if ps -p "$1" >/dev/null 2>&1; then printf 'alive'; else printf 'gone'; fi
    return
  fi
  printf 'unknown'
}
acquire_lock() {
  # LOCK_OWNED before the pid write at both mkdir sites (see unattended-loop.sh):
  # a signal in that window terminates, and an unset flag would leave a pid-less
  # lock dir that later runs read as a live holder and refuse forever.
  if mkdir "$LOCK_DIR" 2>/dev/null; then LOCK_OWNED=1; echo "$$" > "$LOCK_DIR/pid"; return 0; fi
  local holder="" hstate=alive; [ -f "$LOCK_DIR/pid" ] && read -r holder < "$LOCK_DIR/pid" 2>/dev/null
  case "$holder" in ''|*[!0-9]*) holder="" ;; esac
  # Fail-closed: steal a present lock ONLY when its holder PID is readable AND
  # confirmed no longer alive (a crashed driver). An unreadable/empty holder is
  # treated as live and refused — never steal on ambiguity. (Two drivers starting in
  # the same sub-ms window could still both steal a genuinely-stale lock; this is a
  # best-effort accidental-double-launch guard, not a hard mutex — see README.)
  [ -n "$holder" ] && hstate="$(holder_state "$holder")"
  case "$hstate" in
    alive)
      die "another loop-testing driver is running on this project (lock held${holder:+ by pid $holder}); refusing to run concurrently — remove $LOCK_DIR by hand only if you are sure no driver is live" ;;
    unknown)
      die "a driver lock is held by pid $holder and this host offers no way to tell whether that process is still running (no procfs, no ps); refusing to run concurrently rather than stealing a lock that may be live — remove $LOCK_DIR by hand only if you are sure no driver is live" ;;
  esac
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
  if [ "$CLEANED" = "1" ]; then release_lock_or_hold; return 0; fi
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
  release_lock_or_hold
}
# A bash trap handler RETURNS into the interrupted flow, so `trap cleanup INT
# TERM` un-protected the skill dir and dropped the lock while the loop kept
# launching full-access sessions. Clean up, then terminate with the conventional
# 128+n status. cleanup is idempotent, so the EXIT trap after these is a no-op.
#
# The session is stopped FIRST, and stop_child does not return until it is gone
# (audit D-01; kept identical to unattended-loop.sh, including the derivation of
# the 20 s bound and the decision rule at it). `timeout` puts itself and `codex
# exec` in a process group of their own (pgid == its pid), so a signal to the
# driver or its group never reached the session. The pid is known because the
# session is launched with `&` and awaited with `wait` (interruptible by a
# trapped signal, unlike a foreground child). Signalling only ASKS; the wait is
# what makes the lock's absence mean the session's absence.
STOP_GRACE="${LOOP_TESTING_STOP_GRACE:-20}"
case "$STOP_GRACE" in ''|*[!0-9]*) STOP_GRACE=20 ;; esac
STOP_KILL_GRACE=2
STOP_DEADLINE=0       # global so a SECOND signal can collapse it (see shutdown_handler)
STOPPING=0            # a shutdown is in progress (re-entrancy, not idempotency)
STOP_DONE=0           # a shutdown has completed (idempotency, not re-entrancy)
CHILD=""              # pid of the running session (the watchdog leads its group)
SESSION_ERR=""        # this session's stderr capture file, "" when off (audit D-05)
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
  # "Cannot tell" is NOT "mismatch" (see unattended-loop.sh): an empty answer
  # means `ps` failed, which a full-permission session can cause by exhausting
  # forks, so trust what kill -0 just proved instead of reporting a live session
  # as gone. A REUSED pid still yields a different non-empty start.
  st="$(proc_start "$1")"
  [ -n "$st" ] || return 0
  # A non-empty MISMATCH means this pid is no longer the process we launched:
  # treat the session as gone and signal nothing further, because the realistic
  # cause is pid reuse and killing a stranger's group is the worse failure.
  [ "$st" = "$2" ] || return 1
  return 0
}
stop_child() {
  [ -n "$CHILD" ] || return 0
  local c start pg grp kdeadline left
  c="$CHILD"; start="$CHILD_START"
  # Address the session's process group only when the child actually LEADS one
  # (it does whenever a watchdog wraps it) — otherwise `-<pid>` could name some
  # unrelated group. Identity first, never a bare name.
  pg="$(ps -o pgid= -p "$c" 2>/dev/null | tr -d ' ')"
  if [ "$pg" = "$c" ]; then grp=1; else grp=0; fi
  if [ "$grp" = 1 ]; then kill -TERM -- -"$c" 2>/dev/null; else kill -TERM "$c" 2>/dev/null; fi
  # Say so: a silent wait after a Ctrl-C reads as a hang, and the user's next
  # move is another Ctrl-C — the very signal this handler must survive.
  echo "unattended-codex: stopping session pid $c — waiting up to ${STOP_GRACE}s for it to exit, then SIGKILL. Signal again to escalate now." >&2
  STOP_DEADLINE=$(( $(date +%s) + STOP_GRACE ))
  while child_alive "$c" "$start"; do
    [ "$(date +%s)" -ge "$STOP_DEADLINE" ] && break
    poll_sleep
  done
  if child_alive "$c" "$start"; then
    if [ "$grp" = 1 ]; then kill -KILL -- -"$c" 2>/dev/null; else kill -KILL "$c" 2>/dev/null; fi
    # Deliberately a LOCAL deadline: a third signal must not cut the
    # post-SIGKILL settle short and have a dying session recorded as a survivor.
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
  # Decide on the session pid alone: a straggler left in the group is a
  # grandchild, which cannot advance STATE.md or hold the worktree as the
  # session — name it, do not hold the project hostage to it. Only the group is
  # searched, so a grandchild that escaped via setsid() is neither stopped nor
  # named here (see Known limits in unattended-loop.sh).
  if [ "$grp" = 1 ]; then
    left="$(pgrep -g "$c" 2>/dev/null | tr '\n' ' ')"
    [ -n "$left" ] && log "shutdown: session $c stopped; still in its process group (grandchildren, not the session): $left"
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
      # refuses instead of starting a second full-access session on the same
      # STATE.md.
      [ "$LOCK_OWNED" = 1 ] && echo "$CHILD_SURVIVED" > "$LOCK_DIR/pid" 2>/dev/null
      echo "unattended-codex: session pid $CHILD_SURVIVED outlived SIGTERM and SIGKILL — KEEPING the driver lock $LOCK_DIR (now naming that pid) so no second driver starts on this project. Stop that process, then remove the lock dir." >&2
      log "shutdown: session $CHILD_SURVIVED survived SIGKILL; lock kept and holder rewritten to $CHILD_SURVIVED"
    fi
    return 0
  fi
  release_lock
}
log() { echo "$*" >> "$DLOG"; }

# --- session stderr capture (audit D-05, second attempt) ---------------------
# Kept byte-for-byte equivalent to unattended-loop.sh's block; see the long note
# there for why this is a PLAIN FILE and not a bounded writer. Short version: the
# first attempt (pulled in 98095b7) wrote through `2> >(tail -c … > "$SINK.part";
# mv -f …)`, and with the opt-out the sink is /dev/null — /dev/null.part is not
# creatable by a normal user, so the writer exited, the stderr pipe lost its
# reader and every session died of SIGPIPE at round 0; under root the rename
# replaced the /dev/null device node itself. A plain `2>"$file"` has no writer to
# lose and no path derived from the sink.
#
# A FRESH FILE PER SESSION, for the reason spelled out in unattended-loop.sh:
# O_TRUNC resets a file's SIZE, never the OFFSET of an already-open file
# description, so a grandchild still holding fd 2 writes into the NEXT session's
# file at its stale offset and pushes that session's own error out of the tail
# window. Reproduced in review. Per session, it can only reach its own.
#
# Residuals, stated: within one session the file is unbounded (bounding it live
# needs a poll loop around `wait`, which is D-01's machinery and not something a
# diagnostics feature gets to touch), and N surviving grandchildren hold N
# unlinked inodes instead of one — invisible disk traded for silent data loss.
SESSION_ERR_LINES=20
SESSION_ERR_BYTES=4000
session_err_open() {
  [ "${LOOP_TESTING_DISABLE_SESSION_STDERR:-0}" != "1" ] || { SESSION_ERR=""; return 0; }
  # ONE statement, on purpose: bash runs traps between commands in the main
  # shell, so a signal during mktemp is queued until the assignment completes and
  # shutdown_handler always sees the path it has to remove.
  SESSION_ERR="$(mktemp "${TMPDIR:-/tmp}/loop-testing-session-err.XXXXXX" 2>/dev/null)" || SESSION_ERR=""
  # Absolutise: the path is opened by the subshell AFTER `cd "$PROJECT"`, and
  # mktemp honours a relative $TMPDIR. The driver's own cwd never changes.
  case "$SESSION_ERR" in ''|/*) ;; *) SESSION_ERR="$PWD/$SESSION_ERR" ;; esac
  # An unwritable or vanished $TMPDIR costs the capture and nothing else. Opening
  # once per RUN instead meant a $TMPDIR removed mid-run failed every later
  # session's redirect, so the agent never launched again — reported as exit=1.
  return 0
}
session_err_close() {
  [ -n "$SESSION_ERR" ] && rm -f "$SESSION_ERR"
  SESSION_ERR=""
  return 0
}
# What shutdown_handler does with whatever the CURRENT session left. The loop
# removes each session's file once it has been logged, so at most one is
# outstanding here; there is no `.part` sibling to clean, because the redirect
# writes the file directly.
#
# Called AFTER release_lock_or_hold, and conditional on what it decided. On the
# CHILD_SURVIVED path that function deliberately KEEPS the lock and tells the
# user to go stop a full-permission session that outlived SIGKILL — and this
# capture is the only description of what that session was doing. Deleting it
# there deletes the evidence at the moment it is asked for, so it is kept and
# named instead. Its bytes are NOT redacted: redaction happens on the way into
# driver.log, not into this file, which is why the message says so.
#
# A FUNCTION, not an inline block, and the reason is testability rather than
# tidiness. Inlined it was unreachable from the suite — session_err_close clears
# SESSION_ERR before any normal exit reaches the handler, so both arms are dead
# on every path a test can drive, and review inverted the whole condition with
# the suite staying green. It cannot be reached by a fixture either: `kill` is a
# shell builtin so no PATH shim intercepts the liveness check, a `ps` shim sits
# on a branch that never runs, and the zombie route was measured and disproved.
# Extracting it by surrounding TEXT was tried and rejected — this block's own
# comments quote the anchors around it, so renaming the real call still matched,
# inside a comment, and the harness silently tested the wrong region. A named
# function is an anchor that cannot drift that way.
session_err_dispose() {
  if [ -n "$CHILD_SURVIVED" ] && [ -n "$SESSION_ERR" ]; then
    echo "unattended-codex: keeping that session's stderr capture at $SESSION_ERR — it is the only record of what pid $CHILD_SURVIVED was doing, and it is NOT redacted. Delete it once you are done." >&2
  elif [ -n "$SESSION_ERR" ]; then
    rm -f "$SESSION_ERR"
  fi
  SESSION_ERR=""
  return 0
}
session_err_redact() {
  # Order matters: specific shapes first, so a partially masked value cannot
  # re-match. Case is spelled out rather than using a `I` flag — BSD sed has no
  # such flag, and both drivers must run on macOS.
  local q="'" dq='"'
  sed -E \
    -e 's/(sk-[A-Za-z0-9_-]{4})[A-Za-z0-9_-]+/\1***REDACTED***/g' \
    -e 's/(gh[pousr]_)[A-Za-z0-9]{8,}/\1***REDACTED***/g' \
    -e 's/(xox[baprs]-)[A-Za-z0-9-]{8,}/\1***REDACTED***/g' \
    -e 's/AKIA[0-9A-Z]{16}/AKIA***REDACTED***/g' \
    `# userinfo in a URL: https://ci-bot:glpat-…@host` \
    -e "s#(://[^/[:space:]:@]+:)[^@[:space:]/]+@#\\1***REDACTED***@#g" \
    `# any whitespace after the scheme word, not a literal space (a TAB got through)` \
    -e 's#([Bb]earer[[:space:]]+)[A-Za-z0-9._~+/-]{8,}=*#\1***REDACTED***#g' \
    `# Authorization, QUOTED form, before the bare one. Every JSON, Python-dict` \
    `# and Ruby-hash rendering puts a quote between the name and the colon, which` \
    `# the bare rule's literal ':' cannot match — review got 'ci-bot:supersecret'` \
    `# back out of {"headers":{"authorization":"Basic …"}}, and the base64 of a` \
    `# short credential pair is under the 32-char fallback. Stops at the closing` \
    `# quote rather than running to end of line, so the rest of the JSON (status` \
    `# codes, retry-after, the message itself) survives.` \
    `# The leading [A-Za-z-]* and the optional > cover the renderings review found` \
    `# still leaking afterwards: "x-authorization", "proxy-authorization", and` \
    `# Ruby/Perl "authorization" => "Basic …".` \
    `# Residual: sed is line-based, so a value on the NEXT line (pretty-printed` \
    `# JSON) is an orphaned 24-character run that no rule here can attribute.` \
    -e "s#([$dq$q][A-Za-z-]*[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn][$dq$q][[:space:]]*[:=]>?[[:space:]]*[$dq$q])([A-Za-z]+[[:space:]]+)?[^$dq$q]*#\\1\\2***REDACTED***#g" \
    `# Authorization: take the REST OF THE LINE past an optional scheme word.` \
    `# Taking the next token instead redacted "Basic" and published the base64.` \
    `# Rest-of-line is deliberate for the bare header form — the value IS the` \
    `# rest — and costs any diagnostic printed after it on the same line.` \
    -e 's/([Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn][[:space:]]*[:=][[:space:]]*([A-Za-z]+[[:space:]]+)?).*/\1***REDACTED***/' \
    `# Glued <prefix>Token / <prefix>Secret / <prefix>Password names, FIRST because` \
    `# it is the narrower rule. The rule below wants a separator before the secret` \
    `# word, so every camelCase and PascalCase form slipped past it: review found` \
    `# twelve lowerCamelCase leaks (accessToken, clientSecret, dbPassword…) and,` \
    `# after the first attempt at this rule, nine PascalCase ones — .NET` \
    `# appsettings.json is PascalCase by convention, and Go's %+v on oauth2.Config` \
    `# and oauth2.Token prints exported fields, which are necessarily capitalised.` \
    `#` \
    `# The prefix is ENUMERATED, and that is the second attempt at this rule. The` \
    `# first tried to do it structurally, on the case of the first letter:` \
    `# lowercase meant a credential field, uppercase a type name. Measured, case` \
    `# carries no such information — accessToken and nextToken are both` \
    `# lowerCamelCase, AccessToken and SyntaxToken are both PascalCase — so the` \
    `# structural rule failed in BOTH directions at once: it leaked the nine` \
    `# PascalCase credentials and redacted thirteen lexer-API names (nextToken:,` \
    `# peekToken:, readToken:, expectToken:…), which are exactly the diagnostics` \
    `# this feature exists to carry. A list that fails by missing an unlisted` \
    `# prefix beats a structure that fails at both ends.` \
    `# Residual, stated: an unlisted prefix (twilioToken=) is not matched here.` \
    -e "s#(^|[^A-Za-z0-9])(([Aa]ccess|[Rr]efresh|[Ss]ession|[Ii]d|[Bb]earer|[Cc]lient|[Aa]pi|[Aa]uth|[Oo]auth|[Bb]ot|[Uu]ser|[Aa]dmin|[Ww]ebhook|[Ss]lack|[Nn]pm|[Gg]it[Hh]ub|[Gg]it[Ll]ab|[Ss]tripe|[Dd]b)(Token|Secret|Password))([$dq$q]?[[:space:]]*[:=][[:space:]]*[$dq$q]?)[A-Za-z0-9._~+/=-]{10,}#\\1\\2\\5***REDACTED***#g" \
    `# name=value whose NAME says secret/token/password/key. Three bounds, each` \
    `# one a defect the pulled round shipped: the word must START at a` \
    `# non-alphanumeric boundary (it matched 'key' inside 'monKEY'), it must END` \
    `# at one (inside 'KEYboard'), and the value must be 10+ characters (it took` \
    `# ANY value, so 'token: expected ;' became 'token: ***REDACTED***' — the` \
    `# feature deleting the diagnostics it exists to deliver). Glued compounds` \
    `# that really are key names (apikey, authkey, accesskey…) are listed rather` \
    `# than inferred.` \
    `# Known holes, measured and left open rather than chased: a glued SUFFIX` \
    `# (keyId=) is an identifier more often than a credential; hyphenated CSS` \
    `# spec names (ident-token:, delim-token:) satisfy the start boundary and are` \
    `# redacted; and the 10-character floor sits between 'expected' (8) and` \
    `# 'unexpected' (10), so 'token: unexpected end of input' loses one word.` \
    `# Every floor that saves that word also lets an all-letter credential` \
    `# through, and this file is attached to bug reports — over-redaction costs a` \
    `# word, under-redaction costs a key.` \
    -e "s#(^|[^A-Za-z0-9])([Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|([Aa][Pp][Ii]|[Aa][Uu][Tt][Hh]|[Aa][Cc][Cc][Ee][Ss][Ss]|[Pp][Rr][Ii][Vv][Aa][Tt][Ee])?[Kk][Ee][Yy])(([_.-][A-Za-z0-9_.-]*)?[$dq$q]?[[:space:]]*[:=][[:space:]]*[$dq$q]?)[A-Za-z0-9._~+/=-]{10,}#\\1\\2\\4***REDACTED***#g" \
    `# last resort: an unlabelled opaque run. 32, not 24: at 24 it ate ordinary` \
    `# path segments and branch names out of the diagnostics this exists to keep.` \
    -e 's#[A-Za-z0-9_+=-]{32,}#***REDACTED***#g' 2>/dev/null
}
session_err_log() { # <session-number>
  [ -n "$SESSION_ERR" ] || return 0
  # No wait, no poll: `wait` has already returned, so the session's own writes are
  # complete and in the file. A background grandchild still holding fd 2 keeps
  # appending, and is simply not waited for — the first attempt's 2s-per-session
  # wait for a pipe EOF cost the most on exactly the sessions most likely to have
  # failed.
  [ -s "$SESSION_ERR" ] || return 0
  log "session $1 stderr (last $SESSION_ERR_LINES lines, redacted — best effort, not a guarantee):"
  # Bounded twice: bytes first, so one runaway line cannot be read whole.
  #
  # The byte cut lands mid-line, and it runs BEFORE redaction. A 4091-byte
  # one-line HTTP dump with `"api_key":"…"` straddling 4000 bytes had its LABEL
  # amputated by `tail -c`, so the rules below saw a bare 18-character run with
  # nothing to identify it and passed it through verbatim — reproduced in review
  # on both drivers, 18 of a 31-character secret published into driver.log, with
  # the filler after it masked so the line read as redacted. No rule can fix
  # that: the input was mutilated before any rule saw it. So when the cap
  # actually truncated, the first line of the window is dropped. It is USUALLY a
  # fragment, and when the cut happens to land exactly on a newline it is a
  # complete line dropped for nothing — the cost is one line of the OLDEST
  # context either way, against publishing an arbitrary fragment of whatever
  # straddled the boundary.
  local sz body
  # `tr -dc` because BSD/macOS `wc` right-aligns its count in a fixed-width
  # field, and command substitution strips trailing newlines but not leading
  # spaces. A bare `wc -c` returns "      4091", the guard below reads the space
  # as non-numeric, sz becomes 0, the truncation branch is never taken and THE
  # BYTE CAP DOES NOT EXIST on that platform — the driver then `cat`s a capture
  # this file's own header calls unbounded. Six other places in this repo already
  # strip that padding, including :150 and :159 of this script.
  sz=$(wc -c < "$SESSION_ERR" 2>/dev/null | tr -dc '0-9')
  case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
  body=$({ if [ "$sz" -gt "$SESSION_ERR_BYTES" ]; then
             tail -c "$SESSION_ERR_BYTES" "$SESSION_ERR" 2>/dev/null | sed '1d'
           else
             cat "$SESSION_ERR" 2>/dev/null
           fi; } | tail -n "$SESSION_ERR_LINES" 2>/dev/null | session_err_redact)
  # Dropping the partial line can leave nothing at all — a single line longer
  # than the cap, which is exactly the HTTP-dump shape that carries credentials.
  # Say so, rather than printing a bare header that reads like a broken capture.
  # Two causes, and the message must not claim the one it did not check: a
  # capture holding a single newline also reaches here, and saying "one line
  # longer than 4000 bytes" about a 1-byte file is a false statement written into
  # the evidence directory.
  if [ -z "$body" ]; then
    if [ "$sz" -gt "$SESSION_ERR_BYTES" ]; then
      log "  | (nothing shown: the tail was one line longer than $SESSION_ERR_BYTES bytes, and an excerpt of a line that long can publish a credential whose label was cut off)"
    else
      log "  | (nothing shown: the capture held $sz byte(s) and no printable line)"
    fi
  else
    printf '%s\n' "$body" | while IFS= read -r eline || [ -n "$eline" ]; do log "  | $eline"; done
  fi
  return 0
}

# One shutdown at a time, and a SECOND signal must not cancel the first (see the
# same block in unattended-loop.sh: `CHILD` used to serve as both the
# re-entrancy and the idempotency flag, so a second Ctrl-C mid-wait released the
# lock out from under a live danger-full-access session). The nested call
# neither releases nor exits — it collapses the deadline, so a second press
# means "escalate to SIGKILL now" while the first handler keeps the sequence.
shutdown_handler() { # [exit-code]
  if [ "$STOPPING" = 1 ]; then
    STOP_DEADLINE=0
    echo "unattended-codex: second stop signal — escalating to SIGKILL now." >&2
    return 0
  fi
  [ "$STOP_DONE" = 1 ] && return 0
  STOPPING=1
  stop_child
  cleanup
  session_err_dispose
  STOP_DONE=1
  STOPPING=0
  # EXIT passes no code: exiting from the EXIT trap would re-enter it.
  [ $# -ge 1 ] && [ -n "$1" ] && exit "$1"
  return 0
}
# EXIT routes through the same stop-then-restore-then-release sequence: a
# terminating path outside INT/TERM/HUP/QUIT must not free the lock and orphan
# the session.
trap 'shutdown_handler' EXIT
trap 'shutdown_handler 130' INT
trap 'shutdown_handler 143' TERM
trap 'shutdown_handler 129' HUP
trap 'shutdown_handler 131' QUIT
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

# Same preflight as unattended-loop.sh: an absent or misspelled $CODEX_BIN used to
# run the whole session loop and surface as the no-progress circuit breaker, which
# blames the loop for a missing executable.
command -v "$CODEX_BIN" >/dev/null 2>&1 \
  || die "codex binary not found: '$CODEX_BIN' is neither an executable path nor a command on PATH — install Codex CLI or pass --codex-bin <path>"

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
  # Background + `wait`, never a foreground subshell (shutdown note above the
  # traps). `exec` makes $! the watchdog's own pid, hence its pgid, so stop_child
  # can address the session's whole group; `timeout` stays in its default
  # (non --foreground) mode so `-k 15` still reaches the agent's grandchildren.
  # `<&0` + `trap - INT QUIT`: an async list would otherwise get /dev/null stdin
  # and SIGINT AND SIGQUIT ignored — the foreground subshell it replaces passed
  # all three through. The redirections stay on the exec'd command rather than
  # the subshell, so a failing `cd "$PROJECT"` still says so.
  # Opened HERE, not at the top of the loop and not once per run: above the
  # limit checks this would create a file on every early-exit path, and once per
  # run it cannot recover from a $TMPDIR that goes away mid-run.
  # Capture off (or unavailable) resolves to /dev/null — the device node itself,
  # opened O_TRUNC, which is a no-op on it. Nothing derives a second path from
  # this value (audit D-05, 98095b7 CRITICAL).
  session_err_open
  ERR_TARGET=/dev/null
  [ -n "$SESSION_ERR" ] && ERR_TARGET="$SESSION_ERR"
  if [ -n "$TIMEOUT_BIN" ]; then
    ( trap - INT QUIT; cd "$PROJECT" && exec "$TIMEOUT_BIN" -k 15 "$sess_budget" \
      "$CODEX_BIN" exec -s danger-full-access -C "$PROJECT" "$RESUME_PROMPT" >/dev/null 2>"$ERR_TARGET" ) \
      <&0 &
  else
    ( trap - INT QUIT; cd "$PROJECT" && exec "$CODEX_BIN" exec -s danger-full-access -C "$PROJECT" "$RESUME_PROMPT" >/dev/null 2>"$ERR_TARGET" ) \
      <&0 &
  fi
  CHILD=$!
  CHILD_START="$(proc_start "$CHILD")"
  wait "$CHILD"
  rc=$?
  CHILD=""; CHILD_START=""

  cur_round="$(round_of)"
  cur_issues="$(issue_count)"
  cur_sig="$(progress_sig)"
  log "session $session: exit=$rc round=$cur_round issues=$cur_issues status=$(state_field status) sig=$cur_sig"
  session_err_log "$session"
  session_err_close

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
