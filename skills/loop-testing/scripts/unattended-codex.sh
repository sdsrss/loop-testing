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

# Shared with unattended-loop.sh: the nine helpers that were byte-identical in
# both drivers, redaction set included. See lib.sh's driver section for what did
# NOT move. Fail-closed: a driver that cannot read its own helpers must not go on
# to take a lock and launch full-permission sessions.
# No path this script builds ever wants CDPATH. `cd` ECHOES its target into the
# command substitution whenever CDPATH is consulted — for a bare-relative name,
# which includes a relative --project and a relative --worktree-path, not just
# the resolver below. Guarding site by site missed both, so it is unset once,
# before the first `cd`. The resolver keeps its own `CDPATH=''` prefixes.
unset CDPATH
# Resolve THIS script's real directory before looking for lib.sh beside it.
# Two shapes the plain `cd "$(dirname …)" && pwd` form got wrong, both measured
# against `v0.16.0`, where they worked because there was nothing to find:
#   * CDPATH. `cd` ECHOES its target whenever CDPATH is consulted, and the echo
#     lands inside the command substitution, so the path comes back doubled and
#     names nothing. `CDPATH=.` — which people do put in rc files — is enough.
#     Spelled `CDPATH=''` rather than `CDPATH=`: the bare form is the same POSIX
#     env prefix but reads as a typo'd assignment to shellcheck (SC1007), and the
#     raised gate is right to say so. Measured identical under `CDPATH=.`.
#     Only a bare-relative invocation consults it.
#   * a symlinked entry point. `dirname` names the LINK's directory, so a script
#     symlinked onto PATH looked for lib.sh beside the symlink and refused.
#     Resolved with the POSIX `readlink` loop; `readlink -f` is GNU-only and
#     macOS does not have it. Bounded, so a symlink cycle cannot spin here — past
#     the bound the path stays wrong and the refusal below fires, which is right.
_lt_self="${BASH_SOURCE[0]}"
_lt_hops=0
while [ -L "$_lt_self" ] && [ "$_lt_hops" -lt 32 ]; do
  _lt_d="$(CDPATH='' cd -P "$(dirname "$_lt_self")" && pwd)"
  _lt_self="$(readlink "$_lt_self")"
  case "$_lt_self" in /*) ;; *) _lt_self="$_lt_d/$_lt_self" ;; esac
  _lt_hops=$((_lt_hops + 1))
done
_lt_dir="$(CDPATH='' cd -P "$(dirname "$_lt_self")" && pwd)"
. "$_lt_dir/lib.sh" || {
  echo "unattended-codex: cannot source lib.sh beside this script — the install is incomplete." >&2
  exit 2
}
# `.` succeeding says the file PARSED, not that it is whole — see lib.sh's
# sentinel. A driver missing session_err_redact would still run and would write
# the session's stderr into driver.log unredacted, which is the leak that file
# exists to stop; a missing release_lock would leave the lock dir behind. Refuse
# before taking the lock rather than discover it at teardown.
_lt_missing=""
[ "${LT_LIB_LOADED:-}" = 1 ] || _lt_missing=" the completion sentinel"
for _lt_f in is_uint release_lock holder_state proc_start poll_sleep runs_sig \
             bootstrap_sig session_err_close session_err_redact; do
  declare -F "$_lt_f" >/dev/null 2>&1 || _lt_missing="$_lt_missing ${_lt_f}()"
done
if [ -n "$_lt_missing" ]; then
  echo "unattended-codex: lib.sh beside this script sourced but is missing:$_lt_missing — a truncated or partial install; refusing before taking a lock." >&2
  exit 2
fi
unset _lt_missing _lt_f _lt_self _lt_hops _lt_d _lt_dir


PROJECT=""
MAX_SESSIONS=15
MAX_MINUTES=90
SESSION_MINUTES=40
CODEX_BIN="codex"
# `${CODEX_HOME:-$HOME/.codex}` reads as guarded and is not: the `:-` protects
# the OUTER name, while `$HOME` inside the replacement text is expanded
# unguarded exactly when CODEX_HOME is unset — the condition the default exists
# to handle. Under `set -u` above, an unset HOME kills the driver here, at line
# one of its configuration, before it can reach any of the teardown paths that
# were hardened for this. Same shape as the two `"$HOME/…"` sites already fixed,
# and invisible to the sweep that found them because the `$HOME` is mid-string
# after a `:-` rather than behind a quote.
SKILL_DIR="${CODEX_HOME:-${HOME:-}/.codex}/skills/loop-testing"
PROTECT=1
NO_WATCHDOG=0

die() { echo "unattended-codex: $*" >&2; exit 2; }

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

# After arg parsing, so an explicit --skill-dir is the answer rather than a flag
# the refusal ignores. With neither CODEX_HOME nor HOME set, SKILL_DIR above
# resolved to a bare "/.codex/…" — a real path that is simply never the skill, so
# the run would fail much later with a message about the wrong thing. Mirrors
# install-codex.sh's own refusal, which names the two flags that work.
if [ -z "${CODEX_HOME:-}" ] && [ -z "${HOME:-}" ] && [ "$SKILL_DIR" = "/.codex/skills/loop-testing" ]; then
  die "CODEX_HOME is not set and HOME is empty, so there is nowhere to look for the skill. Pass --skill-dir <dir>, or set CODEX_HOME."
fi
[ -n "$PROJECT" ] || die "--project <dir> is required"
[ -d "$PROJECT" ] || die "--project is not a directory: $PROJECT"
# Absolutize (audit D-02; unattended-loop.sh already did). The path is used
# twice per session — `cd "$PROJECT"` and then `codex exec -C "$PROJECT"`, which
# Codex resolves against the cwd it now has — so `--project proj` became
# `proj/proj` for every session, each failed before reading the prompt, and the
# run ended as NO_PROGRESS exit 5 with the loop blamed for a path the driver
# itself had mangled.
PROJECT="$(cd "$PROJECT" && pwd)" || die "cannot enter --project: $PROJECT"
# A relative --codex-bin with a slash is resolved HERE, against the cwd it was typed
# in: the preflight below runs here and passes, but every session execs it after
# `cd "$PROJECT"`, where it names nothing — each session then failed and the
# driver reported NO_PROGRESS. A bare name stays a PATH lookup. An unresolvable
# directory is left as given, so the preflight's refusal names it.
case "$CODEX_BIN" in
  /*) ;;
  */*) _bd="$(cd "$(dirname "$CODEX_BIN")" 2>/dev/null && pwd)" && CODEX_BIN="$_bd/$(basename "$CODEX_BIN")"; unset _bd ;;
