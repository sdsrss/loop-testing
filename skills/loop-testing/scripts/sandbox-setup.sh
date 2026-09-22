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
# The evidence dir docs/looptesting/ lives in the MAIN repo toplevel so it
# survives worktree removal at cleanup time (see sandbox-clean.sh). ONE layout
# breaks that invariant, and git is the reason: with a --separate-git-dir or bare
# repository, `git worktree list` names the GIT DIR as the main entry and nothing
# points back to a work tree, so from inside a linked worktree there is no main
# tree to find. This script then does not re-anchor (guessing "the repo that
# contains the git dir" used to build the whole sandbox in an unrelated OUTER
# repository — audit S-02), and the evidence dir is created where the script was
# invoked: inside that linked worktree. Removing that worktree takes the evidence
# with it. sandbox-clean, invoked from the same place, resolves the same path and
# tears down correctly.
#
# Usage: sandbox-setup.sh [--mode worktree|branch] [--worktree-path PATH]
#                         [--branch NAME] [--baseline-tag NAME] [--allow-dirty]
#
# Exit codes: 0 ready (or already initialized) · 2 usage error · 3 not a git repo
# · 4 dirty tree in branch mode · 5 branch switch/create failed · 6 worktree add
# failed, or its path is taken. A rebuild also stops here when something that is
# not this sandbox's stands at the recorded path: pass --worktree-path to build
# elsewhere, or clear that path yourself. --worktree-path is enough unless that
# worktree has the sandbox branch checked out, in which case git refuses the
# branch and the path must be cleared · 7 branch-mode sandbox is on
# another branch · 8 the
# evidence dir could not be created/written (refused before touching git) · 9 the
# ownership marker is present but unreadable (missing/malformed SANDBOX_VERSION /
# MODE / TOP), or its worktree-ownership verdict is one this version does not
# recognise: nothing was done — inspect docs/looptesting/.sandbox/ownership.env.
#
# git floors: 2.5 (`worktree add`), 2.7 (`worktree list --porcelain`). Everything
# newer is probed and falls back (`--absolute-git-dir` -> `--git-dir`,
# `symbolic-ref` in place of `branch --show-current`); `switch` in branch mode
# needs 2.23.
set -u

# Shared with sandbox-clean.sh: the marker readers and the worktree-identity
# verdict. Sourced rather than copied, because both scripts have to reach the
# SAME answer about the same marker and the same worktree — lib.sh's header says
# what the two hand-kept copies cost. Fail-closed: setup that cannot read its own
# helpers must not go on to decide whether a worktree is its own.
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
  echo "sandbox-setup: cannot source lib.sh beside this script — the install is incomplete." >&2
  exit 2
}
# `.` succeeding says the file PARSED, not that it is whole — see lib.sh's
# sentinel. Here the cost is the other half of S-01: a missing wt_ownership makes
# WT_STATE empty, setup announces "already initialized" and exits 0 with no
# isolation established, which round-0.md §7 tells the agent means isolation
# holds. Both halves of the pair are required in both scripts on purpose: a lib
# that lost one function is broken whether or not THIS run would have called it.
_lt_missing=""
[ "${LT_LIB_LOADED:-}" = 1 ] || _lt_missing=" the completion sentinel"
for _lt_f in mval marker_key wt_gitdir_of wt_ownership; do
  declare -F "$_lt_f" >/dev/null 2>&1 || _lt_missing="$_lt_missing ${_lt_f}()"
done
if [ -n "$_lt_missing" ]; then
  echo "sandbox-setup: lib.sh beside this script sourced but is missing:$_lt_missing — a truncated or partial install; refusing rather than reporting isolation this run cannot establish." >&2
  exit 2
fi
unset _lt_missing _lt_f _lt_self _lt_hops _lt_d
# Kept: _lt_dir is the RESOLVED script dir, and SCRIPT_DIR below must be it —
# `dirname "$0"` names a symlink's directory and echoes under CDPATH.

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
# Set to 1 only when this run itself writes the ownership breadcrumb (see below).
WROTE_BREADCRUMB=0
# Identity of this sandbox's worktree, stamped into the worktree and recorded in
# the marker. Cleared if the stamp cannot be written, so the marker never claims
# an identity that is not actually on disk.
SANDBOX_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM:-0}"
WORKTREE_STAMP="$SANDBOX_ID"

