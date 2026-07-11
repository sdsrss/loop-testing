#!/usr/bin/env bash
# Shared helpers for loop-testing sandbox-script tests. Source, don't execute.
#
# SAFETY: every sandbox test MUST operate only on a throwaway workspace created
# by mk_ws (mktemp -d). NEVER run sandbox-setup.sh / sandbox-clean.sh against the
# real repo or $HOME — these are destructive-path scripts. Each test cleans its
# own workspace on exit:  WS=$(mk_ws); trap 'rm -rf "$WS"' EXIT

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
SETUP="$REPO_ROOT/skills/loop-testing/scripts/sandbox-setup.sh"
CLEAN="$REPO_ROOT/skills/loop-testing/scripts/sandbox-clean.sh"
export SETUP CLEAN

PASS=0
FAIL=0

# mk_ws: create a throwaway workspace dir containing a fresh git repo at $WS/proj.
# Echoes the workspace root (delete the whole thing to clean up). The repo lives
# in a subdir so worktree sibling paths ($WS/proj-qa-loop) stay inside $WS.
mk_ws() {
  local ws
  ws=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-sb.XXXXXX")
  (
    cd "$ws"
    mkdir proj
    cd proj
    git init -q
    git config user.email test@loop-testing.local
    git config user.name loop-testing-test
    printf 'node_modules/\n*.log\n' > .gitignore
    echo "sandbox target" > README.md
    git add .gitignore README.md
    git commit -qm "initial"
  ) >/dev/null
  echo "$ws"
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