esac
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
  # Matched-to-steal, not matched-to-refuse. The earlier form listed the two
  # refusals and let everything else fall through to the `rm -rf` below, so any
  # verdict the list did not anticipate — including an empty one, if the
  # command substitution above died from a signal — authorised the steal by
  # default. The destructive branch is the one that has to be named.
  case "$hstate" in
    gone) : ;;   # the only verdict that authorises the steal below
    alive)
      die "another loop-testing driver is running on this project (lock held${holder:+ by pid $holder}); refusing to run concurrently — remove $LOCK_DIR by hand only if you are sure no driver is live" ;;
    unknown)
      die "a driver lock is held by pid $holder and this host gives no way to tell whether that process is still running (no procfs, no usable ps, or a procfs that hides other accounts' processes); refusing to run concurrently rather than stealing a lock that may be live — remove $LOCK_DIR by hand only if you are sure no driver is live" ;;
    *)
      die "the lock holder check returned an unrecognised verdict ('$hstate') for pid $holder; refusing to run rather than stealing a lock on an answer this script does not understand — remove $LOCK_DIR by hand only if you are sure no driver is live" ;;
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
# Read by poll_sleep, which now lives in lib.sh — the coupling the linter is
# pointing at is real and is the price of one copy instead of two.
# shellcheck disable=SC2034
POLL_STEP=auto
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
# unless the caller explicitly accepts running without one. Kept identical to
# unattended-loop.sh.
#
# What --no-watchdog is, and what it is not (audit D-07): it waives THIS refusal
# and nothing else. On a host that has timeout or gtimeout — the common case —
# every session is still wrapped in `timeout -k 15 <session budget>`, so passing
# the flag there changes nothing about how long a session may run. See the longer
# note in unattended-loop.sh.
if [ -z "$TIMEOUT_BIN" ]; then
  if [ "$NO_WATCHDOG" = "1" ]; then
    log "WARNING: no timeout/gtimeout on PATH and --no-watchdog given — sessions run unbounded (wall-clock watchdog disabled)"
  else
    die "no timeout/gtimeout on PATH — the wall-clock watchdog cannot run (a hung session would hang the driver); install coreutils, or pass --no-watchdog to start anyway and accept that no wall-clock bound exists on this host"
  fi
elif [ "$NO_WATCHDOG" = "1" ]; then
  # Console too, not just driver.log: the misreading this guards against belongs
  # to whoever typed the flag, and they are not reading a log file yet.
  nw_note="NOTE: --no-watchdog has no effect on this host — $TIMEOUT_BIN is on PATH, so every session is still bounded — by --session-minutes=$SESSION_MINUTES, or by whatever is left of --max-minutes, whichever is smaller, and never below one second. The flag only waives the refusal to start when NEITHER timeout NOR gtimeout exists; there is no way to run a session unbounded on a host that has one."
  log "$nw_note"
  printf '%s\n' "unattended-codex: $nw_note" >&2
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
  # Strip the git environment before launching the session (delta review D5).
  # git exports GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE to its own hooks, to
  # `rebase --exec` and to `bisect run`, so a driver started from any of those
  # hands them on, and `git init` / `git rev-parse` inside the session then
  # address a different repository. unattended-loop.sh strips them inside its
  # existing SANITIZE_ENV; this driver has no such array, so the `env` goes on
  # the exec line. One process per session, nothing per hook invocation.
  GIT_SANITIZE=(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_CEILING_DIRECTORIES)
  if [ -n "$TIMEOUT_BIN" ]; then
    ( trap - INT QUIT; cd "$PROJECT" && exec "$TIMEOUT_BIN" -k 15 "$sess_budget" \
      "${GIT_SANITIZE[@]}" "$CODEX_BIN" exec -s danger-full-access -C "$PROJECT" "$RESUME_PROMPT" >/dev/null 2>"$ERR_TARGET" ) \
      <&0 &
  else
    ( trap - INT QUIT; cd "$PROJECT" && exec "${GIT_SANITIZE[@]}" "$CODEX_BIN" exec -s danger-full-access -C "$PROJECT" "$RESUME_PROMPT" >/dev/null 2>"$ERR_TARGET" ) \
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