# die <message> [exit-code] — "$1", not "$*": the code is an argument, not text.
die() {
  echo "sandbox-setup: $1" >&2
  if [ "$GIT_TOUCHED" = 0 ]; then
    # Only the breadcrumb THIS run wrote: an earlier lifecycle's answer about who
    # created the dir outlives our refusal and must not be erased by it.
    [ "${WROTE_BREADCRUMB:-0}" = 1 ] && rm -f "$SB/created-dirs.env" 2>/dev/null
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
# Print the header block as the help text (same mechanism as install-codex.sh):
# one source of truth, so usage and exit codes cannot drift from the comment that
# documents them.
usage() { sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# --help is handled in its own pass, BEFORE the parse loop: it must win over any
# other flag on the line and never reach the filesystem.
for _a in "$@"; do
  case "$_a" in -h|--help) usage; exit 0 ;; esac
done

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

# Canonicalize --worktree-path now, once. `git worktree list --porcelain` prints
# absolute paths, so a relative one recorded verbatim makes every later ownership
# lookup miss: the sandbox's own live worktree reads as "absent" and clean leaks
# it while reporting success. It also resolved against two different directories
# — `[ -e ]` against cwd, `git -C "$TOP" worktree add` against the repo root.
# Done with cd/pwd rather than realpath, which is not on every BSD userland.
if [ -n "$WT_PATH" ]; then
  while :; do
    case "$WT_PATH" in
      /) break ;;
      */) WT_PATH="${WT_PATH%/}" ;;
      *) break ;;
    esac
  done
  # NOTE (user-visible): a relative path is resolved against the CURRENT DIRECTORY.
  # It used to be resolved twice and inconsistently — `[ -e ]` against cwd,
  # `git -C "$TOP" worktree add` against the repo root — so the same string could
  # name two places in one run. cwd is the reading that matches what a person
  # typing the flag means; from a subdirectory the destination differs from the
  # old repo-root anchoring.
  # Resolve against the deepest ancestor that EXISTS, then re-attach the rest
  # lexically. Two reasons for the split: `pwd -P` gives the physical path, which
  # is what `git worktree list` prints, so a symlinked parent still matches later
  # (a logical path never would); and a parent that does not exist yet stays
  # acceptable — git creates it — instead of becoming a refusal that this
  # canonicalization invented rather than found.
  _wt_rest=""
  _wt_probe="$WT_PATH"
  while [ ! -d "$_wt_probe" ]; do
    case "$_wt_probe" in /|.|"") break ;; esac
    # `--` so a path beginning with a dash is a path, not an option: without it
    # coreutils prints its own usage text and the failure is misdiagnosed.
    _wt_rest="$(basename -- "$_wt_probe")${_wt_rest:+/$_wt_rest}"
    _wt_next="$(dirname -- "$_wt_probe")"
    [ "$_wt_next" = "$_wt_probe" ] && break
    _wt_probe="$_wt_next"
  done
  _wt_base="$(cd "$_wt_probe" 2>/dev/null && pwd -P)"
  [ -n "$_wt_base" ] \
    || die "cannot resolve --worktree-path $WT_PATH: no part of it resolves to an existing directory" 2
  WT_PATH="$_wt_base${_wt_rest:+/$_wt_rest}"
  # The lexical tail can still carry `.` and `..` when the component before them
  # did not exist to be resolved physically. `git worktree list` prints resolved
  # paths, so leaving them in would make every later ownership lookup miss.
  _wt_norm=""
  _wt_ifs="$IFS"; IFS=/
  # The expansion below is unquoted on purpose — that is how it splits on "/" —
  # but an unquoted expansion is also a glob, so a segment like `READ*` would be
  # replaced by whatever happens to match in the CURRENT directory, silently
  # retargeting the sandbox. Split, do not match.
  set -f
  for _wt_seg in $WT_PATH; do
    case "$_wt_seg" in
      ''|.) : ;;
      ..)   _wt_norm="${_wt_norm%/*}" ;;
      *)    _wt_norm="$_wt_norm/$_wt_seg" ;;
    esac
  done
  set +f
  IFS="$_wt_ifs"
  WT_PATH="${_wt_norm:-/}"
