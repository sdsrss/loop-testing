#!/usr/bin/env bash
# setup-marker-integrity.test.sh — sandbox-setup.sh must not announce "already
# initialized" on the strength of a marker it never checked (audit S-01, S-08).
#
# S-01: sandbox-clean validates the marker (SANDBOX_VERSION / MODE / TOP) before
# trusting a single field; setup read the same file with a bare grep|cut and
# trusted whatever came back. A worktree-mode marker whose CREATED_WORKTREE line
# is missing (truncated, hand-edited, half-written) made WT_STATE default to
# `ours`, so setup printed "already initialized", armed .active, and exited 0 —
# with NO worktree: the loop then ran against, and committed into, the main tree.
# Every worktree-mode marker since v0.1.0 writes CREATED_WORKTREE, so an empty
# one is never a live sandbox; it is a rebuild (worktree gone) at best.
#
# S-08: a CRLF marker (Windows editor, `core.autocrlf`, a copied evidence dir)
# gave setup `path\r`, which matches nothing in `git worktree list`, so a LIVE
# sandbox read as "recorded worktree is gone" and setup tried to rebuild over it.
# sandbox-clean fail-closed on the same file. Both readers now strip the CR.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

wt_count() { ( cd "$1" && git worktree list --porcelain | grep -c '^worktree ' ); }
cr_named_worktree() { ( cd "$1" && git worktree list --porcelain | grep '^worktree ' | grep -c $'\r' ); }

# Rewrite a file with CRLF line endings. NOT `sed 's/$/\r/'`: BSD/macOS sed does
# not interpret `\r` in the replacement and would append a literal `r` to every
# line, so the CRLF fixture would silently test nothing on the platform this repo
# also targets. printf is POSIX and means the same byte everywhere.
crlf_file() {
  local f="$1" t line
  t="$f.crlf.$$"
  while IFS= read -r line || [ -n "$line" ]; do printf '%s\r\n' "$line"; done < "$f" > "$t"
  mv "$t" "$f"
}

# --- A. S-01 exact: valid marker, CREATED_WORKTREE line gone, worktree gone ----
# The honest outcomes are "rebuild the worktree" or "refuse". "already
# initialized" with nothing isolated is the one outcome that must never happen.
WS=$(mk_ws); trap 'rm -rf "$WS"' EXIT
REPO="$WS/proj"; WT="$WS/proj-qa-loop"; MARKER="$REPO/docs/looptesting/.sandbox/ownership.env"
( cd "$REPO" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_ok $? "setup (A)"
( cd "$REPO" && git worktree remove --force "$WT" ) >/dev/null 2>&1
sed -i.bak '/^CREATED_WORKTREE=/d' "$MARKER"; rm -f "$MARKER.bak"
rm -f "$REPO/docs/looptesting/.active"
OUT=$( cd "$REPO" && bash "$SETUP" --mode worktree 2>&1 ); rc=$?
case "$OUT" in
  *"already initialized"*) FAIL=$((FAIL+1)); echo "  FAIL: S-01 — setup claimed 'already initialized' over a marker with no worktree recorded — got: $OUT" >&2 ;;
  *) PASS=$((PASS+1)) ;;
esac
assert_eq "0" "$rc" "the marker is otherwise valid and the path is free: setup rebuilds (exit 0)"
assert_exists "$WT" "the rebuild put a worktree back at the default path"
assert_eq "2" "$(wt_count "$REPO")" "exactly main + qa worktree registered"
assert_file_contains "$MARKER" "CREATED_WORKTREE=$WT" "the rebuilt marker records the new worktree"
assert_exists "$REPO/docs/looptesting/.active" ".active armed only once isolation exists"

# --- B. S-01 variant: worktree line gone but the LIVE worktree still stands ---
# Rebuilding over it is impossible (git holds the branch there); the answer is a
# refusal that names the path — never a green "already initialized".
WS2=$(mk_ws); trap 'rm -rf "$WS" "$WS2"' EXIT
REPO2="$WS2/proj"; WT2="$WS2/proj-qa-loop"; MARKER2="$REPO2/docs/looptesting/.sandbox/ownership.env"
( cd "$REPO2" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
sed -i.bak '/^CREATED_WORKTREE=/d' "$MARKER2"; rm -f "$MARKER2.bak"
OUT2=$( cd "$REPO2" && bash "$SETUP" --mode worktree 2>&1 ); rc=$?
case "$OUT2" in
  *"already initialized"*) FAIL=$((FAIL+1)); echo "  FAIL: S-01 — 'already initialized' over an unrecorded worktree — got: $OUT2" >&2 ;;
  *) PASS=$((PASS+1)) ;;
