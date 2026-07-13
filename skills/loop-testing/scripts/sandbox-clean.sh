#!/usr/bin/env bash
# sandbox-clean.sh — tear down ONLY what sandbox-setup.sh created.
#
# Fail-closed: with no ownership marker it deletes nothing (never guesses what it
# owns). Stops only processes it recorded, removes only the worktree it created,
# and KEEPS the qa branch (holds fix commits), the baseline tag, and the entire
# docs/looptesting/ evidence dir. Idempotent. Never touches user data.
#
# Usage: sandbox-clean.sh [--purge [--discard-fixes]]   (run from anywhere inside the target repo)
#
#   --purge          USER-run full cleanup after a TERMINAL run (STATE.md status
#                    CONVERGED / INCOMPLETE / BLOCKED): additionally delete the
#                    evidence dir docs/looptesting/, the owned baseline tag, and
#                    the owned qa branch. The branch is deleted only when it has
#                    no fix commits beyond the recorded baseline OR
#                    --discard-fixes is given — fix commits exist ONLY on that
#                    branch, so harvest them (merge / cherry-pick) first.
#                    Refuses (exit 3) without an ownership marker or a terminal
#                    STATE. Default behavior without --purge is unchanged.
#
# Exit codes: 0 cleaned (or nothing to clean) · 1 internal abort (re-anchored to
# the main tree but cannot cd there — applies to both plain clean and --purge) ·
# 2 usage error · 3 --purge refused (no marker / non-terminal STATE).
set -u

echo_info() { echo "sandbox-clean: $*"; }

PURGE=0
DISCARD_FIXES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --purge)         PURGE=1; shift ;;
    --discard-fixes) DISCARD_FIXES=1; shift ;;
    *) echo "sandbox-clean: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ "$DISCARD_FIXES" = 1 ] && [ "$PURGE" = 0 ]; then
  echo "sandbox-clean: --discard-fixes requires --purge" >&2; exit 2
fi

TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo_info "not a git repository — nothing to clean."; exit 0; }

# --- re-anchor when invoked from inside a linked worktree (audit NEW-1 / R57) --
# From inside the qa worktree, --show-toplevel is the WORKTREE, so the marker
# lookup below would miss the main tree's marker and the fail-closed branch
# would return a FAKE success (exit 0, nothing cleaned — processes and worktree
# left behind). Detect the linked-worktree topology (git-dir != git-common-dir),
# re-anchor to the main tree, and cd there so the worktree removal below never
# runs from inside the directory it is deleting. Validation failure (odd
# layouts, git < 2.5 without --git-common-dir) keeps the original TOP untouched.
GD="$(git rev-parse --git-dir 2>/dev/null)"
GCD="$(git rev-parse --git-common-dir 2>/dev/null)"
if [ -n "$GCD" ] && [ "$GD" != "$GCD" ]; then
  case "$GCD" in /*) : ;; *) GCD="$(cd "$GCD" 2>/dev/null && pwd)" ;; esac
  MAIN_TOP="$(git -C "$(dirname "$GCD")" rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$MAIN_TOP" ] && [ "$MAIN_TOP" != "$TOP" ] && [ -d "$MAIN_TOP" ]; then
    echo_info "invoked from inside a linked worktree — re-anchoring to the main tree: $MAIN_TOP"
    TOP="$MAIN_TOP"
    cd "$TOP" || { echo_info "cannot cd to $TOP — aborting without cleaning."; exit 1; }
  fi
fi

MARKER="$TOP/docs/looptesting/.sandbox/ownership.env"
PIDS_FILE="$TOP/docs/looptesting/.pids"

if [ ! -f "$MARKER" ]; then
  if [ "$PURGE" = 1 ]; then
    echo_info "--purge refused: no ownership marker at $MARKER — nothing is known to be ours; fail-closed, deleting nothing. (If leftovers exist, remove them by hand per the README cleanup section.)"
    exit 3
  fi
  echo_info "no ownership marker at $MARKER — fail-closed: deleting nothing."
  exit 0
fi

# --purge precondition (checked BEFORE any action): only a TERMINAL run may be
# purged — purging must never race a live loop, and a half-done run's evidence
# is the resume contract. Everything below (process stop, worktree removal) is
# the normal clean; the purge stage itself runs at the end.
if [ "$PURGE" = 1 ]; then
  PURGE_STATE="$TOP/docs/looptesting/STATE.md"
  st="$(grep -aE '^status:' "$PURGE_STATE" 2>/dev/null | head -1 | sed 's/^status:[[:space:]]*//' | tr -d '[:space:]')"
  case "$st" in
    CONVERGED|INCOMPLETE|BLOCKED) : ;;
    *)
      echo_info "--purge refused: STATE.md status is '${st:-<missing>}' — need a terminal status (CONVERGED / INCOMPLETE / BLOCKED). Let the run finish (or resume it), then purge."
      exit 3 ;;
  esac
