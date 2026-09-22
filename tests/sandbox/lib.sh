#!/usr/bin/env bash
# Shared helpers for loop-testing sandbox-script tests. Source, don't execute.
#
# SAFETY: every sandbox test MUST operate only on a throwaway workspace created
# by mk_ws (mktemp -d). NEVER run sandbox-setup.sh / sandbox-clean.sh against the
# real repo or $HOME — these are destructive-path scripts. Each test cleans its
# own workspace on exit:  WS=$(mk_ws); trap 'rm -rf "$WS"' EXIT

# Fixtures here call `git init` in $TMPDIR; git exports GIT_DIR / GIT_WORK_TREE
# to its own hooks, to `rebase --exec` and to `bisect run`, and an inherited one
# makes `git init` a silent no-op that leaves every later git command addressing
# somebody else's repository. See the long note in tests/hooks/lib.sh (review T-2).
unset GIT_DIR GIT_WORK_TREE GIT_CEILING_DIRECTORIES

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
SETUP="$REPO_ROOT/skills/loop-testing/scripts/sandbox-setup.sh"
CLEAN="$REPO_ROOT/skills/loop-testing/scripts/sandbox-clean.sh"
export SETUP CLEAN

# TIMEOUT_BIN + bounded(): the dangling-flag guards here bound the script so a
# `shift 2` regression shows up as a timeout rather than a hung suite. They were
# calling bare `timeout`, and three of them assert `rc != 124` — which an absent
# binary satisfies with 127, so those three PASSED without running anything.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib-watchdog.sh" || {
  echo "FAILED: cannot source tests/lib-watchdog.sh — TIMEOUT_BIN, bounded and the suite-level guard are then all absent. Measured, the outcome depends on which reference comes first: set -u aborts at a bare \$TIMEOUT_BIN (stop-gate stops with no tally at all), or bounded reports command-not-found and cases fail (driver-limits: 35 passed, 3 failed). Either way the precondition guard never applies, so on a host with no watchdog binary every case runs and the run fills with the failures this lib exists to prevent." >&2
  exit 1
}

PASS=0
FAIL=0

# mk_ws: create a throwaway workspace dir containing a fresh git repo at $WS/proj.
# Echoes the workspace root (delete the whole thing to clean up). The repo lives
# in a subdir so worktree sibling paths ($WS/proj-qa-loop) stay inside $WS.
mk_ws() {
  local ws
  # EVERY step here is load-bearing, not just the first two. There is no `set -e`,
  # so an unchecked `mktemp` leaves $ws empty, the unchecked `cd ""` fails with
  # "null directory" and CONTINUES, and everything below then runs in the caller's
  # cwd — which for run-all.sh is the repository root, where `mkdir proj; git init`
  # is the last thing anyone wants. A deleted TMPDIR is only one way to get there;
  # a full or read-only TMPDIR is another.
  #
  # `mkdir proj` and `cd proj` were the two lines this paragraph described and did
  # not guard — the repair sat directly above the defect it names. Measured with a
  # FILE already at `$ws/proj`, so the mkdir fails: `git init` and the two `git
  # config` calls ran in `$ws` instead of `$ws/proj`, one level below the caller's
  # cwd rather than in it. Same shape, one directory short of the incident.
  ws=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-sb.XXXXXX") || return 1
  (
    cd "$ws" || exit 1
    mkdir proj || exit 1
    cd proj || exit 1
    git init -q
    git config user.email test@loop-testing.local
    git config user.name loop-testing-test
    printf 'node_modules/\n*.log\n' > .gitignore
    echo "sandbox target" > README.md
    git add .gitignore README.md
    git commit -qm "initial"
  ) >/dev/null || {
    # The `|| exit 1` guards above stop the stray writes; they do not stop mk_ws
    # from HANDING BACK a path whose proj/ was never built. The subshell's status
    # was discarded and `echo "$ws"` ran unconditionally, so a failed fixture
    # returned 0 with a workspace that is not one, and every assertion below it
    # then described a repository that does not exist. 96 call sites take this
    # value; none checks it, so the diagnostic has to come from here.
    echo "mk_ws: could not build the fixture workspace in ${ws:-<mktemp failed>} — every assertion after this one would be about a repository that was never created" >&2
    [ -n "$ws" ] && rm -rf "$ws"
    return 1
  }
  echo "$ws"
}

# git_has_worktree_repair — `git worktree repair` landed in git 2.30 (Jan 2021).
# Two cases below use it as the USER's route back after relocating their own
# worktree, and asserted on its exit status directly. On an older git that status
# is "no such subcommand", and the suite reported "the user can no longer repair
# their relocated worktree" — a verdict about this project's scripts produced by a
# probe that could not run. The same shape this repo has already corrected three
# times: a failed probe is not a verdict.
git_has_worktree_repair() {
  local v maj min
  v=$(git --version 2>/dev/null) || return 1
  v=${v#git version }; v=${v%% *}          # "2.39.3 (Apple Git-145)" -> "2.39.3"
  maj=${v%%.*}; min=${v#*.}; min=${min%%.*}
  case "$maj" in ''|*[!0-9]*) return 1 ;; esac
  case "$min" in ''|*[!0-9]*) return 1 ;; esac
  [ "$maj" -gt 2 ] && return 0
  [ "$maj" -eq 2 ] && [ "$min" -ge 30 ]
}

assert_eq() { # expected actual label
  if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $3 — expected [$1] got [$2]" >&2; fi
}

assert_ok() { # label ; checks $? via caller: use `if cmd; then pass; else fail`
  if [ "$1" -eq 0 ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $2 — expected success, got exit $1" >&2; fi
}

assert_nonzero() { # actual_status label
  if [ "$1" -ne 0 ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $2 — expected non-zero exit, got 0" >&2; fi
}

assert_exists() { # path label
  if [ -e "$1" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $2 — path missing: $1" >&2; fi
}

assert_absent() { # path label
  if [ ! -e "$1" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $2 — path should be absent: $1" >&2; fi
}

assert_file_contains() { # file needle label
  if grep -qF -- "$2" "$1" 2>/dev/null; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $3 — $1 lacks [$2]" >&2; fi
}

report() { # test-name
  echo "$1: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}
