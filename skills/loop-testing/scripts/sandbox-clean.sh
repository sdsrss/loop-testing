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
#                    the owned qa branch. The evidence dir is KEPT, and named, in
#                    four cases: the marker records that the sandbox only re-used
#                    a directory the user already had; the marker predates that
#                    field being measured; the field says the question was never
#                    answered (an upgraded sandbox lands here); or a worktree this
#                    run could not claim is still registered and the marker is the
#                    only record of it. The branch is deleted only when it has
#                    no fix commits beyond the recorded baseline OR
#                    --discard-fixes is given — fix commits exist ONLY on that
#                    branch, so harvest them (merge / cherry-pick) first.
#                    Refuses (exit 3) without an ownership marker or a terminal
#                    STATE. Default behavior without --purge is unchanged.
#
# Exit codes: 0 cleaned (or nothing to clean) · 1 internal abort (re-anchored to
# the main tree but cannot cd there — applies to both plain clean and --purge) ·
# 2 usage error · 3 --purge refused (no marker / non-terminal STATE) · 4 --purge
# ran but stopped short: a worktree it could not claim is still registered, so
# the evidence dir and its marker were kept. Resolve that worktree and re-run.
set -u

echo_info() { echo "sandbox-clean: $*"; }

PURGE=0
DISCARD_FIXES=0
# Print the header block as the help text (same mechanism as install-codex.sh):
# one source of truth, so usage and exit codes cannot drift from the comment that
# documents them.
usage() { sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# --help is handled in its own pass, BEFORE the parse loop, so it wins over
# --purge on the same line and can never reach the destructive path.
for _a in "$@"; do
  case "$_a" in -h|--help) usage; exit 0 ;; esac
done

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

# Present is not the same as readable. Every field below is read with `mval`
# (grep '^KEY=' | cut), so a truncated or corrupted marker returns EMPTY for every
# key — and empty CREATED_BRANCH / CREATED_TAG / CREATED_WORKTREE is
# indistinguishable from "this run created nothing". That made --purge print
# "purge done." and exit 0 over a sandbox whose branch, tag, worktree and evidence
# dir were all still there. An unreadable marker is strictly LESS knowable than a
# missing one, so it refuses at least as loudly.
#
# Validity = the three keys every marker version has written since v0.1.2:
# SANDBOX_VERSION (numeric), MODE and TOP. Deliberately not a whole-file schema —
# v1 markers legitimately lack ADOPTED_*/UNCLAIMED_WORKTREE/WORKTREE_STAMP, and
# rejecting those would strand every sandbox created before v0.10.0.
marker_key() { grep -aE "^$1=[^[:space:]]" "$MARKER" 2>/dev/null | head -1 | cut -d= -f2-; }
M_VER="$(marker_key SANDBOX_VERSION)"
M_MODE="$(marker_key MODE)"
M_TOP="$(marker_key TOP)"
marker_bad=""
case "$M_VER" in ''|*[!0-9]*) marker_bad="SANDBOX_VERSION" ;; esac
[ -n "$M_MODE" ] || marker_bad="${marker_bad:+$marker_bad, }MODE"
[ -n "$M_TOP" ]  || marker_bad="${marker_bad:+$marker_bad, }TOP"
if [ -n "$marker_bad" ]; then
  if [ "$PURGE" = 1 ]; then
    echo_info "--purge refused: the ownership marker at $MARKER is unreadable (missing or malformed: $marker_bad) — this run cannot tell what it owns, so it is deleting nothing. Inspect that file; if the sandbox is finished and you recognise the leftovers, remove them by hand per the README cleanup section."
    exit 3
  fi
  echo_info "the ownership marker at $MARKER is unreadable (missing or malformed: $marker_bad) — fail-closed: deleting nothing."
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
SANDBOX_BRANCH="$(mval SANDBOX_BRANCH)"
WORKTREE_STAMP="$(mval WORKTREE_STAMP)"

# --- worktree identity (mirrors sandbox-setup.sh) ----------------------------
# A path is not an identity: after a clean the path is free again, so what stands
# there now may be the user's. sandbox-setup stamps a nonce inside the worktree's
# own git admin dir, which git removes together with the worktree.

