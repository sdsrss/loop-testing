#!/usr/bin/env bash
# Shared helpers for the loop-testing sandbox scripts. Source, never execute.
#
# WHY this file exists. Until now `sandbox-setup.sh` and `sandbox-clean.sh` each
# carried their own copy of the marker readers and the worktree-identity logic —
# 195 lines of it, byte-identical by hand. Both files said so in prose and asked
# the next reader to keep it that way: "byte-identical to sandbox-clean.sh's, and
# deliberately so: one marker must not be valid to one script and invalid to the
# other". That is an invariant a comment cannot hold. This project's own record
# is that it does not hold: the H-03 repair re-committed the very shape it was
# fixing in the second copy, and the `assert_path` incident was one helper living
# in one lib and called from a suite sourcing another. A guarantee written as a
# request to the reader is the root cause of "fix it twice, miss the second".
#
# So the rule here is structural rather than aspirational: if both scripts must
# agree about a marker or about who owns a worktree, the code that decides lives
# in this file and nowhere else.
#
# This file defines functions and does nothing else — no side effects at source
# time, so the order a caller sources it in cannot matter. The functions read
# globals ($MARKER, $TOP) that each script sets; a shell resolves those at CALL
# time, which is why moving the definitions here changes nothing about when they
# are read.
#
# It ships automatically: install/install-codex.sh copies skills/loop-testing/
# whole, so anything in this directory travels with the scripts that source it.
# hooks/ is deliberately NOT part of that copy (Codex has no Stop-hook
# mechanism), which is why the hooks keep their own copies of what they need —
# a shared file across two separately distributed artifacts would be a file one
# of them could arrive without.

# --- marker readers -----------------------------------------------------------
# Marker fields are read by PARSING, never by sourcing: a tampered marker must
# not run. Two readers, and the difference between them is the validity rule:
#   mval       — the value of a key, verbatim.
#   marker_key — the same, but only when the value's first character is not
#                blank. A key present with an empty or whitespace-only value
#                carries no information, and the three keys every marker has
#                written since v0.1.0 (SANDBOX_VERSION, MODE, TOP) are checked
#                with this one before either script trusts a field.
#
# Only the trailing CR is stripped, and only one. A CRLF marker — a Windows
# editor, core.autocrlf, an evidence dir copied through a zip — used to hand back
# `path\r`, which matches no line of `git worktree list`. The two scripts then
# disagreed about the same bytes: clean refused the file as unreadable while
# setup called a LIVE worktree gone and rebuilt over it, at a path whose last byte
# was the CR (audit S-08). Stripping all trailing WHITESPACE instead would fix
# that and break something worse: a directory name may legally end in a space,
# the marker is the only record of the path, and a silently shortened path makes
# the sandbox's own worktree unrecognisable to both scripts — the
# ownership-by-text failure this whole area exists to remove.
#
# Parameter expansion, not `sed 's/\r$//'`: BSD sed does not interpret `\r` and
# would eat a trailing literal `r` instead.
mval() { local v; v="$(grep -aE "^$1=" "$MARKER" 2>/dev/null | head -1 | cut -d= -f2-)"; printf '%s' "${v%$'\r'}"; }
marker_key() { local v; v="$(grep -aE "^$1=[^[:space:]]" "$MARKER" 2>/dev/null | head -1 | cut -d= -f2-)"; printf '%s' "${v%$'\r'}"; }

# --- worktree identity --------------------------------------------------------
# Ownership recorded as a PATH is not ownership: after a clean the path is free,
# and a user who chose it with --worktree-path may well reuse it. Each sandbox
# therefore stamps a nonce inside its worktree's own git admin dir, which git
# deletes together with the worktree — so the stamp cannot outlive the thing it
# identifies, and a worktree recreated at the same path does not inherit it.

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

# Ownership of the worktree registered at $1, given the stamp $2 and branch $3
# from the marker. Prints exactly one word, and "cannot tell" is its own answer:
#   absent   nothing is registered at that path
#   stale    registered, but the directory is gone — a dangling registration
#   legacy   the marker records no stamp (sandbox predates stamping) — caller
#            keeps the old path-only behavior rather than inventing a refusal
#   ours     stamp matches, or the stamp file is gone but the branch still matches
#   foreign  something else is standing there
#   unknown  the question could not be answered — never a licence to delete
#
# `stale` is the correction this extraction carried in: BOTH copies of this
# header listed five verdicts and the code has printed six since the dangling-
# registration branch was added, while both callers already had an explicit
# `stale)` arm (sandbox-setup.sh, sandbox-clean.sh). A contract under-reporting
# its own return values, in the function whose entire job is to be trusted about
# ownership, duplicated so the drift had to be found twice to be fixed once.
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
