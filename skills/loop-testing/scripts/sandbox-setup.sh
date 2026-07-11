#!/usr/bin/env bash
# sandbox-setup.sh — establish an isolated QA sandbox for the loop-testing skill.
#
# Idempotent. Refuses when it cannot isolate. Records exactly what it creates in
# docs/looptesting/.sandbox/ownership.env so sandbox-clean.sh removes ONLY its
# own artifacts and nothing of the user's.
#
# Modes:
#   worktree (default) — isolated `git worktree` checkout for code + fix commits;
#                        safe even when the main tree has uncommitted work.
#   branch             — switch the current tree to branch qa/loop-testing;
#                        requires a clean tree (refuses when dirty).
#
# The evidence dir docs/looptesting/ always lives in the MAIN repo toplevel so it
# survives worktree removal at cleanup time (see sandbox-clean.sh).
#
# Usage: sandbox-setup.sh [--mode worktree|branch] [--worktree-path PATH]
#                         [--branch NAME] [--baseline-tag NAME] [--allow-dirty]
set -u

MODE="worktree"
BRANCH="qa/loop-testing"
BASELINE_TAG="qa-baseline"
WT_PATH=""
ALLOW_DIRTY=0

die() { echo "sandbox-setup: $*" >&2; exit "${2:-1}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)          MODE="${2:-}"; shift; shift ;;
    --worktree-path) WT_PATH="${2:-}"; shift; shift ;;
    --branch)        BRANCH="${2:-}"; shift; shift ;;
    --baseline-tag)  BASELINE_TAG="${2:-}"; shift; shift ;;
    --allow-dirty)   ALLOW_DIRTY=1; shift ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done
case "$MODE" in worktree|branch) : ;; *) die "invalid --mode: $MODE (worktree|branch)" 2 ;; esac

# --- resolve target repo -----------------------------------------------------
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "not a git repository — refusing to build a sandbox that cannot be isolated" 3

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd 2>/dev/null)" || TEMPLATES_DIR=""

LT="$TOP/docs/looptesting"
SB="$LT/.sandbox"
MARKER="$SB/ownership.env"

seed_dirs_and_templates() {
  mkdir -p "$LT/runs" "$LT/decisions" "$SB"
  [ -f "$LT/.pids" ] || : > "$LT/.pids"
  # Arm the stop-gate sentinel: while it exists, the Stop hook refuses to end
  # the session until STATE.md reaches a terminal status. Harmless on Codex
  # (no hook mechanism). Removed by the gate itself on terminal status and by
  # sandbox-clean.sh.
  [ -f "$LT/.active" ] || : > "$LT/.active"
  if [ -n "$TEMPLATES_DIR" ]; then
    # FINAL_REPORT.md is deliberately NOT seeded here: a pre-copied template
    # reads as a (fake) final report mid-run; exit-and-report.md instantiates
    # it from templates/ only at exit time.
    for f in STATE.md PLAN.md FEATURE_MATRIX.md ISSUES.md SUGGESTIONS.md; do
      [ -f "$LT/$f" ] || { [ -f "$TEMPLATES_DIR/$f" ] && cp "$TEMPLATES_DIR/$f" "$LT/$f"; }
    done
  fi
}

# --- idempotent short-circuit: already initialized ---------------------------
# BUT if the marker records a worktree that a prior sandbox-clean removed, the
# sandbox lost its isolation — re-seeding alone would hand back a phantom
# "initialized" sandbox with NO isolated worktree, so the loop would run against
# (and commit into) the main tree (audit B2). In that case rebuild instead: drop
# the stale marker and fall through to full init, which re-adds the worktree on
# the (kept) qa branch. A live worktree, or branch-mode (no worktree), short-circuits.
if [ -f "$MARKER" ]; then
  RECORDED_WT="$(grep -E '^CREATED_WORKTREE=' "$MARKER" 2>/dev/null | head -1 | cut -d= -f2-)"
  if [ -n "$RECORDED_WT" ] \
     && ! git -C "$TOP" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $RECORDED_WT"; then
    echo "sandbox-setup: recorded worktree is gone ($RECORDED_WT) — rebuilding isolation on the qa branch."
    [ -z "$WT_PATH" ] && WT_PATH="$RECORDED_WT"
    rm -f "$MARKER"
  else
    seed_dirs_and_templates   # re-create only files the user may have deleted
    echo "sandbox-setup: already initialized (marker present); left existing state untouched."
    exit 0
  fi
