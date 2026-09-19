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
#
# Exit codes: 0 ready (or already initialized) · 2 usage error · 3 not a git repo
# · 4 dirty tree in branch mode · 5 branch switch/create failed · 6 worktree add
# failed (or path taken) · 7 branch-mode sandbox is on another branch · 8 the
# evidence dir could not be created/written (refused before touching git).
set -u

MODE="worktree"
BRANCH="qa/loop-testing"
BASELINE_TAG="qa-baseline"
WT_PATH=""
ALLOW_DIRTY=0

# Directories the preflight created. A refusal must leave none of them behind:
# sandbox-clean is fail-closed without a marker, so nothing else would ever remove
# them from the user's repo. Flags (not a path list) so a path with spaces is safe,
# and rmdir (not rm -rf) so anything that ended up inside is never destroyed.
MADE_DOCS=0; MADE_LT=0; MADE_RUNS=0; MADE_DECISIONS=0; MADE_SB=0
# Flips to 1 as soon as this run creates a git artifact (tag / branch / worktree).
# Past that point a refusal cannot clean up completely anyway, and rolling back
# only the still-empty dirs would leave a half-built evidence tree — worse than
# leaving it whole for the re-run to reuse.
GIT_TOUCHED=0

# die <message> [exit-code] — "$1", not "$*": the code is an argument, not text.
die() {
  echo "sandbox-setup: $1" >&2
  if [ "$GIT_TOUCHED" = 0 ]; then
    # Innermost first; each guard is only ever 1 after a non-`-p` mkdir SUCCEEDED,
    # i.e. the dir did not exist, and rmdir refuses a non-empty one — so a
    # pre-existing user directory is never removed.
    [ "$MADE_SB" = 1 ]        && rmdir "$SB"            2>/dev/null
    [ "$MADE_DECISIONS" = 1 ] && rmdir "$LT/decisions"  2>/dev/null
    [ "$MADE_RUNS" = 1 ]      && rmdir "$LT/runs"       2>/dev/null
    [ "$MADE_LT" = 1 ]        && rmdir "$LT"            2>/dev/null
    [ "$MADE_DOCS" = 1 ]      && rmdir "$TOP/docs"      2>/dev/null
  fi
  exit "${2:-1}"
}

# Value-taking flags fail closed on a missing value (audit DR-10) — a dangling
# trailing flag must never silently fall back to the computed default and proceed.
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)          [ $# -ge 2 ] || die "missing value for --mode" 2;          MODE="$2"; shift; shift ;;
    --worktree-path) [ $# -ge 2 ] || die "missing value for --worktree-path" 2; WT_PATH="$2"; shift; shift ;;
    --branch)        [ $# -ge 2 ] || die "missing value for --branch" 2;        BRANCH="$2"; shift; shift ;;
    --baseline-tag)  [ $# -ge 2 ] || die "missing value for --baseline-tag" 2;  BASELINE_TAG="$2"; shift; shift ;;
    --allow-dirty)   ALLOW_DIRTY=1; shift ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done
case "$MODE" in worktree|branch) : ;; *) die "invalid --mode: $MODE (worktree|branch)" 2 ;; esac

# --- resolve target repo -----------------------------------------------------
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "not a git repository — refusing to build a sandbox that cannot be isolated" 3

