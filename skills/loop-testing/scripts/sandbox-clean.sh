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
#                    five cases: the marker records that the sandbox only re-used
#                    a directory the user already had; the marker predates that
#                    field being measured; the field says the question was never
#                    answered (an upgraded sandbox lands here); a worktree this
#                    run could not claim is still registered and the marker is the
#                    only record of it; or the directory holds files this sandbox
#                    did not write, which are never deleted. In that last case the
#                    ownership marker and STATE.md are kept WITH them, so a later
#                    --purge can still identify this sandbox's refs and act —
#                    deleting the marker while leaving residue would strand you
#                    with leftovers the tool can no longer name or remove. Inside
#                    the evidence dir only this sandbox's own files are deleted,
#                    by name; runs/, decisions/ and .sandbox/ go whole, so nothing
#                    you want kept may live in those three. The tag and branch are identified by
#                    the recorded baseline, not by name: the tag goes only if it
#                    is a lightweight tag still AT that commit, the branch only
#                    if it descends from it — anything else of the same name is
#                    kept and named. KNOWN LIMIT: a lightweight tag the user
#                    re-created at exactly the recorded baseline commit is
#                    byte-for-byte what this sandbox writes, so nothing on disk
#                    can tell them apart and purge deletes it. Re-creating a
#                    deleted lightweight tag at the same commit loses nothing;
#                    anything a user would mind losing (a message, a signature,
#                    a different commit) makes the tag distinguishable and is
#                    kept.
#                    The branch is deleted only when it has no fix commits beyond
#                    the recorded baseline OR --discard-fixes is given — fix
#                    commits exist ONLY on that branch, so harvest them (merge /
#                    cherry-pick) first. Refuses (exit 3) without an ownership
#                    marker or a terminal STATE. Default behavior without
#                    --purge is unchanged.
#
# Exit codes: 0 cleaned (or nothing to clean) · 1 internal abort (re-anchored to
# the main tree but cannot cd there — applies to both plain clean and --purge) ·
# 2 usage error · 3 --purge refused (no marker / non-terminal STATE) · 4 --purge
# ran but stopped short: a worktree it could not claim is still registered, so
# the evidence dir and its marker were kept. Resolve that worktree and re-run.
#
# git floors: 2.5 (`worktree`), 2.7 (`worktree list --porcelain`,
# `for-each-ref --contains`), 1.8.0 (`merge-base --is-ancestor`). Everything
# newer is probed and falls back (`--absolute-git-dir`, `symbolic-ref` in place
# of `branch --show-current`).
set -u

echo_info() { echo "sandbox-clean: $*"; }