fi

# --- isolation guard ---------------------------------------------------------
DIRTY=0
[ -n "$(git -C "$TOP" status --porcelain 2>/dev/null)" ] && DIRTY=1
if [ "$MODE" = "branch" ] && [ "$DIRTY" -eq 1 ] && [ "$ALLOW_DIRTY" -eq 0 ]; then
  die "working tree not clean — refusing branch-mode sandbox to avoid touching uncommitted user changes (use --mode worktree to isolate, or --allow-dirty to override)" 4
fi

BASELINE_HEAD="$(git -C "$TOP" rev-parse HEAD 2>/dev/null || echo '')"

# --- baseline tag (own it only if we create it) ------------------------------
CREATED_TAG=""
if [ -n "$BASELINE_HEAD" ]; then
  if git -C "$TOP" rev-parse -q --verify "refs/tags/$BASELINE_TAG" >/dev/null 2>&1; then
    :  # pre-existing tag — not ours to remove
  else
    git -C "$TOP" tag "$BASELINE_TAG" >/dev/null 2>&1 && CREATED_TAG="$BASELINE_TAG"
  fi
fi

# --- branch / worktree -------------------------------------------------------
CREATED_BRANCH=""
CREATED_WORKTREE=""
branch_exists=0
git -C "$TOP" rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null 2>&1 && branch_exists=1

if [ "$MODE" = "branch" ]; then
  if [ "$branch_exists" -eq 1 ]; then
    git -C "$TOP" switch "$BRANCH" >/dev/null 2>&1 || die "failed to switch to existing branch $BRANCH" 5
  else
    git -C "$TOP" switch -c "$BRANCH" >/dev/null 2>&1 || die "failed to create branch $BRANCH" 5
    CREATED_BRANCH="$BRANCH"
  fi
else
  # worktree mode
  if [ -z "$WT_PATH" ]; then
    WT_PATH="$(dirname "$TOP")/$(basename "$TOP")-qa-loop"
  fi
  if [ -e "$WT_PATH" ]; then
    die "worktree path already exists: $WT_PATH (pass --worktree-path to choose another)" 6
  fi
  if [ "$branch_exists" -eq 1 ]; then
    git -C "$TOP" worktree add "$WT_PATH" "$BRANCH" >/dev/null 2>&1 \
      || die "failed to add worktree at $WT_PATH for existing branch $BRANCH" 6
  else
    git -C "$TOP" worktree add -b "$BRANCH" "$WT_PATH" >/dev/null 2>&1 \
      || die "failed to add worktree at $WT_PATH" 6
    CREATED_BRANCH="$BRANCH"
  fi
  CREATED_WORKTREE="$WT_PATH"
fi

# --- evidence dir + templates ------------------------------------------------
seed_dirs_and_templates
git -C "$TOP" status --porcelain > "$SB/git-status-baseline.txt" 2>/dev/null || true

# --- ownership marker (parsed, never sourced, by sandbox-clean.sh) -----------
{
  echo "SANDBOX_VERSION=1"
  echo "MODE=$MODE"
  echo "TOP=$TOP"
  echo "CREATED_BRANCH=$CREATED_BRANCH"
  echo "CREATED_TAG=$CREATED_TAG"
  echo "CREATED_WORKTREE=$CREATED_WORKTREE"
  echo "CREATED_LOOPTESTING_DIR=true"
  echo "BASELINE_HEAD=$BASELINE_HEAD"
  echo "SETUP_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$MARKER"

echo "sandbox-setup: ready (mode=$MODE, branch=$BRANCH, baseline=$BASELINE_TAG)."
[ -n "$CREATED_WORKTREE" ] && echo "  worktree: $CREATED_WORKTREE"
echo "  evidence: $LT"
exit 0