fi

# Read marker fields by parsing (NEVER source: a tampered marker must not run).
mval() { grep -E "^$1=" "$MARKER" 2>/dev/null | head -1 | cut -d= -f2-; }
CREATED_WORKTREE="$(mval CREATED_WORKTREE)"

# --- stop only processes we recorded (and their descendants) -----------------
# A dev server started by the agent commonly forks worker children (vite->esbuild,
# npm->node); signalling only the bare recorded PID leaves those workers holding
# ports/CPU past teardown (audit DR-1). Snapshot each recorded PID's descendant
# tree FIRST (before signalling anything, so children reparented by an early
# parent-kill aren't lost), then SIGTERM the whole set, then SIGKILL any survivor.
# (Residual: .pids stores bare PIDs captured live at start; descendant discovery
# needs pgrep — absent it we fall back to the recorded PID only. A PID recycled by
# an unrelated process between capture and clean could be signalled — the writer
# verifies liveness + listening port at capture to minimize this.)
if [ -f "$PIDS_FILE" ]; then
  collect_tree() {   # print PID + all descendants, depth-first (needs pgrep)
    printf '%s\n' "$1"
    if command -v pgrep >/dev/null 2>&1; then
      local child
      for child in $(pgrep -P "$1" 2>/dev/null); do collect_tree "$child"; done
    fi
  }
  TARGETS=""
  while IFS= read -r pid; do
    case "$pid" in
      ''|*[!0-9]*) continue ;;   # skip blanks / non-numeric lines
    esac
    kill -0 "$pid" 2>/dev/null || continue
    TARGETS="$TARGETS
$(collect_tree "$pid")"
  done < "$PIDS_FILE"
  TARGETS=$(printf '%s\n' "$TARGETS" | grep -E '^[0-9]+$' | sort -un)

  for pid in $TARGETS; do
    kill -0 "$pid" 2>/dev/null || continue
    kill "$pid" 2>/dev/null && echo_info "sent SIGTERM to process $pid"
  done
  # Escalate to SIGKILL for any that ignore SIGTERM within a short grace.
  for pid in $TARGETS; do
    i=0
    while [ "$i" -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
      sleep 0.1; i=$(( i + 1 ))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null && echo_info "escalated to SIGKILL for process $pid"
    fi
  done
  : > "$PIDS_FILE"   # clear the ledger; keep the file for continued runs
fi

# --- remove only the worktree we created ------------------------------------
if [ -n "$CREATED_WORKTREE" ]; then
  # Guard against ever removing the repo itself, / or $HOME.
  case "$CREATED_WORKTREE" in
    ""|"/"|"$HOME"|"$TOP")
      echo_info "refusing to remove suspicious worktree path: $CREATED_WORKTREE" ;;
    *)
      if git -C "$TOP" worktree list --porcelain 2>/dev/null \
           | grep -qxF "worktree $CREATED_WORKTREE"; then
        if git -C "$TOP" worktree remove --force "$CREATED_WORKTREE" >/dev/null 2>&1; then
          echo_info "removed worktree $CREATED_WORKTREE"
        else
          echo_info "could not remove worktree via git; leaving it in place: $CREATED_WORKTREE"
        fi
      else
        echo_info "worktree already gone: $CREATED_WORKTREE"
      fi ;;
  esac