fi

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
  GCD_P="$(cd "$GCD" 2>/dev/null && pwd -P)"
  # A candidate is the main tree of THIS repository only if its git-common-dir
  # is the one we started from (audit S-02). The old rule — "the repository
  # containing the parent of the common dir" — is a guess about layout, and it
  # is wrong exactly when a --separate-git-dir or a bare repository lives inside
  # another repo (a dotfiles repo in $HOME, say): the sandbox was then built in
  # the OUTER repo — its tag, branch, worktree and docs/looptesting all there.
  same_repo() {
    local c
    [ -n "$1" ] && [ -d "$1" ] || return 1
    c="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 1
    [ -n "$c" ] || return 1
    case "$c" in /*) : ;; *) c="$1/$c" ;; esac
    c="$(cd "$c" 2>/dev/null && pwd -P)"
    [ -n "$c" ] && [ -n "$GCD_P" ] && [ "$c" = "$GCD_P" ]
  }
  MAIN_TOP=""
  # First candidate: what git itself lists first — the main worktree (or the
  # bare repository, which has no tree and fails the toplevel lookup, so no
  # re-anchor happens: there is nothing to anchor to). Second: the historical
  # guess. Either one is accepted only when same_repo says so.
  for _cand in \
    "$(git -C "$TOP" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1)" \
    "$(dirname "$GCD")"; do
    [ -n "$_cand" ] || continue
    _cand_top="$(git -C "$_cand" rev-parse --show-toplevel 2>/dev/null)"
    [ -n "$_cand_top" ] || continue
    if same_repo "$_cand_top"; then MAIN_TOP="$_cand_top"; break; fi
  done
  if [ -n "$MAIN_TOP" ] && [ "$MAIN_TOP" != "$TOP" ] && [ -d "$MAIN_TOP" ]; then
    echo "sandbox-setup: invoked from inside a linked worktree — re-anchoring to the main tree: $MAIN_TOP"
    TOP="$MAIN_TOP"
    cd "$TOP" || die "cannot cd to re-anchored main tree $TOP" 3
  fi
fi

SCRIPT_DIR="$_lt_dir"
TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd 2>/dev/null)" || TEMPLATES_DIR=""

LT="$TOP/docs/looptesting"
SB="$LT/.sandbox"
MARKER="$SB/ownership.env"

# Whether docs/looptesting/ is OURS is recorded once, at the lifecycle where it
# was created, and carried forward from there. It cannot be re-derived later: a
# plain clean keeps the dir, so by the next setup it always exists, and reading
# ownership off mere presence would promote a user's adopted dir to "ours" one
# lifecycle on — the same destructive purge, only delayed. Read before anything
# below can rewrite or remove the marker.
# Only from a marker that actually measured it. SANDBOX_VERSION 1 wrote this
# field as a constant `true`, over a directory the user already owned included.
# sandbox-clean refuses to trust that value — and that refusal is worthless if
# this side reads it and re-emits it under SANDBOX_VERSION=2, which would turn an
# unmeasured constant into a fact nobody ever established.
INHERITED_CREATED_LT=""
MARKER_PRESENT_AT_START=0
[ -f "$MARKER" ] && MARKER_PRESENT_AT_START=1

# `mval` and `marker_key` come from lib.sh, which is also where the reasoning
# they encode lives — parse-never-source, the single trailing CR, and the
# validity rule that `marker_key` applies and the check just below relies on.

# Present is not the same as readable (audit S-01). sandbox-clean validates the
# marker before trusting a field; this side used to read the same file with a
# bare grep|cut and trust whatever came back — an empty CREATED_WORKTREE from a
# truncated or hand-edited marker made the resume path call the worktree "ours",
# print "already initialized", arm .active and exit 0 with no worktree at all:
# the loop then ran against, and committed into, the main tree. The rule below is
# the same one sandbox-clean applies, through the same reader: the three keys
# every marker has carried since v0.1.0 (SANDBOX_VERSION was a literal in every
# release tag, MODE is gated by its own `case … die 2`, and TOP by `|| die … 3`).
if [ -f "$MARKER" ]; then
  _mk_ver="$(marker_key SANDBOX_VERSION)"
  _mk_bad=""
  case "$_mk_ver" in ''|*[!0-9]*) _mk_bad="SANDBOX_VERSION" ;; esac
  [ -n "$(marker_key MODE)" ] || _mk_bad="${_mk_bad:+$_mk_bad, }MODE"
  [ -n "$(marker_key TOP)" ]  || _mk_bad="${_mk_bad:+$_mk_bad, }TOP"
  if [ -n "$_mk_bad" ]; then
    # Name the command that unblocks them. "See the README cleanup section" sent
    # the reader to a block about harvesting a FINISHED sandbox, which never
    # mentions the marker — the one file standing between them and a working
    # re-run.
    die "the ownership marker at $MARKER is unreadable (missing or malformed: $_mk_bad) — nothing in it can be trusted, so this run did nothing (no worktree, no sentinel, and that file is unchanged). Read it: if it describes a sandbox you still want, repair those lines; if it is finished, harvest what you need from the qa branch, then 'rm $MARKER' and re-run this script to build a fresh sandbox. Removing the marker only forfeits this tool's record of what it created — it deletes no branch, tag, worktree or evidence" 9
  fi
fi

if [ -f "$MARKER" ]; then
  MARKER_VERSION="$(mval SANDBOX_VERSION)"
  # Digit-count first: a marker can hold anything, and `[ huge -ge 2 ]` prints a
  # raw "integer expression expected" at the user. Three or more digits is >= 100.
  case "$MARKER_VERSION" in
    ''|*[!0-9]*) : ;;
    ?|??) [ "$MARKER_VERSION" -ge 2 ] && INHERITED_CREATED_LT="$(mval CREATED_LOOPTESTING_DIR)" ;;
    *)    INHERITED_CREATED_LT="$(mval CREATED_LOOPTESTING_DIR)" ;;
  esac
fi

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

# --- worktree identity (lib.sh) ----------------------------------------------
# `wt_gitdir_of` and `wt_ownership` live in lib.sh, with the nonce-stamp
# rationale and the full verdict list. Ownership recorded as a PATH is not
# ownership: after a clean the path is free, and a user who chose it with
# --worktree-path may well reuse it.


# --- idempotent short-circuit: already initialized ---------------------------
# BUT if the marker records a worktree that a prior sandbox-clean removed, the
# sandbox lost its isolation — re-seeding alone would hand back a phantom
# "initialized" sandbox with NO isolated worktree, so the loop would run against
# (and commit into) the main tree (audit B2). In that case rebuild instead: drop
# the stale marker and fall through to full init, which re-adds the worktree on
# the (kept) qa branch. A live worktree, or branch-mode (no worktree), short-circuits.
PRIOR_CREATED_BRANCH=""
PRIOR_CREATED_TAG=""
# A worktree the rebuild walked away from rather than claimed. Recorded so it
# does not become invisible: purge keys off this marker, so a path missing from
# it can never be named again by any later run.
UNCLAIMED_WORKTREE=""
ADOPTED_BRANCH=""
ADOPTED_TAG=""
if [ -f "$MARKER" ]; then
  RECORDED_WT="$(mval CREATED_WORKTREE)"
  RECORDED_STAMP="$(mval WORKTREE_STAMP)"
  RECORDED_BRANCH="$(mval SANDBOX_BRANCH)"
  RECORDED_MODE="$(mval MODE)"
  # Branch mode has no worktree by design. In worktree mode an empty
  # CREATED_WORKTREE is never a live sandbox — every worktree-mode marker since
  # v0.1.0 writes the path — so it is treated exactly like a worktree that is
  # gone: rebuild if the path is free, refuse if something stands there. It
  # used to default to `ours` and short-circuit into an unisolated "ready".
  WT_STATE=ours
  if [ -n "$RECORDED_WT" ]; then
    WT_STATE="$(wt_ownership "$RECORDED_WT" "$RECORDED_STAMP" "$RECORDED_BRANCH")"
  elif [ "$RECORDED_MODE" != branch ]; then
    WT_STATE=absent
  fi
  REBUILD_WHY=""
  case "$WT_STATE" in
    absent)
      if [ -n "$RECORDED_WT" ]; then REBUILD_WHY="recorded worktree is gone ($RECORDED_WT)"
      else REBUILD_WHY="the marker records no worktree for a worktree-mode sandbox"; fi ;;
    stale)   REBUILD_WHY="the recorded worktree's directory is gone ($RECORDED_WT), leaving only a dangling registration" ;;
    foreign) REBUILD_WHY="the worktree at $RECORDED_WT is not this sandbox's (its stamp does not match)" ;;
    unknown) REBUILD_WHY="cannot confirm the worktree at $RECORDED_WT belongs to this sandbox" ;;
    # `legacy` is deliberately NOT here. Resuming is the reversible half: adopting
    # a worktree to continue a run can, at worst, put QA commits on a branch, and
    # that can be undone. Force-removing cannot. Refusing to resume would break
    # every sandbox created before stamping — the whole installed population —
    # and an unattended run would hit the isolation gate and report BLOCKED. The
    # protection lives in sandbox-clean, which will not delete what it cannot
    # identify.
    ours|legacy) : ;;
    *)
      # There was no default arm here, so a verdict none of the above names left
      # REBUILD_WHY empty and fell through to the short-circuit below: "already
      # initialized", .active armed, exit 0 — with nothing isolated. That is S-01
      # exactly, and round-0.md §7 tells the agent exit 0 means isolation holds.
      # The empty string is the case that matters: it is what a call to a function
      # that does not exist returns, which the guard at the top of this file now
      # refuses outright. This arm is the second line, for a verdict added to
      # lib.sh and not wired up here.
      die "the worktree ownership check returned '$WT_STATE', which this version of sandbox-setup does not recognise — refusing rather than reporting an isolation it cannot confirm. Inspect docs/looptesting/.sandbox/ownership.env and the worktree recorded at $RECORDED_WT." 9 ;;
  esac
  # Rebuild rather than refuse. A refusal here was a dead end: the gate reads only
  # marker fields, so none of the advice it could give changed the outcome, and
  # clean would not clear it either. Rebuilding honors --worktree-path when given
  # and otherwise stops at the existing "worktree path already exists" refusal,
  # which names a flag that actually works.
  if [ -n "$REBUILD_WHY" ]; then
    echo "sandbox-setup: $REBUILD_WHY — rebuilding isolation on the qa branch."
    # A dangling registration still holds the qa branch, so `worktree add` would
    # refuse the path. Dropping a registration whose directory no longer exists
    # removes no files — it is what git's own `worktree prune` does.
    if [ "$WT_STATE" = stale ] && [ ! -d "$RECORDED_WT" ]; then
      # Scoped to our own recorded path. `git worktree prune` would have been
      # repo-wide — it takes no path — and would drop other worktrees'
      # registrations along with ours. The `[ ! -d ]` re-test immediately above
      # is what handles the race the earlier verdict cannot rule out: if the
      # directory came back, we do nothing and the rebuild refuses below rather
      # than force-removing something that exists.
      git -C "$TOP" worktree remove --force "$RECORDED_WT" >/dev/null 2>&1 || true
    fi
    [ -z "$WT_PATH" ] && WT_PATH="$RECORDED_WT"
    # Name a route that actually works. While that worktree stands there it also
    # holds the sandbox branch, so --worktree-path alone cannot rebuild: git
    # refuses the branch, not the path. Saying "pass --worktree-path" here would
    # be a dead end dressed as advice.
    # Only when the rebuild genuinely cannot proceed: with --worktree-path given
    # and the branch free, redirecting really does work, so refusing there would
    # break the one route that does.
    case "$WT_STATE" in
      foreign|unknown)
        if [ "$WT_PATH" != "$RECORDED_WT" ] && [ -e "$RECORDED_WT" ]; then
          UNCLAIMED_WORKTREE="$RECORDED_WT"
          echo "sandbox-setup: the worktree at $RECORDED_WT is still standing — this run could not claim it, so it is left exactly as it is and recorded in the marker rather than forgotten."
        fi
        if [ "$WT_PATH" = "$RECORDED_WT" ] && [ -e "$RECORDED_WT" ]; then
          # `foreign` and `unknown` are not the same situation and must not get
          # the same advice. `foreign` is an answer: the stamp was read and it is
          # somebody else's, so naming --force is fair — the user knows whose it
          # is even if this script does not. `unknown` is the ABSENCE of an
          # answer, and handing --force to a user who has just been told this run
          # cannot identify the worktree is the tool refusing a destructive
          # operation and then asking the user to perform it by hand. The
          # qualifier "if it is the sandbox's" does not save it: when the probe
          # failed the worktree usually IS the sandbox's, so the qualifier reads
          # as a yes and --force discards whatever uncommitted or untracked QA
          # work is in there.
          if [ "$WT_STATE" = unknown ]; then
            die "this run could not confirm whether the worktree standing at $RECORDED_WT belongs to this sandbox — either the worktree registry or the worktree's own ownership record could not be read (an unreadable .git/worktrees is the usual cause). Fix that and re-run, or pass --worktree-path to build the sandbox somewhere else. No removal command is offered here on purpose: --force discards anything uncommitted or untracked, and this run cannot tell you whose work that would be. If it has '$BRANCH' checked out, --worktree-path alone will not be enough: git will refuse the branch, not the path" 6
          fi
          die "a worktree this sandbox cannot claim is standing at $RECORDED_WT. Either pass --worktree-path to build the sandbox somewhere else, or deal with that worktree first — 'git worktree remove --force $RECORDED_WT' if it is the sandbox's, move it aside if it is yours — and re-run. If it has '$BRANCH' checked out, --worktree-path alone will not be enough: git will refuse the branch, not the path" 6
        fi ;;
    esac
    # Carry the unclaimed worktree across the rebuild for the same reason the
    # adopted refs below are carried, on the field where forgetting costs more.
    # The record written above describes THIS run's verdict; the next rebuild has
    # a verdict about a different path and wrote this key empty, so after two
    # rebuilds the marker no longer named the worktree it had walked away from —
    # and nothing else on disk does. purge keys off exactly this, so its fourth
    # keep-case stopped firing and it closed over the evidence dir that held the
    # only record (audit S-09).
    #
    # Only while the path is still there: a record of something the user has
    # since removed would make every later purge stop short over nothing. And
    # only when this run has no unclaimed worktree of its own — the field holds
    # one path, so a run that walks away from a SECOND worktree still forgets the
    # first. That is a real residual, reachable only by redirecting --worktree-path
    # twice in a row, and closing it needs a multi-valued marker key.
    PRIOR_UNCLAIMED_WT="$(mval UNCLAIMED_WORKTREE)"
    if [ -z "$UNCLAIMED_WORKTREE" ] && [ -n "$PRIOR_UNCLAIMED_WT" ] && [ -e "$PRIOR_UNCLAIMED_WT" ]; then
      UNCLAIMED_WORKTREE="$PRIOR_UNCLAIMED_WT"
    fi
    # Carry ownership across the marker rebuild: sandbox-clean deliberately KEEPS
    # the qa branch and baseline tag, so re-deriving ownership below from "does
    # this ref exist now" would record neither — orphaning artifacts this sandbox
    # created beyond --purge's reach, and silencing its harvest warning.
    PRIOR_CREATED_BRANCH="$(mval CREATED_BRANCH)"
    PRIOR_CREATED_TAG="$(mval CREATED_TAG)"
    # Adoption must be transitive. After the first rebuild the marker records
    # CREATED_BRANCH= (empty) + ADOPTED_BRANCH=…, so reading only CREATED_* would
    # find nothing to carry on the NEXT rebuild and purge would fall silent again.
    [ -n "$PRIOR_CREATED_BRANCH" ] || PRIOR_CREATED_BRANCH="$(mval ADOPTED_BRANCH)"
    [ -n "$PRIOR_CREATED_TAG" ]    || PRIOR_CREATED_TAG="$(mval ADOPTED_TAG)"
    # The marker is NOT removed here. It is overwritten at the end of a successful
    # rebuild; deleting it up front means a rebuild that fails for any reason
    # (worktree path taken, add refused) leaves the worktree, branch and tag with
    # no record of who owns them — unclaimable by clean and invisible to purge.
  else
    # Re-verify the isolation before handing back "already initialized" — in
    # BOTH modes. Branch mode: the user may have switched branches since setup
    # (audit DR-9). Worktree mode: what the check above proved is that the PATH is
    # registered, not that the worktree there is ours — ownership is recorded by
    # path, the path is free again after a clean, and a user who picked it with
    # --worktree-path may well reuse it. Adopting it would run the loop, and
    # commit its fixes, onto the user's own branch with no isolation at all.
    if [ "$RECORDED_MODE" = "branch" ]; then
      # Only re-verify against the branch the marker ACTUALLY recorded. A legacy
      # marker (written before SANDBOX_BRANCH existed) has no recorded branch, so
      # the sandbox's branch is unknown — guessing the invocation default and
      # refusing would break a valid custom-branch sandbox with wrong advice
      # (and could false-pass onto the wrong branch). Skip the check for legacy
      # markers; new sandboxes always record SANDBOX_BRANCH so they are covered.
      want="$RECORDED_BRANCH"
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

# Record whether WE created docs/looptesting/, now that the tree has been judged
# clean and before the first git artifact can exist. Past GIT_TOUCHED=1 the
# rollback below is skipped, so a failed setup leaves the dir behind with no
# marker — and a retry inferring ownership from "the dir is already there" would
# brand the tool's OWN dir as the user's, making purge refuse to clean it up ever
# again. Deliberately AFTER the cleanliness check above: the preflight creates
# only empty dirs, which `git status --porcelain` cannot see, while this file can.
# Never overwrite an existing breadcrumb — the run that created the dir is the one
# that knows, and a later run must not overwrite its answer with a guess.
# Write it only when this run can honestly answer the question. Creating the dir
# ourselves is an answer. Finding it already there is an answer ONLY on a fresh
# start — with a marker already present we are mid-lifecycle, and "the dir was
# here when I arrived" says nothing about whether an earlier run of this tool put
# it there. Recording 0 in that case would manufacture a measurement; leaving it
# unwritten lets the marker say `unknown`, which is the truth.
if [ ! -f "$SB/created-dirs.env" ]; then
  _crumb=""
  if [ "$MADE_LT" = 1 ]; then _crumb=1
  elif [ "$MARKER_PRESENT_AT_START" = 0 ]; then _crumb=0
  fi
  if [ -n "$_crumb" ]; then
    if printf 'MADE_LOOPTESTING_DIR=%s\n' "$_crumb" > "$SB/created-dirs.env" 2>/dev/null; then
      WROTE_BREADCRUMB=1
    fi
  fi
fi

# Read BEFORE the branch stage: `git switch` to an existing qa branch moves HEAD,
# and the baseline is what HEAD was when this run started. The tag that marks it
# is created much further down — see the note there.
BASELINE_HEAD="$(git -C "$TOP" rev-parse HEAD 2>/dev/null || echo '')"

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
    # Keep git's own reason: "already used by worktree at ..." is the difference
    # between an actionable message and a bare exit code.
    WT_ADD_ERR="$(git -C "$TOP" worktree add "$WT_PATH" "$BRANCH" 2>&1 >/dev/null)" \
      || die "failed to add worktree at $WT_PATH for existing branch $BRANCH — git said: ${WT_ADD_ERR:-<no output>}" 6
  else
    WT_ADD_ERR="$(git -C "$TOP" worktree add -b "$BRANCH" "$WT_PATH" 2>&1 >/dev/null)" \
      || die "failed to add worktree at $WT_PATH — git said: ${WT_ADD_ERR:-<no output>}" 6
    CREATED_BRANCH="$BRANCH"
  fi
  CREATED_WORKTREE="$WT_PATH"
  # Stamp it now, inside the worktree's own git admin dir: git removes that dir
  # with the worktree, so the stamp dies with the thing it identifies and a
  # worktree later created at the same path cannot inherit it.
  WT_GITDIR="$(wt_gitdir_of "$WT_PATH")"
  if [ -n "$WT_GITDIR" ]; then
    printf '%s\n' "$SANDBOX_ID" > "$WT_GITDIR/loop-testing-owner" 2>/dev/null || WORKTREE_STAMP=""
  else
    WORKTREE_STAMP=""   # could not stamp: record no stamp rather than a false one
  fi
fi

# --- evidence dir + templates ------------------------------------------------
seed_dirs_and_templates
git -C "$TOP" status --porcelain > "$SB/git-status-baseline.txt" 2>/dev/null || true

# --- baseline tag (own it only if we create it) ------------------------------
# Created LAST, after every step that can refuse. The ownership marker is written
# a few lines below, and it is the only record that this sandbox created the tag;
# anything that exits between the two leaves a `qa-baseline` nothing claims. The
# tag used to be created before the branch/worktree stage, so an occupied
# worktree path — the refusal whose own message tells the user to re-run with
# --worktree-path — returned exit 6 with that tag standing. The retry then found
# a tag it had not created, correctly declined to own what might be the user's,
# and recorded neither CREATED_TAG nor ADOPTED_TAG: outside --purge's reach for
# good, in the repo the tool had just invited the user to re-run in (audit S-07).
#
# The commit is named explicitly. In branch mode this now runs after `git switch`,
# where HEAD is no longer where it was, and the tag must mark the baseline the
# marker records rather than the branch tip.
#
# Residual: a crash (not a refusal — there is no `die` left on this path) between
# the tag and the marker write still orphans it. That window is two statements
# wide and cannot be closed while the marker is a single file written in one go.
CREATED_TAG=""
if [ -n "$BASELINE_HEAD" ]; then
  if git -C "$TOP" rev-parse -q --verify "refs/tags/$BASELINE_TAG" >/dev/null 2>&1; then
    :  # pre-existing tag — not ours to remove
  else
    git -C "$TOP" tag "$BASELINE_TAG" "$BASELINE_HEAD" >/dev/null 2>&1 && { CREATED_TAG="$BASELINE_TAG"; GIT_TOUCHED=1; }
  fi
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
#
# Runs after the tag block above, not before it: both lines read CREATED_* to
# decide whether there is anything left to adopt.
[ -z "$CREATED_BRANCH" ] && [ "$PRIOR_CREATED_BRANCH" = "$BRANCH" ] && ADOPTED_BRANCH="$BRANCH"
[ -z "$CREATED_TAG" ] && [ "$PRIOR_CREATED_TAG" = "$BASELINE_TAG" ] && ADOPTED_TAG="$BASELINE_TAG"

# Ownership of docs/looptesting/, in order of authority: the breadcrumb this
# lifecycle line wrote when the dir first appeared, then a previous marker's
# field, then this run's own mkdir. Presence of the directory is never evidence —
# a plain clean keeps it, so by the next setup it always exists.
BREADCRUMB_MADE_LT="$(grep -aE '^MADE_LOOPTESTING_DIR=' "$SB/created-dirs.env" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/[[:space:]]*$//')"
if [ "$BREADCRUMB_MADE_LT" = 1 ] || [ "$MADE_LT" = 1 ]; then
  CREATED_LT=true              # measured: this lifecycle line created the dir
elif [ "$BREADCRUMB_MADE_LT" = 0 ]; then
  CREATED_LT=false             # measured: the dir was already there
elif [ "$INHERITED_CREATED_LT" = true ] || [ "$INHERITED_CREATED_LT" = false ]; then
  CREATED_LT="$INHERITED_CREATED_LT"
else
  # Nothing measured it. A sandbox upgraded from before this field existed lands
  # here: the old marker's value is not usable and the old version wrote no
  # breadcrumb. Recording `false` would be a guess that reads as a measurement,
  # and would let purge tell the user the directory holds files that were
  # already theirs — which is exactly what nobody established.
  CREATED_LT=unknown
fi

# --- ownership marker (parsed, never sourced, by sandbox-clean.sh) -----------
{
  # 2: CREATED_LOOPTESTING_DIR became meaningful. Version 1 wrote it as a
  # constant `true`, so a v1 marker says nothing about who owns the evidence dir
  # and sandbox-clean must treat it as unknown rather than as permission to delete.
  echo "SANDBOX_VERSION=2"
  echo "MODE=$MODE"
  echo "SANDBOX_BRANCH=$BRANCH"
  echo "TOP=$TOP"
  echo "CREATED_BRANCH=$CREATED_BRANCH"
  echo "CREATED_TAG=$CREATED_TAG"
  # Re-used by this run, not created by it — reported at purge, never deleted.
  echo "ADOPTED_BRANCH=$ADOPTED_BRANCH"
  echo "ADOPTED_TAG=$ADOPTED_TAG"
  echo "CREATED_WORKTREE=$CREATED_WORKTREE"
  # Left standing by a rebuild, never owned by this run. Reported at purge,
  # never deleted — the same rule as an adopted ref.
  echo "UNCLAIMED_WORKTREE=$UNCLAIMED_WORKTREE"
  # Empty in branch mode and whenever the stamp could not be written: an empty
  # stamp means "no identity recorded", which readers treat as the pre-stamp
  # behavior rather than as a mismatch.
  echo "WORKTREE_STAMP=$([ -n "$CREATED_WORKTREE" ] && echo "$WORKTREE_STAMP")"
  # true only when THIS run created docs/looptesting/, or a previous run recorded
  # that it did. Anything else means we adopted a directory the user already keeps
  # files in, and purge must report it rather than rm -rf it — the same rule the
  # marker already applies to adopted branches and tags.
  echo "CREATED_LOOPTESTING_DIR=$CREATED_LT"
  echo "BASELINE_HEAD=$BASELINE_HEAD"
  echo "SETUP_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$MARKER" || die "failed to write the ownership marker $MARKER — sandbox-clean could not claim what this run just created; remove the worktree/branch by hand" 8
[ -s "$MARKER" ] || die "ownership marker $MARKER is empty after writing (disk full?) — sandbox-clean could not claim what this run just created" 8

echo "sandbox-setup: ready (mode=$MODE, branch=$BRANCH, baseline=$BASELINE_TAG)."
[ -n "$CREATED_WORKTREE" ] && echo "  worktree: $CREATED_WORKTREE"
echo "  evidence: $LT"
exit 0