PURGE=0
DISCARD_FIXES=0
# Print the header block as the help text (same mechanism as install-codex.sh):
# one source of truth, so usage and exit codes cannot drift from the comment that
# documents them.
usage() { sed -n '2,56p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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
  GCD_P="$(cd "$GCD" 2>/dev/null && pwd -P)"
  # Mirrors sandbox-setup.sh (audit S-02): a candidate is the main tree of THIS
  # repository only if its git-common-dir is the one we started from. "The repo
  # containing the parent of the common dir" is a layout guess, wrong exactly
  # when a --separate-git-dir or bare repository sits inside another repo — the
  # clean then looked for (and, on --purge, deleted under) the OUTER repo.
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
  for _cand in \
    "$(git -C "$TOP" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1)" \
    "$(dirname "$GCD")"; do
    [ -n "$_cand" ] || continue
    _cand_top="$(git -C "$_cand" rev-parse --show-toplevel 2>/dev/null)"
    [ -n "$_cand_top" ] || continue
    if same_repo "$_cand_top"; then MAIN_TOP="$_cand_top"; break; fi
  done
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
# Validity = the three keys every marker version has written since v0.1.0:
# SANDBOX_VERSION (numeric), MODE and TOP. Deliberately not a whole-file schema —
# v1 markers legitimately lack ADOPTED_*/UNCLAIMED_WORKTREE/WORKTREE_STAMP, and
# rejecting those would strand every sandbox created before v0.10.0.
#
# `marker_key` and `mval` below are byte-identical to sandbox-setup.sh's, so one
# marker cannot be valid to one script and invalid to the other. Only the
# trailing CR is stripped, and only one: a CRLF marker (Windows editor,
# core.autocrlf, an evidence dir copied through a zip) made every value end in
# `\r`, so this check refused the file while setup, reading the same bytes,
# called a live worktree gone (audit S-08). Stripping all trailing whitespace
# instead would silently shorten a path whose directory name legally ends in a
# space. Parameter expansion, not `sed 's/\r$//'`: BSD sed does not interpret
# `\r` and would eat a trailing literal `r` instead.
marker_key() { local v; v="$(grep -aE "^$1=[^[:space:]]" "$MARKER" 2>/dev/null | head -1 | cut -d= -f2-)"; printf '%s' "${v%$'\r'}"; }
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
mval() { local v; v="$(grep -aE "^$1=" "$MARKER" 2>/dev/null | head -1 | cut -d= -f2-)"; printf '%s' "${v%$'\r'}"; }
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
  local p="$1" want="$2" gd got list nl _gl   # $3 (recorded branch) is no longer consulted
  # Builtins only from here down. The first version parsed `git worktree list`
  # with awk, so a missing awk read as "not ours"; swapping awk for `cat` only
  # moved that hole. Any external command on this path can fail, and a failed
  # command must never be mistaken for an ownership verdict — so there are none.
  nl='
'
  # The one external command left on this path, and it can fail like any other:
  # an unreadable or locked .git/worktrees, a corrupted admin entry, a fork that
  # cannot allocate. Its empty output used to flow straight into the match below
  # and come out as `absent` — a live worktree reported "already gone", purge
  # closing with exit 0 over a sandbox still standing (audit S-04). A failed
  # command is not a verdict: `unknown` is. What each caller does with it differs
  # — clean keeps the worktree and stops short at exit 4, setup refuses and asks
  # for another path — so this comment does not get to speak for "every caller";
  # what holds is that none of them deletes on it.
  if ! list="$(git -C "$TOP" worktree list --porcelain 2>/dev/null)"; then
    printf 'unknown'; return
  fi
  list="$list$nl"
  case "$nl$list" in
    *"${nl}worktree $p${nl}"*) : ;;
    *)
      # Not listed is not the same as not there. `git worktree list` ALSO exits 0
      # and silently omits an entry whose admin dir is unreadable or whose
      # `gitdir` file is missing (measured on git 2.53.0: rc=0, empty stderr,
      # entry gone), so the exit status above cannot be the only liveness signal
      # — audit S-04, second arm. A linked checkout owns its own `.git` FILE: it
      # lives inside the checkout, not in the admin dir, and outlives both
      # failures. `-f`, not `-e`: a plain repo parked at the freed path has
      # `.git` as a DIRECTORY, and that one really is absent as far as this
      # sandbox is concerned — `-e` would manufacture a permanent exit 4 over a
      # user's own repository.
      # Three states, not two. `-f` false can mean "no worktree here" or "this
      # process cannot look". An unreadable admin dir alone is not enough to get
      # here — git still LISTS an inaccessible worktree — but an unreadable admin
      # dir together with an unsearchable PARENT is, and that pair has one
      # plausible cause: a sandbox created by another account on a shared box,
      # which is the scenario the finding names. `-x` on the parent is the "can I
      # look at all" test, and `${p%/*}` keeps this function builtins-only as its
      # header requires.
      #
      # A `.git` FILE is not by itself a linked worktree: `git init
      # --separate-git-dir`, a submodule checkout and a plain file of that name
      # all have one. Only a linked worktree of THIS repo points into
      # `$TOP/.git/worktrees/`, so that is what makes it ours — without the
      # check, a user's own --separate-git-dir repo parked at the freed path
      # reads as `unknown` and earns a permanent exit 4, with a diagnosis
      # ("the registry could not be read") that is false: it read fine.
      if [ -f "$p/.git" ]; then
        _gl=""
        IFS= read -r _gl < "$p/.git" 2>/dev/null
        case "$_gl" in
          "gitdir: $TOP/.git/worktrees/"*) printf 'unknown'; return ;;
          "") printf 'unknown'; return ;;   # present but unreadable — cannot tell
        esac
        printf 'absent'; return             # someone else's .git file
      fi
      if [ -e "$p" ]; then printf 'absent'; return; fi
      if [ -x "${p%/*}" ]; then printf 'absent'; else printf 'unknown'; fi
      return ;;
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
  # This process and its ancestors are never targets, and their descendant trees
  # are never expanded either — this process is one of those descendants, so
  # collect_tree would put our own PID into the set and clean would signal itself
  # at that line, before the worktree removal and before `.active` is disarmed
  # (audit S-06). The recorded PIDs come from `lsof -t -i :PORT` / `ss -ltnp`,
  # which report whoever holds the port: the agent session, or the unattended
  # driver that started it, are exactly the processes that can be both an
  # ancestor of this script and the answer to that query. A recycled PID lands in
  # the same place.
  #
  # $$ and $PPID come from the shell and cannot fail. The walk above them uses
  # `ps`, which may be missing or refuse — and an incomplete chain is NOT
  # harmless: case 6 of clean-pid-guard exists because a grandparent is findable
  # only by this walk, so "nothing here depends on the walk succeeding" (what
  # this comment used to say) was contradicted by the test written beside it.
  # `ps` right-aligns its output in a fixed-width field, so the padding goes
  # through `tr -dc '0-9'` like the six other places in this repo that read a
  # padded count; leaving it in makes every comparison below miss silently.
  #
  # WALK_COMPLETE is the difference between "reached the top of the tree" and
  # "could not ask" — `case "$_spp" in ''|…) break` cannot tell those apart, and
  # on the second reading every ancestor above the truncation becomes a legal
  # signal target while pgrep still expands the recorded PID into a tree that
  # contains this cleanup. A healthy walk never takes that arm: `ps -o ppid= -p 1`
  # prints 0, so it exits through the `-gt 1` test below.
  LOOP_PROCFS="${LOOP_TESTING_PROCFS:-/proc}"   # test seam; never set in normal use
  WALK_COMPLETE=0
  PIDS_UNACTED=0   # recorded services this run declined to stop; see the purge
                   # keep-case — leaving the ledger "for a later run" is only
                   # true if something keeps the directory it lives in.
  SELF_CHAIN=" $$ $PPID "
  _sp="$PPID"
  _hops=0
  # The bound is a backstop, not the terminator: the cycle check below breaks on
  # any repeated PID, so a real tree always ends at the `-gt 1` arm. It was 64,
  # which a deep chain can legitimately exceed — measured at 77 hops of nested
  # shells — and falling out of the loop leaves WALK_COMPLETE=0, so the stage was
  # skipped while the message asserted that "ps gave no answer and procfs had
  # none either" when both had answered every hop. Past any real process tree,
  # so WALK_COMPLETE=0 means what the message says it means.
  while [ "$_hops" -lt 4096 ]; do
    [ "$_sp" -gt 1 ] 2>/dev/null || { WALK_COMPLETE=1; break; }   # reached the top
    _spp="$(ps -o ppid= -p "$_sp" 2>/dev/null | tr -dc '0-9')"
    # `ps -p` exits non-zero for "no such process" and for a ps that could not
    # answer, and `ps -o ppid= -p <live pid>` can print nothing while exiting 0 —
    # so empty output is not an answer. procfs can still have one.
    if [ -z "$_spp" ] && [ -r "$LOOP_PROCFS/$_sp/status" ]; then
      while IFS= read -r _line; do
        case "$_line" in
          PPid:*) _spp="$(printf '%s' "${_line#PPid:}" | tr -dc '0-9')"; break ;;
        esac
      done < "$LOOP_PROCFS/$_sp/status"
    fi
    case "$_spp" in ''|*[!0-9]*) break ;; esac   # neither probe could answer
    case "$SELF_CHAIN" in *" $_spp "*) break ;; esac   # a cycle cannot be walked
    SELF_CHAIN="$SELF_CHAIN$_spp "
    _sp="$_spp"
    _hops=$(( _hops + 1 ))
  done

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
    # Fail closed on a chain this run could not finish walking. With a truncated
    # chain the check below can only reject the ancestors it happens to know, and
    # the cost of being wrong is signalling the teardown itself — before the
    # worktree is removed and before `.active` is disarmed. The ledger is left in
    # place (see the guarded clear below) so a later run on a host where the walk
    # works can still stop these services.
    if [ "$WALK_COMPLETE" = 0 ]; then
      PIDS_UNACTED=$(( PIDS_UNACTED + 1 ))
      echo_info "refusing to signal PID $pid from .pids (this run could not walk its own ancestry — ps gave no answer and procfs had none either — so it cannot prove this PID is not one of its own ancestors; $PIDS_FILE is left for a later run)"
      continue
    fi
    # Compare the normalized value for the same reason the 0/1 guard does: a
    # zero-padded copy of our own parent is still our own parent.
    case "$SELF_CHAIN" in
      *" $norm "*)
        echo_info "refusing to signal PID $pid from .pids (it is this cleanup's own process, or one of its ancestors — signalling it would stop the teardown before the worktree is removed)"
        continue ;;
    esac
    kill -0 "$pid" 2>/dev/null || continue
    TARGETS="$TARGETS