fi

# Disarm the stop-gate sentinel + counter (loop is over; the gate must not
# block the session's final stop). Evidence files are kept.
rm -f "$TOP/docs/looptesting/.active" "$TOP/docs/looptesting/.gate-count"

# Record cleanup time; keep the marker + evidence for the final report / resume.
if ! grep -q "^CLEANED_AT=" "$MARKER" 2>/dev/null; then
  echo "CLEANED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$MARKER"
fi

# --- purge stage (only with --purge; preconditions were checked up front) -----
# Deletes ONLY what the marker records as ours. The qa branch is protected: it
# holds the fix commits, which exist nowhere else — with commits beyond the
# recorded baseline (or an unverifiable baseline) it is kept unless
# --discard-fixes explicitly waives them. A checked-out branch is never deleted.
if [ "$PURGE" = 1 ]; then
  P_TAG="$(mval CREATED_TAG)"
  P_BRANCH="$(mval CREATED_BRANCH)"
  P_BASE="$(mval BASELINE_HEAD)"
  kept_branch=""

  if [ -n "$P_TAG" ] && git -C "$TOP" rev-parse -q --verify "refs/tags/$P_TAG" >/dev/null 2>&1; then
    git -C "$TOP" tag -d "$P_TAG" >/dev/null 2>&1 && echo_info "purge: deleted baseline tag $P_TAG"
  fi

  if [ -n "$P_BRANCH" ] && git -C "$TOP" rev-parse -q --verify "refs/heads/$P_BRANCH" >/dev/null 2>&1; then
    cur="$(git -C "$TOP" symbolic-ref --short -q HEAD 2>/dev/null)"
    fixes=-1   # -1 = unknown (unverifiable baseline) -> fail-closed like >0
    if [ -n "$P_BASE" ] && git -C "$TOP" rev-parse -q --verify "$P_BASE^{commit}" >/dev/null 2>&1; then
      fixes="$(git -C "$TOP" rev-list --count "$P_BASE..refs/heads/$P_BRANCH" 2>/dev/null)"
      case "$fixes" in ''|*[!0-9]*) fixes=-1 ;; esac
    fi
    if [ "$cur" = "$P_BRANCH" ]; then
      kept_branch="$P_BRANCH (currently checked out — switch away, then delete it by hand)"
    elif [ "$fixes" = "0" ] || [ "$DISCARD_FIXES" = 1 ]; then
      if git -C "$TOP" branch -D "$P_BRANCH" >/dev/null 2>&1; then
        echo_info "purge: deleted branch $P_BRANCH"
      else
        kept_branch="$P_BRANCH (git refused the deletion — checked out in another worktree?)"
      fi
    else
      if [ "$fixes" -gt 0 ] 2>/dev/null; then
        kept_branch="$P_BRANCH (holds $fixes fix commit(s) beyond the baseline — harvest them first, or re-run with --purge --discard-fixes)"
      else
        kept_branch="$P_BRANCH (baseline unverifiable, fix commits unknown — harvest first, or re-run with --purge --discard-fixes)"
      fi
    fi
  fi

  LT_DIR="$TOP/docs/looptesting"
  case "$LT_DIR" in
    */docs/looptesting)
      rm -rf "$LT_DIR"
      echo_info "purge: removed evidence dir $LT_DIR (marker included)" ;;
    *)
      echo_info "purge: refusing to remove suspicious evidence path: $LT_DIR" ;;
  esac

  if [ -n "$kept_branch" ]; then
    echo_info "purge done. KEPT branch: $kept_branch"
  else
    echo_info "purge done."
  fi
  exit 0
fi

echo_info "done. Kept: qa branch, baseline tag, docs/looptesting/ evidence."
exit 0