# --- re-anchor when invoked from inside a linked worktree (audit NEW-1 / R57) --
# From inside the qa worktree, --show-toplevel is the WORKTREE: the marker lives
# in the MAIN tree, so the idempotent short-circuit below would miss it, fall
# through to full init, and try to nest a second `<wt>-qa-loop` worktree (git
# refuses — branch already checked out — and the exit-6 message misleads).
# Re-anchor to the main tree so a resume from the worktree cwd short-circuits
# like any other resume. Validation failure keeps the original TOP untouched.
GD="$(git rev-parse --git-dir 2>/dev/null)"
GCD="$(git rev-parse --git-common-dir 2>/dev/null)"
if [ -n "$GCD" ] && [ "$GD" != "$GCD" ]; then
  case "$GCD" in /*) : ;; *) GCD="$(cd "$GCD" 2>/dev/null && pwd)" ;; esac
  MAIN_TOP="$(git -C "$(dirname "$GCD")" rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$MAIN_TOP" ] && [ "$MAIN_TOP" != "$TOP" ] && [ -d "$MAIN_TOP" ]; then
    echo "sandbox-setup: invoked from inside a linked worktree — re-anchoring to the main tree: $MAIN_TOP"
    TOP="$MAIN_TOP"
    cd "$TOP" || die "cannot cd to re-anchored main tree $TOP" 3
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd 2>/dev/null)" || TEMPLATES_DIR=""

LT="$TOP/docs/looptesting"
SB="$LT/.sandbox"
MARKER="$SB/ownership.env"

# Preflight: the evidence dir IS the sandbox contract — the ownership marker
# (sandbox-clean removes only what it records), the .active sentinel (arms the
# stop-gate) and STATE.md (resume) all live there. Every write below used to be
# unchecked, so an unwritable docs/ (read-only mount, root-owned dir, full disk,
# quota) still printed "ready" and exited 0 while leaving a branch/worktree/tag
# that no cleanup could claim and a silently disarmed gate. Verify writability
# BEFORE touching git, so a refusal leaves nothing behind.
require_writable_evidence_dir() {
  # Create each level ourselves, so we know exactly what to drop again on a refusal.
  [ -d "$TOP/docs" ]     || { mkdir "$TOP/docs"     2>/dev/null && MADE_DOCS=1; }
  [ -d "$LT" ]           || { mkdir "$LT"           2>/dev/null && MADE_LT=1; }
  [ -d "$LT/runs" ]      || { mkdir "$LT/runs"      2>/dev/null && MADE_RUNS=1; }
  [ -d "$LT/decisions" ] || { mkdir "$LT/decisions" 2>/dev/null && MADE_DECISIONS=1; }
  [ -d "$SB" ]           || { mkdir "$SB"           2>/dev/null && MADE_SB=1; }
  # Probe EVERY dir the sandbox writes into, not just .sandbox: a writable
  # .sandbox under a read-only docs/looptesting passed a .sandbox-only probe and
  # moved the failure to seed time — after the tag, branch and worktree existed.
  for d in "$LT" "$LT/runs" "$LT/decisions" "$SB"; do
    [ -d "$d" ] \
      || die "cannot create the evidence dir $d — refusing a sandbox whose state (ownership marker, .active sentinel, STATE.md) could not be recorded" 8
    # Sweep probes from an interrupted earlier run first: a leftover one that is
    # not owner-writable would otherwise false-refuse forever. The sweep is broad
    # and CAN remove a concurrent run's in-flight probe — harmless, because a
    # writer never re-reads its own probe, so a swept probe cannot cause a false
    # refusal. The per-PID name below is for attribution, not mutual exclusion.
    rm -f "$d"/.write-probe* 2>/dev/null
    # Write a BYTE, not just truncate: creating a zero-length file succeeds on a
    # full filesystem, so an empty probe would pass ENOSPC straight through to
    # the marker write — i.e. after the git artifacts already exist.
    ( printf 'x' > "$d/.write-probe.$$" ) 2>/dev/null \
      || die "evidence dir $d is not writable (or the filesystem is full) — refusing a sandbox whose state (ownership marker, .active sentinel, STATE.md) could not be recorded" 8
    rm -f "$d/.write-probe.$$"
  done
}

seed_dirs_and_templates() {
  mkdir -p "$LT/runs" "$LT/decisions" "$SB" \
    || die "cannot create the evidence dirs under $LT — refusing a sandbox whose state could not be recorded" 8
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

require_writable_evidence_dir

# --- idempotent short-circuit: already initialized ---------------------------
# BUT if the marker records a worktree that a prior sandbox-clean removed, the
# sandbox lost its isolation — re-seeding alone would hand back a phantom
# "initialized" sandbox with NO isolated worktree, so the loop would run against
# (and commit into) the main tree (audit B2). In that case rebuild instead: drop
# the stale marker and fall through to full init, which re-adds the worktree on
# the (kept) qa branch. A live worktree, or branch-mode (no worktree), short-circuits.
PRIOR_CREATED_BRANCH=""
PRIOR_CREATED_TAG=""
ADOPTED_BRANCH=""
ADOPTED_TAG=""
if [ -f "$MARKER" ]; then
  RECORDED_WT="$(grep -E '^CREATED_WORKTREE=' "$MARKER" 2>/dev/null | head -1 | cut -d= -f2-)"
  if [ -n "$RECORDED_WT" ] \
     && ! git -C "$TOP" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $RECORDED_WT"; then
    echo "sandbox-setup: recorded worktree is gone ($RECORDED_WT) — rebuilding isolation on the qa branch."
    [ -z "$WT_PATH" ] && WT_PATH="$RECORDED_WT"
    # Carry ownership across the marker rebuild: sandbox-clean deliberately KEEPS
    # the qa branch and baseline tag, so re-deriving ownership below from "does
    # this ref exist now" would record neither — orphaning artifacts this sandbox
    # created beyond --purge's reach, and silencing its harvest warning.
    PRIOR_CREATED_BRANCH="$(grep -E '^CREATED_BRANCH=' "$MARKER" 2>/dev/null | head -1 | cut -d= -f2-)"
    PRIOR_CREATED_TAG="$(grep -E '^CREATED_TAG=' "$MARKER" 2>/dev/null | head -1 | cut -d= -f2-)"
    # Adoption must be transitive. After the first rebuild the marker records
    # CREATED_BRANCH= (empty) + ADOPTED_BRANCH=…, so reading only CREATED_* would
    # find nothing to carry on the NEXT rebuild and purge would fall silent again.
    [ -n "$PRIOR_CREATED_BRANCH" ] \
      || PRIOR_CREATED_BRANCH="$(grep -E '^ADOPTED_BRANCH=' "$MARKER" 2>/dev/null | head -1 | cut -d= -f2-)"
    [ -n "$PRIOR_CREATED_TAG" ] \
      || PRIOR_CREATED_TAG="$(grep -E '^ADOPTED_TAG=' "$MARKER" 2>/dev/null | head -1 | cut -d= -f2-)"
    rm -f "$MARKER"
  else
    # Branch-mode re-verify (audit DR-9): the user may have switched branches
    # since setup; handing back "already initialized" would let the loop run
    # (and commit) on whatever branch is checked out. Worktree mode needs no
    # check — its isolation is the worktree itself, verified above.
    RECORDED_MODE="$(grep -E '^MODE=' "$MARKER" 2>/dev/null | head -1 | cut -d= -f2-)"
    if [ "$RECORDED_MODE" = "branch" ]; then
      # Only re-verify against the branch the marker ACTUALLY recorded. A legacy
      # marker (written before SANDBOX_BRANCH existed) has no recorded branch, so
      # the sandbox's branch is unknown — guessing the invocation default and
      # refusing would break a valid custom-branch sandbox with wrong advice
      # (and could false-pass onto the wrong branch). Skip the check for legacy
      # markers; new sandboxes always record SANDBOX_BRANCH so they are covered.
      want="$(grep -E '^SANDBOX_BRANCH=' "$MARKER" 2>/dev/null | head -1 | cut -d= -f2-)"
      if [ -n "$want" ]; then
        # `branch --show-current` needs git >= 2.22; symbolic-ref is the portable
        # equivalent — empty + nonzero on detached HEAD, exactly like --show-current
        # — so older git can't misread a valid branch as detached and false-refuse.
        cur="$(git -C "$TOP" symbolic-ref --short -q HEAD 2>/dev/null)"
        if [ "$cur" != "$want" ]; then
          die "branch-mode sandbox lives on '$want' but the tree is on '${cur:-<detached>}' — run 'git switch $want' (or sandbox-clean + re-setup); refusing a sandbox that would commit onto the wrong branch" 7
        fi
      fi
    fi
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
    git -C "$TOP" tag "$BASELINE_TAG" >/dev/null 2>&1 && { CREATED_TAG="$BASELINE_TAG"; GIT_TOUCHED=1; }
  fi
fi

# --- branch / worktree -------------------------------------------------------
CREATED_BRANCH=""
CREATED_WORKTREE=""
branch_exists=0
git -C "$TOP" rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null 2>&1 && branch_exists=1

GIT_TOUCHED=1   # switching a branch or adding a worktree both mutate the repo
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

# --- adopt (do NOT re-claim) refs a prior lifecycle created ------------------
# A prior marker records ownership by NAME, not by ref identity. sandbox-clean
# deliberately KEEPS the qa branch and baseline tag, so between that clean and
# this rebuild the user may have deleted them and created their own refs of the
# same name — and --purge deletes what the marker calls CREATED. Re-claiming
# ownership on a name match would hand it the right to delete a user's branch
# (silently, when that branch has no commits beyond the recorded baseline).
# Record the fact as ADOPTED instead: purge reports these and never deletes them,
# so the user still learns the refs are there without the tool guessing.
[ -z "$CREATED_BRANCH" ] && [ "$PRIOR_CREATED_BRANCH" = "$BRANCH" ] && ADOPTED_BRANCH="$BRANCH"
[ -z "$CREATED_TAG" ] && [ "$PRIOR_CREATED_TAG" = "$BASELINE_TAG" ] && ADOPTED_TAG="$BASELINE_TAG"

# --- evidence dir + templates ------------------------------------------------
seed_dirs_and_templates
git -C "$TOP" status --porcelain > "$SB/git-status-baseline.txt" 2>/dev/null || true

# --- ownership marker (parsed, never sourced, by sandbox-clean.sh) -----------
{
  echo "SANDBOX_VERSION=1"
  echo "MODE=$MODE"
  echo "SANDBOX_BRANCH=$BRANCH"
  echo "TOP=$TOP"
  echo "CREATED_BRANCH=$CREATED_BRANCH"
  echo "CREATED_TAG=$CREATED_TAG"
  # Re-used by this run, not created by it — reported at purge, never deleted.
  echo "ADOPTED_BRANCH=$ADOPTED_BRANCH"
  echo "ADOPTED_TAG=$ADOPTED_TAG"
  echo "CREATED_WORKTREE=$CREATED_WORKTREE"
  echo "CREATED_LOOPTESTING_DIR=true"
  echo "BASELINE_HEAD=$BASELINE_HEAD"
  echo "SETUP_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$MARKER" || die "failed to write the ownership marker $MARKER — sandbox-clean could not claim what this run just created; remove the worktree/branch by hand" 8
[ -s "$MARKER" ] || die "ownership marker $MARKER is empty after writing (disk full?) — sandbox-clean could not claim what this run just created" 8

echo "sandbox-setup: ready (mode=$MODE, branch=$BRANCH, baseline=$BASELINE_TAG)."
[ -n "$CREATED_WORKTREE" ] && echo "  worktree: $CREATED_WORKTREE"
echo "  evidence: $LT"
exit 0
