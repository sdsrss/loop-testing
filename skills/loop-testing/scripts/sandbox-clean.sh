#!/usr/bin/env bash
# sandbox-clean.sh — tear down ONLY what sandbox-setup.sh created.
#
# Fail-closed: with no ownership marker it deletes nothing (never guesses what it
# owns). Stops only processes it recorded, removes only the worktree it created,
# and KEEPS the qa branch (holds fix commits), the baseline tag, and the entire
# docs/looptesting/ evidence dir. Idempotent. Never touches user data.
#
# Usage: sandbox-clean.sh   (run from anywhere inside the target repo)
set -u

echo_info() { echo "sandbox-clean: $*"; }

TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo_info "not a git repository — nothing to clean."; exit 0; }

MARKER="$TOP/docs/looptesting/.sandbox/ownership.env"
PIDS_FILE="$TOP/docs/looptesting/.pids"

if [ ! -f "$MARKER" ]; then
  echo_info "no ownership marker at $MARKER — fail-closed: deleting nothing."
  exit 0
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

echo_info "done. Kept: qa branch, baseline tag, docs/looptesting/ evidence."
exit 0