esac
assert_eq "6" "$rc" "setup refuses with the documented exit 6 (worktree path taken), not merely non-zero"
case "$OUT2" in *"$WT2"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: the refusal must name the path standing in the way — got: $OUT2" >&2 ;; esac
assert_exists "$WT2" "the refusal left the standing worktree alone"

# --- C. corrupted marker (SANDBOX_VERSION missing): refuse, touch nothing -----
WS3=$(mk_ws); trap 'rm -rf "$WS" "$WS2" "$WS3"' EXIT
REPO3="$WS3/proj"; WT3="$WS3/proj-qa-loop"; MARKER3="$REPO3/docs/looptesting/.sandbox/ownership.env"
( cd "$REPO3" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
( cd "$REPO3" && git worktree remove --force "$WT3" ) >/dev/null 2>&1
sed -i.bak 's/^SANDBOX_VERSION=.*/SANDBOX_VERSION=/' "$MARKER3"; rm -f "$MARKER3.bak"
rm -f "$REPO3/docs/looptesting/.active"
BEFORE3="$(cat "$MARKER3")"
OUT3=$( cd "$REPO3" && bash "$SETUP" --mode worktree 2>&1 ); rc=$?
assert_eq "9" "$rc" "corrupted marker -> exit 9 (ownership marker unreadable)"
case "$OUT3" in *"already initialized"*) FAIL=$((FAIL+1)); echo "  FAIL: corrupted marker read as initialized — got: $OUT3" >&2 ;;
  *) PASS=$((PASS+1)) ;; esac
case "$OUT3" in *"$MARKER3"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: the refusal must name the marker file — got: $OUT3" >&2 ;; esac
assert_eq "$BEFORE3" "$(cat "$MARKER3")" "the refusal did not rewrite the marker"
assert_absent "$WT3" "the refusal created no worktree"
assert_absent "$REPO3/docs/looptesting/.active" "the refusal did not arm .active"
assert_eq "1" "$(wt_count "$REPO3")" "no worktree registered by the refusal"