$(collect_tree "$pid")"
  done < "$PIDS_FILE"
  TARGETS=$(printf '%s\n' "$TARGETS" | grep -E '^[0-9]+$' | sort -un)
  # Backstop, and defensive rather than load-bearing: the per-PID guard above
  # `continue`s before `collect_tree` ever runs, and with WALK_COMPLETE=1 any PID
  # whose descendants include us is already in SELF_CHAIN — so no input reaches
  # this filter today. It stays because a future reordering of those two steps
  # would silently re-open the path, and the cost is one comparison per target.
  # (An earlier version of this comment described that path as live, which it is
  # not.) pgrep output is unpadded, and so is SELF_CHAIN.
  _kept=""
  for _t in $TARGETS; do
    case "$SELF_CHAIN" in
      *" $_t "*)
        echo_info "refusing to signal PID $_t (it is this cleanup's own process or one of its ancestors, reached by expanding a recorded PID's descendants)" ;;
      *) _kept="$_kept$_t
" ;;
    esac
  done
  TARGETS="$_kept"

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
  # Clear the ledger only if this run was actually able to act on it. Clearing
  # after a fail-closed skip would discard the record of services nobody stopped.
  if [ "$WALK_COMPLETE" = 1 ]; then : > "$PIDS_FILE"; fi   # keep the file for continued runs
