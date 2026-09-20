#!/usr/bin/env bash
# reanchor-identity.test.sh — when invoked from inside a linked worktree, the
# sandbox scripts re-anchor to the MAIN tree. They used to guess it as "whatever
# repository contains the parent of git-common-dir" (audit S-02): with a
# --separate-git-dir, or a bare repository, that lives inside ANOTHER repo (the
# classic ~ dotfiles repo), the guess is the outer repo — and the whole sandbox
# (tag, branch, worktree, docs/looptesting) was built there.
#
# A candidate main tree is accepted only when ITS git-common-dir is the one we
# started from. Nothing else is evidence of being the same repository.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

git_init_repo() { # dir [extra git-init args...]
  local d="$1"; shift
  mkdir -p "$d"
  ( cd "$d" && git init -q "$@" && git config user.email t@t && git config user.name t \
    && echo x > f.txt && git add f.txt && git commit -qm init ) >/dev/null 2>&1
}
has_tag()    { ( cd "$1" && git rev-parse -q --verify refs/tags/qa-baseline >/dev/null 2>&1 ); }
has_branch() { ( cd "$1" && git rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 ); }
outer_untouched() { # repo label — the outer repository must gain no ref and no evidence dir
  if has_tag "$1";    then FAIL=$((FAIL+1)); echo "  FAIL: $2 — the baseline tag landed on the OUTER repo" >&2; else PASS=$((PASS+1)); fi
  if has_branch "$1"; then FAIL=$((FAIL+1)); echo "  FAIL: $2 — the qa branch landed on the OUTER repo" >&2;    else PASS=$((PASS+1)); fi
  assert_absent "$1/docs/looptesting" "$2 — no evidence dir was created in the outer repo"
}

# --- A. --separate-git-dir inside an outer repo -------------------------------
# git itself lists the GIT DIR as the main entry of `git worktree list` for this
# layout and cannot name the main tree from the linked worktree (no back-pointer
# from a separate git dir to its work tree). So the only honest re-anchor is
# none: the sandbox stays in the worktree it was invoked from — the SAME
# repository — and the outer repo is never touched.
WS=$(mk_ws); trap 'rm -rf "$WS"' EXIT
OUTER="$WS/outer"; INNER="$OUTER/inner"; INNER_WT="$OUTER/inner-wt"
git_init_repo "$OUTER"
git_init_repo "$INNER" --separate-git-dir "$OUTER/inner.git"
( cd "$INNER" && git worktree add -q "$INNER_WT" >/dev/null 2>&1 ) || { echo "fixture: worktree add failed" >&2; exit 1; }
OUT=$( cd "$INNER_WT" && bash "$SETUP" --mode worktree 2>&1 ); rc=$?
assert_eq "0" "$rc" "setup from the inner repo's linked worktree exits 0"
outer_untouched "$OUTER" "S-02 (separate-git-dir)"
if has_tag "$INNER"; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: the baseline tag must be on the inner repo (the one we were in)" >&2; fi
case "$OUT" in *"re-anchoring to the main tree: $OUTER"*) FAIL=$((FAIL+1)); echo "  FAIL: S-02 — re-anchored to the outer repo — got: $OUT" >&2 ;;
  *) PASS=$((PASS+1)) ;; esac
assert_exists "$INNER_WT/docs/looptesting/.sandbox/ownership.env" "with no main tree to find, the marker lives where setup was invoked"
# clean from the same place finds that marker and removes the sandbox worktree
QA_WT="$(sed -n 's/^CREATED_WORKTREE=//p' "$INNER_WT/docs/looptesting/.sandbox/ownership.env")"
assert_exists "$QA_WT" "fixture: the sandbox worktree exists"
( cd "$INNER_WT" && bash "$CLEAN" ) >/dev/null 2>&1
assert_eq "0" "$?" "clean from the inner linked worktree exits 0"
assert_absent "$QA_WT" "clean found the marker and removed the sandbox worktree"
outer_untouched "$OUTER" "S-02 (separate-git-dir, after clean)"

# --- B. bare repo inside an outer repo: no main tree exists ------------------
# Nothing to re-anchor to. Whatever setup does with the layout, it must not do it
# to the outer repository.
WS2=$(mk_ws); trap 'rm -rf "$WS" "$WS2"' EXIT
OUTER2="$WS2/outer"; BARE2="$OUTER2/proj.git"; WT2="$OUTER2/proj-wt"
git_init_repo "$OUTER2"
git init -q --bare "$BARE2" >/dev/null 2>&1
( cd "$OUTER2" && git -C "$BARE2" worktree add -q "$WT2" >/dev/null 2>&1 ) # empty bare: creates an orphan-ish checkout
( cd "$WT2" && git config user.email t@t && git config user.name t && echo y > g.txt && git add g.txt && git commit -qm init ) >/dev/null 2>&1
OUT2=$( cd "$WT2" && bash "$SETUP" --mode worktree 2>&1 )
outer_untouched "$OUTER2" "S-02 (bare)"
case "$OUT2" in *"re-anchoring to the main tree: $OUTER2"*) FAIL=$((FAIL+1)); echo "  FAIL: S-02 (bare) — re-anchored to the outer repo — got: $OUT2" >&2 ;;
  *) PASS=$((PASS+1)) ;; esac
if has_tag "$WT2"; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: S-02 (bare) — the baseline tag must be on the repository we were in" >&2; fi

# --- C. control: an ordinary repo still re-anchors from its linked worktree ---
WS3=$(mk_ws); trap 'rm -rf "$WS" "$WS2" "$WS3"' EXIT
REPO3="$WS3/proj"; OTHER3="$WS3/proj-other"
( cd "$REPO3" && git worktree add -q -b other "$OTHER3" ) >/dev/null 2>&1
OUT3=$( cd "$OTHER3" && bash "$SETUP" --mode worktree 2>&1 ); rc=$?
assert_eq "0" "$rc" "control: setup from a linked worktree of a normal repo exits 0"
case "$OUT3" in *"re-anchoring to the main tree: $REPO3"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: control — expected re-anchor to $REPO3 — got: $OUT3" >&2 ;; esac
assert_exists "$REPO3/docs/looptesting/.sandbox/ownership.env" "control: marker in the main tree"
assert_absent "$OTHER3/docs/looptesting" "control: nothing built inside the linked worktree"

report "reanchor-identity.test.sh"