# --- D. truncated marker (first two lines only): refuse the same way ----------
WS4=$(mk_ws); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4"' EXIT
REPO4="$WS4/proj"; MARKER4="$REPO4/docs/looptesting/.sandbox/ownership.env"
( cd "$REPO4" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
head -2 "$MARKER4" > "$MARKER4.t" && mv "$MARKER4.t" "$MARKER4"
( cd "$REPO4" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_eq "9" "$?" "truncated marker (no TOP) -> exit 9"

# --- E. S-08: CRLF marker over a LIVE sandbox: setup short-circuits cleanly ---
WS5=$(mk_ws); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5"' EXIT
REPO5="$WS5/proj"; WT5="$WS5/proj-qa-loop"; MARKER5="$REPO5/docs/looptesting/.sandbox/ownership.env"
( cd "$REPO5" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
crlf_file "$MARKER5"
if grep -q $'\r' "$MARKER5"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: fixture — marker should be CRLF" >&2; fi
OUT5=$( cd "$REPO5" && bash "$SETUP" --mode worktree 2>&1 ); rc=$?
assert_eq "0" "$rc" "CRLF marker over a live sandbox -> exit 0"
case "$OUT5" in *"already initialized"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: S-08 — a live sandbox behind a CRLF marker must short-circuit — got: $OUT5" >&2 ;; esac
assert_eq "0" "$(cr_named_worktree "$REPO5")" "no worktree whose name ends in CR was created"
assert_eq "2" "$(wt_count "$REPO5")" "worktree count unchanged (no rebuild attempted)"
# ...and clean removes that worktree instead of fail-closing on the CR.
OUT5c=$( cd "$REPO5" && bash "$CLEAN" 2>&1 ); rc=$?
assert_eq "0" "$rc" "clean on a CRLF marker exits 0"
assert_absent "$WT5" "clean on a CRLF marker removed the recorded worktree"
case "$OUT5c" in *"unreadable"*) FAIL=$((FAIL+1)); echo "  FAIL: S-08 — clean called a CRLF marker unreadable — got: $OUT5c" >&2 ;;
  *) PASS=$((PASS+1)) ;; esac

# --- F. S-08: CRLF marker, worktree gone: rebuild lands at the CR-free path ----
WS6=$(mk_ws); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6"' EXIT
REPO6="$WS6/proj"; WT6="$WS6/proj-qa-loop"; MARKER6="$REPO6/docs/looptesting/.sandbox/ownership.env"
( cd "$REPO6" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
( cd "$REPO6" && git worktree remove --force "$WT6" ) >/dev/null 2>&1
crlf_file "$MARKER6"
( cd "$REPO6" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_eq "0" "$?" "CRLF marker + gone worktree -> rebuild exits 0"
assert_exists "$WT6" "rebuild recreated the worktree at the recorded (CR-stripped) path"
assert_eq "0" "$(cr_named_worktree "$REPO6")" "rebuild created no CR-named worktree"

# --- G. CRLF marker under --purge: identity fields still resolve --------------
WS7=$(mk_ws); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7"' EXIT
REPO7="$WS7/proj"; MARKER7="$REPO7/docs/looptesting/.sandbox/ownership.env"
( cd "$REPO7" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
crlf_file "$MARKER7"
sed -i.bak 's/^status: RUNNING/status: CONVERGED/' "$REPO7/docs/looptesting/STATE.md"; rm -f "$REPO7/docs/looptesting/STATE.md.bak"
( cd "$REPO7" && bash "$CLEAN" --purge ) >/dev/null 2>&1
assert_eq "0" "$?" "--purge on a CRLF marker exits 0"
if ( cd "$REPO7" && git rev-parse -q --verify refs/tags/qa-baseline >/dev/null 2>&1 ); then
  FAIL=$((FAIL+1)); echo "  FAIL: purge on a CRLF marker must still identify and delete the baseline tag" >&2
else PASS=$((PASS+1)); fi
assert_absent "$REPO7/docs/looptesting" "purge on a CRLF marker removed the evidence dir"

# --- H. control: branch-mode marker legitimately has no worktree -> unchanged --
WS8=$(mk_ws); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8"' EXIT
REPO8="$WS8/proj"
( cd "$REPO8" && bash "$SETUP" --mode branch ) >/dev/null 2>&1
OUT8=$( cd "$REPO8" && bash "$SETUP" --mode branch 2>&1 ); rc=$?
assert_eq "0" "$rc" "branch-mode resume exits 0"
case "$OUT8" in *"already initialized"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: branch mode has no worktree by design and must still short-circuit — got: $OUT8" >&2 ;; esac
assert_eq "1" "$(wt_count "$REPO8")" "branch-mode resume added no worktree"

# --- I. a trailing SPACE in a recorded path is data, not noise ----------------
# The S-08 CR strip must take the CR and nothing else. Stripping all trailing
# whitespace instead silently rewrites a legitimate path: a worktree directory
# whose name ends in a space is legal on every platform this runs on, and the
# marker is the only record of it. The ownership lookup then misses (the stripped
# path matches no `git worktree list` line), clean reports "already gone", and the
# worktree leaks with nothing left naming it — the exact ownership-by-text shape
# the identity work exists to remove.
WS9=$(mk_ws); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9"' EXIT
REPO9="$WS9/proj"; WT9="$WS9/qa wt "   # note the trailing space
( cd "$REPO9" && bash "$SETUP" --mode worktree --worktree-path "$WT9" ) >/dev/null 2>&1
assert_eq "0" "$?" "setup accepts a worktree path ending in a space"
assert_exists "$WT9" "the worktree really is at the space-suffixed path"
MARKER9="$REPO9/docs/looptesting/.sandbox/ownership.env"
assert_file_contains "$MARKER9" "CREATED_WORKTREE=$WT9" "the marker records the path verbatim, trailing space included"
# A resume must recognise it rather than calling it gone and rebuilding.
OUT9=$( cd "$REPO9" && bash "$SETUP" --mode worktree 2>&1 )
case "$OUT9" in *"already initialized"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: a space-suffixed worktree path must still read as ours — got: $OUT9" >&2 ;; esac
assert_eq "2" "$(wt_count "$REPO9")" "no second worktree was built alongside it"
# ...and clean must find and remove it, not report it already gone.
OUT9c=$( cd "$REPO9" && bash "$CLEAN" 2>&1 )
assert_eq "0" "$?" "clean over a space-suffixed worktree path exits 0"
assert_absent "$WT9" "clean removed the space-suffixed worktree"
case "$OUT9c" in *"already gone"*) FAIL=$((FAIL+1)); echo "  FAIL: clean lost the path to whitespace stripping and called it gone — got: $OUT9c" >&2 ;;
  *) PASS=$((PASS+1)) ;; esac

# --- J0. ONE marker reader, and both scripts reach it -------------------------
# This used to assert that the two scripts held byte-identical copies, because
# that is what they held and what both headers claimed. The claim was worth
# exactly as much as the check that held it true — six spaces of alignment
# padding once made the sentence false while every behavioural test still passed.
#
# The copies are gone: the readers live in scripts/lib.sh and both scripts source
# it. So the invariant this case defends got stronger and changed shape. It is no
# longer "the two agree" (an identical wrong edit to both passed that) but "there
# is only one definition to agree with". Three things, in the order they can
# break:
#   * lib.sh defines each reader exactly once;
#   * NEITHER script defines it again — a re-introduced local copy would SHADOW
#     the shared one silently, which is the drift this file exists to catch and
#     the only way it can come back now;
#   * both scripts actually source lib.sh, or the functions they call are simply
#     not there.
#
# WHAT THIS DOES NOT COVER, by construction and unchanged: it says nothing about
# whether the one reader is RIGHT. That half stays behavioural — cases E/F/G pin
# CRLF handling, case I pins the trailing space, case J pins the shared validity
# rule — so a reader that is single and wrong still turns this file red.
LIBSH="$(dirname "$SETUP")/lib.sh"
if [ -f "$LIBSH" ]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: scripts/lib.sh is missing — both scripts source it" >&2; fi
for _fn in mval marker_key; do
  _n_lib="$(grep -hc "^$_fn() {" "$LIBSH" 2>/dev/null)"; _n_lib="${_n_lib:-0}"
  _dup="$(grep -l "^$_fn() {" "$SETUP" "$CLEAN" 2>/dev/null)"
  if [ "$_n_lib" != "1" ]; then
    FAIL=$((FAIL+1)); echo "  FAIL: $_fn() is defined $_n_lib times in lib.sh — exactly one, or there is nothing single about it" >&2
  elif [ -n "$_dup" ]; then
    FAIL=$((FAIL+1)); echo "  FAIL: $_fn() is defined again in: $_dup — a local copy shadows the shared one" >&2
  else PASS=$((PASS+1)); fi
done
for _s in "$SETUP" "$CLEAN"; do
  if grep -q '/lib\.sh"' "$_s"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $(basename "$_s") does not source lib.sh, so the readers it calls are undefined" >&2; fi
done

# --- J. one validity rule, two scripts ----------------------------------------
# setup's comment claims it applies "the same validity rule as clean". A marker
# whose TOP is present but blank is the case that told them apart: clean's reader
# requires a non-blank first character, setup's accepted the whitespace. One
# marker must not be valid to one script and invalid to the other.
WSJ=$(mk_ws); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WSJ"' EXIT
REPOJ="$WSJ/proj"; MARKERJ="$REPOJ/docs/looptesting/.sandbox/ownership.env"
( cd "$REPOJ" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
sed -i.bak 's|^TOP=.*|TOP=   |' "$MARKERJ"; rm -f "$MARKERJ.bak"
( cd "$REPOJ" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1
assert_eq "9" "$?" "blank TOP -> setup refuses (exit 9)"
OUTJ=$( cd "$REPOJ" && bash "$CLEAN" 2>&1 )
case "$OUTJ" in *"unreadable"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: the same blank TOP must be unreadable to clean too — got: $OUTJ" >&2 ;; esac
OUTJp=$( cd "$REPOJ" && bash "$CLEAN" --purge 2>&1 )
assert_eq "3" "$?" "blank TOP -> --purge refuses (exit 3) — output: $OUTJp"

report "setup-marker-integrity.test.sh"