fi

# --- remove only the worktree we created ------------------------------------
WT_KEPT=0   # set when the worktree was deliberately left standing
if [ -n "$CREATED_WORKTREE" ]; then
  # Guard against ever removing the repo itself, / or $HOME.
  # `${HOME:-}`, not `$HOME`: this script runs under `set -u`, and a bare
  # reference is a fatal unbound-variable error wherever HOME is not exported —
  # cron, a systemd unit without `User=`, `env -i`, a container entrypoint. That
  # killed the teardown at this line, BEFORE the worktree was removed and before
  # `.active` was disarmed, so a guard against deleting $HOME cost the whole
  # cleanup exactly when $HOME did not exist (audit S-05). An undefined HOME
  # contributes an empty pattern, which cannot match the non-empty path the
  # `[ -n "$CREATED_WORKTREE" ]` above already guarantees.
  case "$CREATED_WORKTREE" in
    ""|"/"|"${HOME:-}"|"$TOP")
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
          # No removal command here, and the omission is deliberate. `foreign`
          # above is an ANSWER — the stamp was read and it is somebody else's —
          # and it offers none either. `unknown` is the absence of an answer, so
          # offering one here was the inverse of the split sandbox-setup.sh uses,
          # and the qualifier does not rescue it: "if it is the sandbox's" reads
          # as a yes exactly when the probe failed, which is when the worktree
          # usually IS the sandbox's and --force would discard its uncommitted
          # and untracked work. This arm also became reachable from more states
          # when a failed registry read started producing `unknown`.
          echo_info "kept worktree $CREATED_WORKTREE — this run could not confirm whether it belongs to this sandbox: either the worktree registry or the worktree's own ownership record could not be read (an unreadable .git/worktrees is the usual cause). Fix that and run clean again. No removal command is offered here on purpose — --force discards anything uncommitted or untracked, and this run cannot tell you whose work that would be" ;;
        legacy)
          # Marker predates ownership stamping, so nothing here records which
          # worktree this sandbox created. The pre-stamp behavior was to remove
          # whatever stood at the recorded path — the original data-loss bug,
          # still armed for every sandbox that already exists. No identity
          # recorded is not permission.
          #
          # And "not permission" has to survive into the advice, which it did not.
          # `legacy` is `unknown`'s situation and not `foreign`'s: the stamp was
          # never written, so there is no answer to read, and this arm went on
          # printing a ready-to-paste `--force` long after the other two stopped.
          # "check it first" next to the command that skips the check is not a
          # check.
          #
          # The first repair substituted git's own refusal for that check, and
          # that was wrong in the case that matters most (review F1). `git
          # worktree remove` refuses over tracked-modified and untracked files;
          # it does NOT refuse over IGNORED ones. A finished loop sandbox is
          # exactly that state — round-N commits its fixes, so what is left is
          # build output, .env and logs, all matched by the project's own
          # .gitignore and all invisible to `git status`. Measured: such a
          # worktree reports zero porcelain lines and `git worktree remove`
          # takes it at exit 0 with the .env in it. So the advice cannot lean on
          # a refusal; it has to name the inspection that can see the files, and
          # state where the refusal stops. Pinned by worktree-identity case 9b.
          echo_info "kept worktree $CREATED_WORKTREE — its ownership marker predates worktree stamping, so nothing records that this sandbox created it and this run cannot tell it from one of yours. Look before you remove: 'git -C \"$CREATED_WORKTREE\" status --porcelain --ignored' lists what is actually in there, including the build output, .env files and logs a finished loop leaves behind, which plain 'git status' does not show. Then, if it is the sandbox's, remove it with 'git worktree remove -- \"$CREATED_WORKTREE\"'. Note what that does NOT protect: git only refuses over tracked-modified or untracked files, never over ignored ones, so once the loop has committed its fixes it will take this worktree silently. No --force is printed here on purpose; this run cannot tell you whose work it would discard" ;;
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
  # Set by every branch below that KEEPS a ref this sandbox might own. The
  # evidence-dir stage reads it: a kept ref's only recovery route runs through
  # the marker (`--purge --discard-fixes`, or a re-run after you delete the ref
  # by hand), and deleting the marker in the same run that names that route
  # destroys it. Two stages each learned to stop short; only one of them was
  # protecting the marker.
  REFS_KEPT=0

  # A name is not an identity (audit S-03). The marker says what this sandbox
  # created: a tag AT BASELINE_HEAD, and a branch STARTING FROM it. A tag of that
  # name pointing anywhere else, or a branch of that name that does not descend
  # from that commit, is something the user made in the meantime — the same
  # workflow the ADOPTED_* rule already protects across lifecycles, only within
  # one. So every deletion below is gated on the recorded baseline: no baseline
  # recorded (or no longer resolvable) means nothing can be identified, and
  # nothing is deleted.
  base_ok=0
  if [ -n "$P_BASE" ] && git -C "$TOP" rev-parse -q --verify "$P_BASE^{commit}" >/dev/null 2>&1; then
    base_ok=1
  fi

  if [ -n "$P_TAG" ] && git -C "$TOP" rev-parse -q --verify "refs/tags/$P_TAG" >/dev/null 2>&1; then
    # Two questions, and `^{commit}` answers only the second. It PEELS: an
    # annotated tag object resolves to the commit it wraps, so a user's annotated
    # tag sitting on the recorded baseline looked exactly like the sandbox's own.
    # sandbox-setup only ever writes a lightweight tag (`git tag <name>`, never
    # -a/-m/-s), so an annotated object of that name was made by someone else —
    # and it carries their message and signature, which deleting destroys.
    tag_type="$(git -C "$TOP" cat-file -t "refs/tags/$P_TAG" 2>/dev/null)"
    tag_at="$(git -C "$TOP" rev-parse -q --verify "refs/tags/$P_TAG^{commit}" 2>/dev/null)"
    if [ "$tag_type" != commit ]; then
      REFS_KEPT=1; echo_info "purge: kept tag $P_TAG (its object type is ${tag_type:-unreadable}, and this sandbox only ever writes a lightweight tag — so this one is not ours; remove it by hand if you want it gone)"
    elif [ "$base_ok" = 1 ] && [ -n "$tag_at" ] && [ "$tag_at" = "$P_BASE" ]; then
      git -C "$TOP" tag -d "$P_TAG" >/dev/null 2>&1 && echo_info "purge: deleted baseline tag $P_TAG"
    elif [ "$base_ok" = 1 ]; then
      REFS_KEPT=1; echo_info "purge: kept tag $P_TAG (it no longer points at the recorded baseline ${P_BASE}, so it is not the one this sandbox created — remove it by hand if it is)"
    else
      REFS_KEPT=1; echo_info "purge: kept tag $P_TAG (the marker records no resolvable baseline, so this run cannot tell the sandbox's tag from one of yours)"
    fi
  fi

  if [ -n "$P_BRANCH" ] && git -C "$TOP" rev-parse -q --verify "refs/heads/$P_BRANCH" >/dev/null 2>&1; then
    cur="$(git -C "$TOP" symbolic-ref --short -q HEAD 2>/dev/null)"
    fixes=-1   # -1 = unknown (unverifiable baseline) -> fail-closed like >0
    # Ours only if the recorded baseline is an ancestor of the tip: the branch
    # was cut from that commit and only ever gained commits on top of it. A tip
    # that does NOT contain the baseline (the user's own branch of the same name
    # at an older commit, say) reads as "0 commits beyond the baseline" to
    # rev-list, which the old code took as permission to delete it.
    descends=0
    if [ "$base_ok" = 1 ]; then
      if git -C "$TOP" merge-base --is-ancestor "$P_BASE" "refs/heads/$P_BRANCH" 2>/dev/null; then
        descends=1
        fixes="$(git -C "$TOP" rev-list --count "$P_BASE..refs/heads/$P_BRANCH" 2>/dev/null)"
        case "$fixes" in ''|*[!0-9]*) fixes=-1 ;; esac
      fi
    fi
    if [ "${WT_STATE:-}" = unknown ] && [ "$P_BRANCH" = "$SANDBOX_BRANCH" ]; then
      # `git branch -D` refuses a branch that is checked out in another worktree
      # — and it reads that fact out of `.git/worktrees`, the same admin dir this
      # run could not read. So on an `unknown` verdict the refusal is not a
      # protection that happens to be there; it is a probe that failed silently,
      # and the deletion goes through. The worktree is left on a dangling ref and
      # the branch was the only record of its commits (audit S-04, second arm).
      # WT_STATE is only assigned when the worktree stage ran, hence `:-`.
      REFS_KEPT=1; kept_branch="$P_BRANCH (this run could not identify the worktree holding it, and git's own 'checked out elsewhere' refusal reads the same registry this run could not read — delete it by hand once the worktree is resolved)"
    elif [ "$cur" = "$P_BRANCH" ]; then
      REFS_KEPT=1; kept_branch="$P_BRANCH (currently checked out — switch away, then delete it by hand)"
    elif [ "$descends" = 0 ]; then
      if [ "$base_ok" = 1 ]; then
        REFS_KEPT=1; kept_branch="$P_BRANCH (it does not descend from the recorded baseline ${P_BASE}, so it is not the branch this sandbox created — remove it by hand if it is)"
      else
        REFS_KEPT=1; kept_branch="$P_BRANCH (the marker records no resolvable baseline, so this run cannot tell the sandbox's branch from one of yours — remove it by hand once you have harvested)"
      fi
    elif [ "$fixes" = "0" ] || [ "$DISCARD_FIXES" = 1 ]; then
      if git -C "$TOP" branch -D "$P_BRANCH" >/dev/null 2>&1; then
        echo_info "purge: deleted branch $P_BRANCH"
      else
        REFS_KEPT=1; kept_branch="$P_BRANCH (git refused the deletion — checked out in another worktree?)"
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
          REFS_KEPT=1; kept_branch="$P_BRANCH (holds $fixes fix commit(s); the tip is also reachable from '$harvested_by' — if that is where you harvested them, re-run with --purge --discard-fixes to drop the branch)"
        else
          REFS_KEPT=1; kept_branch="$P_BRANCH (holds $fixes fix commit(s) beyond the baseline — harvest them first, or re-run with --purge --discard-fixes)"
        fi
      else
        REFS_KEPT=1; kept_branch="$P_BRANCH (baseline unverifiable, fix commits unknown — harvest first, or re-run with --purge --discard-fixes)"
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
  elif [ "${PIDS_UNACTED:-0}" -gt 0 ]; then
    # The .pids stage declined to signal services it could not prove were not
    # this cleanup's own ancestors, and said the ledger was "left for a later
    # run". On a purge that sentence is only true if something keeps the
    # directory the ledger lives in — otherwise the same run that promised a
    # later one deletes the evidence of what it skipped, and closes at exit 0
    # with the services still running. Keeping `.pids` alone inside an otherwise
    # deleted directory is worse than useless: its meaning depends on the marker
    # that would have gone with the dir.
    echo_info "purge: kept evidence dir $LT_DIR — this run could not walk its own ancestry, so it left ${PIDS_UNACTED} recorded service(s) running rather than risk signalling itself; $PIDS_FILE names them, and the marker here is what a later run needs to finish the job"
  elif [ "$REFS_KEPT" = 1 ]; then
    # Same rule as the worktree above, for the stage that learned to stop short
    # later. A ref was kept — it holds unharvested fix commits, it is checked
    # out, it no longer matches the recorded baseline, or the baseline itself is
    # unresolvable. Each of those has a follow-up (`--purge --discard-fixes`, or
    # deleting the ref by hand and purging again), and every follow-up needs this
    # marker to know what is the sandbox's. Deleting it here would leave the ref
    # standing with nothing on disk able to name it, and answer the next
    # `--purge` with exit 3 — the tool naming a recovery route in the same breath
    # as destroying it. The evidence stays too: commits you have not harvested
    # yet are exactly when `runs/` and `ISSUES.md` are worth reading.
    echo_info "purge: kept evidence dir $LT_DIR — a ref above was kept, and the marker here is the only record that can identify it; harvest or remove that ref, then purge again"
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
        # Delete by NAME, never "everything under the directory this run
        # created". Since the drivers record a headless run's evidence dir as
        # the tool's own, this branch would otherwise `rm -rf` a directory the
        # user had dropped files into between runs — and an untracked file is
        # gone for good. Owning the DIRECTORY is not owning everything later
        # put inside it.
        #
        # Each name below is written by this tool: sandbox-setup.sh seeds
        # STATE.md / PLAN.md / FEATURE_MATRIX.md / ISSUES.md / SUGGESTIONS.md
        # plus .pids and the .active sentinel; the skill writes FINAL_REPORT.md
        # at exit; hooks/stop-gate.sh writes .gate-count; the unattended drivers
        # write driver.log and .driver.lock.
        for f in ISSUES.md PLAN.md FEATURE_MATRIX.md SUGGESTIONS.md \
                 FINAL_REPORT.md driver.log .active .pids .gate-count; do
          rm -f "$LT_DIR/$f" 2>/dev/null
        done
        # runs/, decisions/ and .sandbox/ go whole: their CONTENTS are the
        # tool's by construction — the agent names its own evidence files, so
        # there is no manifest to check them against — and that is the line.
        # Anything you want kept must not live inside those three.
        rm -rf "$LT_DIR/runs" "$LT_DIR/decisions" "$LT_DIR/.driver.lock" 2>/dev/null
        # The marker and STATE.md are decided LAST, and only ever go together
        # with the directory. They are this script's two inputs: the marker is
        # the only record that can identify the sandbox's worktree and refs, and
        # STATE.md is the terminal-status precondition --purge refuses without.
        # Deleting either while leftovers keep the directory alive would send the
        # next --purge into a fail-closed exit 3 with no tool route to finish —
        # residue the tool could no longer name OR remove. So when anything is
        # kept, they are kept with it, and this branch stays re-runnable.
        # Globs, not `ls | grep`: a leftover may be named anything at all, and a
        # newline in a filename must not be able to split one entry into two.
        lt_leftovers=""
        for lt_p in "$LT_DIR"/* "$LT_DIR"/.[!.]* "$LT_DIR"/..?*; do
          # `-e` is FALSE for a dangling symlink, and a dangling symlink is a
          # leftover: an agent that linked into a worktree `clean` has since
          # removed leaves exactly one. Missing it made the directory look empty,
          # so the marker and STATE.md were deleted and only then did `rmdir`
          # fail on the link — the stranding this whole branch exists to prevent.
          [ -e "$lt_p" ] || [ -L "$lt_p" ] || continue   # unmatched glob expands to itself
          case "${lt_p##*/}" in .sandbox|STATE.md) continue ;; esac
          lt_leftovers="${lt_leftovers:+$lt_leftovers, }${lt_p##*/}"
        done
        if [ -z "$lt_leftovers" ]; then
          rm -f "$LT_DIR/STATE.md" 2>/dev/null
          rm -rf "$LT_DIR/.sandbox" 2>/dev/null
          if rmdir "$LT_DIR" 2>/dev/null; then
            echo_info "purge: removed evidence dir $LT_DIR (marker included)"
          else
            echo_info "purge: removed this sandbox's own files from $LT_DIR, but the directory itself could not be removed — inspect it by hand"
          fi
        else
          echo_info "purge: removed this sandbox's own files from $LT_DIR but KEPT the directory — it still holds files this sandbox did not write: $lt_leftovers. Its ownership marker and STATE.md are kept with them so a later --purge can still identify what is the sandbox's; remove the directory by hand once you have taken what you want."
        fi ;;
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
  elif [ "${PIDS_UNACTED:-0}" -gt 0 ]; then
    # Same reason, different stage. Exit 0 here would report a run that left
    # services alive as a completed teardown.
    PURGE_VERB="purge incomplete: ${PIDS_UNACTED} recorded service(s) are still running because this run could not prove they were not its own ancestors. Stop them, or re-run from a shell whose ancestry can be walked, then --purge again."
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
# A run that declined to stop recorded services has not finished either, and the
# refusals above go to stdout where a caller reading only the exit code never
# sees them. Same shape as the worktree case: "ran but stopped short" is exit 4,
# and the closing line has to name the stage rather than say "done." over it.
if [ "${PIDS_UNACTED:-0}" -gt 0 ]; then
  echo_info "clean incomplete: ${PIDS_UNACTED} recorded service(s) in $PIDS_FILE are still running — this run could not walk its own ancestry, so it could not prove they were not its own. The ledger is kept; re-run from a shell whose ancestry can be walked, or stop them by hand."
  exit 4
fi
exit 0