# Absolute git dir of the worktree at $1 — empty when it is not a readable worktree.
wt_gitdir_of() {
  local d
  d="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)"
  if [ -z "$d" ]; then   # --absolute-git-dir needs git >= 2.13
    d="$(git -C "$1" rev-parse --git-dir 2>/dev/null)"
    case "$d" in ''|/*) : ;; *) d="$1/$d" ;; esac
  fi
  printf '%s' "$d"
}

# Prints exactly one of: absent | legacy | ours | foreign | unknown.
# "cannot tell" is its own answer and never means "delete it". An earlier version
# collapsed a detached HEAD, a missing text tool and a genuine stranger into a
# single verdict, which stranded the sandbox's own worktree.
wt_ownership() {
  local p="$1" want="$2" gd got list nl   # $3 (recorded branch) is no longer consulted
  # Builtins only from here down. The first version parsed `git worktree list`
  # with awk, so a missing awk read as "not ours"; swapping awk for `cat` only
  # moved that hole. Any external command on this path can fail, and a failed
  # command must never be mistaken for an ownership verdict — so there are none.
  nl='
'
  list="$(git -C "$TOP" worktree list --porcelain 2>/dev/null)$nl"
  case "$nl$list" in
    *"${nl}worktree $p${nl}"*) : ;;
    *) printf 'absent'; return ;;
  esac
  # Registered, but the directory is gone. This is the one case where ownership
  # does not matter: there is nothing on disk to lose, and leaving the phantom
  # registration in place blocks the next setup from reusing the branch.
  [ -d "$p" ] || { printf 'stale'; return; }
  [ -n "$want" ] || { printf 'legacy'; return; }
  gd="$(wt_gitdir_of "$p")"
  [ -n "$gd" ] || { printf 'unknown'; return; }
  if [ -f "$gd/loop-testing-owner" ]; then
    got=""
    if IFS= read -r got < "$gd/loop-testing-owner" 2>/dev/null; then
      if [ "$got" = "$want" ]; then printf 'ours'; else printf 'foreign'; fi
    else
      printf 'unknown'   # present but unreadable — still not a verdict
    fi
    return
  fi
  # No stamp file, but the marker records one. For OUR worktree that cannot
  # happen: setup clears WORKTREE_STAMP when the stamp write fails, so a recorded
  # stamp means the file WAS written into that worktree's admin dir, which git
  # deletes only together with the worktree. So the only thing reaching here is a
  # different worktree standing at the recorded path.
  #
  # A branch-name fallback used to live here — "if HEAD is on the recorded
  # branch, call it ours". It could never help our own worktree (that case
  # returns `legacy` above), and it fired on exactly the workflow this tool tells
  # users to perform: clean KEEPS qa/loop-testing because the fix commits exist
  # only there, so harvesting them means adding a worktree on that branch — and
  # the fallback then called the user's checkout ours and force-removed it.
  printf 'foreign'
}

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
    # `kill 0` signals EVERY process in the sender's own process group — the agent
    # session, the unattended driver, sibling jobs — so a 0 here would take down
    # the run mid-cleanup, before the worktree is ever removed; `kill 1` targets
    # init. Neither can be a service this run started. .pids is written by the
    # agent from parsed `lsof -t -i :PORT` / `ss -ltnp` output, so a stray 0 is a
    # parse artifact, not a hypothesis. Compare the VALUE, not the shape: "00" is
    # numeric and still means the group, while "0000123" is a real PID to stop.
    norm=$pid
    while [ "${#norm}" -gt 1 ]; do
      case "$norm" in 0*) norm=${norm#0} ;; *) break ;; esac
    done
    case "$norm" in
      0|1) echo_info "refusing to signal PID $pid from .pids (0 would signal this whole process group, 1 is init)"
           continue ;;
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
WT_KEPT=0   # set when the worktree was deliberately left standing
if [ -n "$CREATED_WORKTREE" ]; then
  # Guard against ever removing the repo itself, / or $HOME.
  case "$CREATED_WORKTREE" in
    ""|"/"|"$HOME"|"$TOP")
      echo_info "refusing to remove suspicious worktree path: $CREATED_WORKTREE" ;;
    *)
      WT_STATE="$(wt_ownership "$CREATED_WORKTREE" "$WORKTREE_STAMP" "$SANDBOX_BRANCH")"
      case "$WT_STATE" in
        absent)
          echo_info "worktree already gone: $CREATED_WORKTREE" ;;
        stale)
          # Directory deleted by hand, registration left behind. Nothing to lose,
          # and leaving it registered keeps the qa branch checked out so the next
          # setup cannot reuse it.
          # Scoped removal, NEVER `git worktree prune`: prune takes no path and
          # drops every prunable registration in the repo, answering a per-path
          # verdict with a repo-wide remedy. A user who relocated their own
          # worktree with a plain `mv` — the state `git worktree repair` exists
          # to fix — would lose its admin dir and be unable to repair it.
          #
          # The race the earlier verdict cannot rule out is handled by re-testing
          # here, immediately before the call, rather than by widening the blast
          # radius: if the directory came back, leave it alone and say so.
          #
          # UNTESTED BY CONSTRUCTION: the window between wt_ownership's [ -d ]
          # and this one cannot be entered from outside the process, so no test
          # here can tell this re-test from its absence. A test that recreates
          # the directory beforehand exercises the `unknown` arm instead — it
          # passes either way, which is why one was written and then deleted
          # rather than left standing as coverage it does not provide.
          if [ -d "$CREATED_WORKTREE" ]; then
            echo_info "kept worktree $CREATED_WORKTREE — its directory reappeared after this run judged it gone, so it will not be force-removed"
            WT_KEPT=1
          elif git -C "$TOP" worktree remove --force "$CREATED_WORKTREE" >/dev/null 2>&1; then
            echo_info "removed worktree $CREATED_WORKTREE (its directory was already gone)"
          else
            echo_info "could not clear the stale registration for $CREATED_WORKTREE (locked, or git refused) — it is still registered"
            WT_KEPT=1
          fi ;;
        foreign)
          # Removal is --force: uncommitted AND untracked work would go with it.
          echo_info "kept worktree $CREATED_WORKTREE — it is not this sandbox's (its ownership stamp does not match), so this run will not remove it" ;;
        unknown)
          echo_info "kept worktree $CREATED_WORKTREE — this run could not confirm it belongs to this sandbox and will not force-remove a worktree it cannot identify; if it is the sandbox's, remove it with 'git worktree remove --force $CREATED_WORKTREE' — check it first, --force discards anything uncommitted or untracked in there" ;;
        legacy)
          # Marker predates ownership stamping, so nothing here records which
          # worktree this sandbox created. The pre-stamp behavior was to remove
          # whatever stood at the recorded path — the original data-loss bug,
          # still armed for every sandbox that already exists. No identity
          # recorded is not permission.
          echo_info "kept worktree $CREATED_WORKTREE — its ownership marker predates worktree stamping, so this run cannot tell it from one of yours; if it is the sandbox's, remove it with 'git worktree remove --force $CREATED_WORKTREE' — check it first, --force discards anything uncommitted or untracked in there" ;;
        *)  # ours
          if git -C "$TOP" worktree remove --force "$CREATED_WORKTREE" >/dev/null 2>&1; then
            echo_info "removed worktree $CREATED_WORKTREE"
          else
            # Still standing, and it is OURS — so this teardown did not finish.
            # Every other outcome that leaves a worktree marks the purge partial;
            # this one did not, so purge deleted the marker, said "purge done."
            # and exited 0 with a worktree this tool created still on disk.
            echo_info "could not remove worktree via git; leaving it in place: $CREATED_WORKTREE"
            WT_KEPT=1
          fi ;;
      esac
      case "$WT_STATE" in foreign|unknown|legacy) WT_KEPT=1 ;; esac ;;
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
  # Refs a PRIOR lifecycle created and this one only re-used. Ownership is recorded
  # by name, so the ref standing there now may be the user's own — never delete an
  # adopted ref, just say it is there and what is on it.
  P_ADOPT_BRANCH="$(mval ADOPTED_BRANCH)"
  P_ADOPT_TAG="$(mval ADOPTED_TAG)"
  # Same question for the evidence dir: did this lifecycle line create it, or did
  # the user already keep files under docs/looptesting/? Read it before the purge
  # below can delete the marker along with the dir.
  P_CREATED_LT="$(mval CREATED_LOOPTESTING_DIR)"
  # CREATED_LOOPTESTING_DIR only carries information from marker version 2 on:
  # v1 wrote a constant `true`, over a directory the user already owned included.
  # Trusting a v1 `true` would leave every sandbox created before v0.10.0 exactly
  # as exposed as before, which is the population the fix exists for.
  P_SBX_VER="$(mval SANDBOX_VERSION)"
  # Digit-count first: the marker is user-editable, and `[ huge -ge 2 ]` prints a
  # raw "integer expression expected" at whoever ran purge. 3+ digits is >= 100.
  case "$P_SBX_VER" in
    ''|*[!0-9]*) LT_FIELD_TRUSTED=0 ;;
    ?|??) if [ "$P_SBX_VER" -ge 2 ]; then LT_FIELD_TRUSTED=1; else LT_FIELD_TRUSTED=0; fi ;;
    *)    LT_FIELD_TRUSTED=1 ;;
  esac
  kept_branch=""
  adopted_note=""

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
        # Needs git >= 2.7 for `for-each-ref --contains`; older git prints nothing
        # (stderr suppressed) and falls through to the conservative wording below,
        # so the degradation is graceful rather than a failure.
        # Merging (or pushing) does not move the qa tip, but it does make that tip
        # reachable from the other ref — so a COMPLETED harvest is detectable, and
        # a user who just merged must not be told to go harvest again. The branch
        # is still KEPT either way: deleting commits stays the user's explicit
        # call. A cherry-pick harvest rewrites the commits, so it does not match
        # here and falls back to the conservative advice.
        # Exclude the branch's OWN mirrors: `git push origin qa/loop-testing` as a
        # backup lists origin/qa/loop-testing here, and calling that a completed
        # harvest invites --discard-fixes on commits that exist nowhere else. Also
        # drop the bare `origin` that refs/remotes/origin/HEAD shortens to. The -F
        # suffix match is deliberately broad: a false "not harvested" only keeps a
        # branch, while a false "harvested" loses commits.
        harvested_by="$(git -C "$TOP" for-each-ref --contains "refs/heads/$P_BRANCH" \
          --format='%(refname:short)' refs/heads refs/tags refs/remotes 2>/dev/null \
          | grep -vxF "$P_BRANCH" | grep -vF "/$P_BRANCH" | grep -vxF origin | head -1)"
        if [ -n "$harvested_by" ]; then
          # State the observation, not a verdict: a remote-tracking ref is a local
          # cache that may be stale, and another branch cut from the same tip also
          # satisfies --contains. Reachability is evidence the user can check, not
          # proof the harvest is done.
          kept_branch="$P_BRANCH (holds $fixes fix commit(s); the tip is also reachable from '$harvested_by' — if that is where you harvested them, re-run with --purge --discard-fixes to drop the branch)"
        else
          kept_branch="$P_BRANCH (holds $fixes fix commit(s) beyond the baseline — harvest them first, or re-run with --purge --discard-fixes)"
        fi
      else
        kept_branch="$P_BRANCH (baseline unverifiable, fix commits unknown — harvest first, or re-run with --purge --discard-fixes)"
      fi
    fi
  fi

  # --- adopted refs: report, never delete -------------------------------------
  if [ -n "$P_ADOPT_BRANCH" ] \
     && git -C "$TOP" rev-parse -q --verify "refs/heads/$P_ADOPT_BRANCH" >/dev/null 2>&1; then
    a_n=-1
    if [ -n "$P_BASE" ] && git -C "$TOP" rev-parse -q --verify "$P_BASE^{commit}" >/dev/null 2>&1; then
      a_n="$(git -C "$TOP" rev-list --count "$P_BASE..refs/heads/$P_ADOPT_BRANCH" 2>/dev/null)"
      case "$a_n" in ''|*[!0-9]*) a_n=-1 ;; esac
    fi
    if [ "$a_n" -ge 0 ] 2>/dev/null; then
      adopted_note="$P_ADOPT_BRANCH (re-used by this run, not created by it — holds $a_n commit(s) beyond the baseline; purge never deletes an adopted ref, so remove it by hand once you have harvested)"
    else
      adopted_note="$P_ADOPT_BRANCH (re-used by this run, not created by it; purge never deletes an adopted ref, so remove it by hand once you have harvested)"
    fi
  fi
  if [ -n "$P_ADOPT_TAG" ] \
     && git -C "$TOP" rev-parse -q --verify "refs/tags/$P_ADOPT_TAG" >/dev/null 2>&1; then
    echo_info "purge: kept tag $P_ADOPT_TAG (re-used by this run, not created by it)"
  fi
  # A worktree a rebuild walked away from. Not ours to delete, but naming it is
  # the difference between "left standing" and "invisible forever".
  P_UNCLAIMED_WT="$(mval UNCLAIMED_WORKTREE)"
  if [ -n "$P_UNCLAIMED_WT" ] && [ -e "$P_UNCLAIMED_WT" ]; then
    echo_info "purge: kept worktree $P_UNCLAIMED_WT (a rebuild could not claim it and built elsewhere; it was never this sandbox's to remove)"
  fi

  LT_DIR="$TOP/docs/looptesting"
  # A worktree a rebuild walked away from counts too: the marker is the only
  # place its path is written down, so deleting the marker would un-name it.
  if [ -n "$P_UNCLAIMED_WT" ] && [ -e "$P_UNCLAIMED_WT" ]; then WT_KEPT=1; fi
  if [ "$WT_KEPT" = 1 ]; then
    # The worktree stage left a worktree standing that it could not claim. The
    # marker in here is the only thing on disk that still ties that path to this
    # tool, so deleting it would turn a recoverable situation into a registered
    # worktree nothing can identify — the orphan the fail-closed design exists to
    # prevent. Resolve the worktree first; purge again afterwards.
    echo_info "purge: kept evidence dir $LT_DIR — a worktree this run could not claim is still registered at $CREATED_WORKTREE, and the marker here is the only record that can identify it; deal with that worktree first, then purge again"
  elif [ "$LT_FIELD_TRUSTED" = 0 ]; then
    # Say only what is known. The marker predates the field being measured, so
    # this run cannot tell a directory it created from one the user already kept
    # notes in — and an untracked file is gone for good if it guesses wrong.
    echo_info "purge: kept evidence dir $LT_DIR (its ownership marker was written by an older version that could not record whether the directory existed beforehand, so this run will not delete it — remove it by hand if everything in it is the sandbox's)"
  elif [ "$P_CREATED_LT" = false ]; then
    # Measured as adopted: the user was already keeping files here, and an
    # untracked one is gone for good. Report it, never delete it — the rule this
    # block already applies to adopted refs.
    echo_info "purge: kept evidence dir $LT_DIR (re-used by this run, not created by it — it also holds files that were already yours; remove it by hand once you have taken what you want)"
  elif [ "$P_CREATED_LT" != true ]; then
    # Recorded as unknown, or missing/garbled. Say that, and nothing more: the
    # neighbouring branch's wording would assert user files that nobody ever
    # observed.
    echo_info "purge: kept evidence dir $LT_DIR (this run could not determine whether the directory existed before the sandbox did — remove it by hand if everything in it is the sandbox's)"
  else
    case "$LT_DIR" in
      */docs/looptesting)
        rm -rf "$LT_DIR"
        echo_info "purge: removed evidence dir $LT_DIR (marker included)" ;;
      *)
        echo_info "purge: refusing to remove suspicious evidence path: $LT_DIR" ;;
    esac
  fi

  # A purge that left the worktree standing has NOT finished — it still deleted
  # the baseline tag on the way through, so reporting a plain "done" describes a
  # partial run as a complete one and leaves the user with no reason to come back.
  if [ "$WT_KEPT" = 1 ]; then
    PURGE_VERB="purge incomplete: the worktree above is still there, so this run stopped short of removing everything it owns. Deal with that worktree, then run --purge again."
    PURGE_EXIT=4
  else
    PURGE_VERB="purge done."
    PURGE_EXIT=0
  fi
  if [ -n "$kept_branch" ]; then
    echo_info "$PURGE_VERB KEPT branch: $kept_branch"
  elif [ -n "$adopted_note" ]; then
    echo_info "$PURGE_VERB KEPT branch: $adopted_note"
  else
    echo_info "$PURGE_VERB"
  fi
  exit "${PURGE_EXIT:-0}"
fi

if [ "$WT_KEPT" = 1 ]; then
  echo_info "done. Kept: the worktree named above, the qa branch, baseline tag, docs/looptesting/ evidence."
else
  echo_info "done. Kept: qa branch, baseline tag, docs/looptesting/ evidence."
fi
exit 0
