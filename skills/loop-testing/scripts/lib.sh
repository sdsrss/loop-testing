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


# --- driver helpers ------------------------------------------------------------
# Shared by unattended-loop.sh and unattended-codex.sh, which were near-twins:
# these nine functions were byte-identical in both, 169 lines of them, including
# the 73-line redaction set that a pre-ship review had to be told about twice
# (it leaked nine PascalCase credential shapes, and the fix had to be applied to
# a second copy nobody was looking at). A redaction rule that exists twice is a
# redaction rule you have to remember to fix twice.
#
# What did NOT move, and why: roughly a dozen more functions differ between the
# two drivers only in prose, formatting, or the driver's own name in a message
# (`unattended-loop:` vs `unattended-codex:`). Measured, not assumed — the four
# that looked like a missing fix (round_of, issue_count, state_field,
# child_alive) all carry the same behaviour on both sides. Unifying those means
# parameterising the name that appears in user-visible output, which is a change
# to what the drivers print and belongs in its own pass rather than riding along
# with a mechanical move.

is_uint() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

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
  # Test seam. Never set in normal use; it exists because on Linux `[ -d /proc/self ]`
  # is always true, so the `ps` arm below — the ONLY liveness path on macOS — can
  # otherwise never be reached by any test this project can run (CI is ubuntu-only).
  local procfs="${LOOP_TESTING_PROCFS:-/proc}"
  kill -0 "$1" 2>/dev/null && { printf 'alive'; return; }
  # `kill -0` just failed, which is ESRCH (gone) or EPERM (alive, owned by
  # someone else) — indistinguishable from the shell, which is why the probes
  # below exist. Each must prove it COULD have answered before its negative
  # answer is believed: `gone` is the verdict that authorises stealing the lock,
  # so a probe that cannot see the process says `unknown`, not `gone`.
  if [ -d "$procfs/self" ]; then
    if [ -e "$procfs/$1" ]; then printf 'alive'; return; fi
    # Absent from procfs means "gone" only if this procfs shows us other
    # accounts' processes at all. Under hidepid=2 — ordinary hardening on a
    # shared box, which is the very case this fix names — it does not, and a live
    # holder owned by another account is simply invisible. PID 1 always exists,
    # so it is the canary: an invisible canary means the probe is blind, not that
    # the holder died.
    if [ -e "$procfs/1" ]; then printf 'gone'; else printf 'unknown'; fi
    return
  fi
  if command -v ps >/dev/null 2>&1; then
    if ps -p "$1" >/dev/null 2>&1; then printf 'alive'; return; fi
    # Same rule, same reason: `ps -p` exits non-zero both for "no such process"
    # and for a `ps` that could not answer at all — and `ps -o ppid= -p 999999`
    # even prints nothing while exiting 0, so status alone is not a signal here.
    #
    # The canary is PID 1, not `$$`. The whole point of a canary here is to
    # detect a probe that cannot see processes belonging to OTHER accounts —
    # which is the case the holder is in. Our own process is visible to us under
    # every such restriction, so `ps -p $$` succeeds exactly when the probe is
    # blind and would have confirmed nothing. PID 1 always exists and belongs to
    # root, so it is the smallest thing that tests the right property.
    if ps -p 1 >/dev/null 2>&1; then printf 'gone'; else printf 'unknown'; fi
    return
  fi
  printf 'unknown'
}

# The kernel reuses pids. Across a 20 s wait the session's number could come
# back as an unrelated process, and this code signals a whole process GROUP at
# the bound — so pair the pid with its start time and read a mismatch as "the
# session is gone", never as "something to kill".
proc_start() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' ' '; }

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

session_err_close() {
  [ -n "$SESSION_ERR" ] && rm -f "$SESSION_ERR"
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

# --- completion sentinel ------------------------------------------------------
# Set LAST, on purpose. A consumer's `. lib.sh || exit` proves the file PARSED,
# not that it is whole, and those are different things here: this file is several
# hundred lines with long prose blocks between functions, so a copy truncated by
# an interrupted transfer, a full disk or a partial checkout is still valid bash
# at most cut points. Measured on the cut one line above `wt_ownership() {`:
# `bash -n` clean, rc 0 from `.`, wt_ownership undefined — and sandbox-clean's
# ownership switch then read the empty output of a command that does not exist as
# a verdict and force-removed the worktree, rc 0, printing "done".
#
# So consumers check this variable AND the names they need. Neither alone is
# enough: the sentinel misses a hand-edited file that dropped one function, and a
# name list misses nothing today but says nothing about what was added later.
#
# Unused HERE and that is the point: the four consumers read it after sourcing,
# and shellcheck cannot follow a source it was told to ignore (SC1091 is excluded
# repo-wide). Left as a bare `disable=` this would be the shape the raised gate
# exists to catch, so the coupling is written down instead of papered over —
# sandbox-setup.sh, sandbox-clean.sh, unattended-loop.sh and unattended-codex.sh
# each test `[ "${LT_LIB_LOADED:-}" = 1 ]` immediately after their source block.
# shellcheck disable=SC2034
LT_LIB_LOADED=1
