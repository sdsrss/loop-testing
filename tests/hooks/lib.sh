#!/usr/bin/env bash
# Shared helpers for loop-testing hook tests. Source, don't execute.
#
# SAFETY: every hook test operates only on a throwaway workspace from mk_lt
# (mktemp -d). The hooks read cwd-relative docs/looptesting/, so tests cd into
# the workspace — they NEVER run against the real repo, $HOME, or ~/.claude.
# Each test cleans up: WS=$(mk_lt); trap 'rm -rf "$WS"' EXIT

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
STOP="$REPO_ROOT/hooks/stop-gate.sh"
LEDGER="$REPO_ROOT/hooks/ledger-gate.sh"
export STOP LEDGER

# The hooks anchor on $CLAUDE_PROJECT_DIR before anything else, and Claude Code
# sets it for every hook it runs — so a suite run from inside a session inherits
# it and every case that does not override it anchors the hook at the REAL
# project instead of its fixture (audit T-16). Measured before this line existed:
# `CLAUDE_PROJECT_DIR=<this repo> bash tests/hooks/stop-gate.test.sh` died at the
# counter read with `kc: unbound variable`, having tested nothing after case K.
# Unset it once, here, rather than per invocation: the per-case `env -u` below
# are kept as documentation, but a new case that forgets one is the normal
# outcome and this is what makes forgetting harmless. Cases that WANT the anchor
# set it explicitly on the command line, which still overrides.
unset CLAUDE_PROJECT_DIR

# Same class, different variable (review T-2). Fixtures here call `git init` in
# $TMPDIR, and git exports GIT_DIR / GIT_WORK_TREE to its own hooks, to
# `rebase --exec` and to `bisect run` — so a suite run from any of those
# inherits them. `git init -q "$DIR"` then returns 0 having created nothing at
# $DIR, every later git command in the fixture addresses the INHERITED repo, and
# a case can pass having tested an unrelated repository — while writing state
# into it. GIT_CEILING_DIRECTORIES goes too: it can stop the upward search the
# K-14 walk-up depends on, which would make those cases fail for a reason that
# has nothing to do with the code under test.
unset GIT_DIR GIT_WORK_TREE GIT_CEILING_DIRECTORIES

PASS=0
FAIL=0

# mk_lt: throwaway workspace with a docs/looptesting/ skeleton. Echoes its path.
mk_lt() {
  local ws
  # Unchecked, an empty $ws turns the mkdir below into `mkdir -p /docs/…` and
  # every later path into an absolute one outside any fixture.
  ws=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-hooks.XXXXXX") || return 1
  mkdir -p "$ws/docs/looptesting/runs"
  printf '# ISSUES\n' > "$ws/docs/looptesting/ISSUES.md"
  echo "$ws"
}

# write_state <ws> <status> <round> [converged_streak]
write_state() {
  local ws="$1" status="$2" round="$3" streak="${4:-0}"
  cat > "$ws/docs/looptesting/STATE.md" <<EOF
# STATE
\`\`\`
round: $round
converged_streak: $streak
status: $status
max_rounds: 12
\`\`\`
EOF
}

arm()   { : > "$1/docs/looptesting/.active"; }        # create sentinel
disarm(){ rm -f "$1/docs/looptesting/.active"; }

# run_stop <ws> <stop_hook_active true|false> -> sets RC and prints stderr
# CLAUDE_PROJECT_DIR is unset inside the subshell: these helpers exercise the
# cwd-fallback anchor; the env/stdin-cwd anchors have dedicated HK-7 cases.
run_stop() {
  local ws="$1" active="$2"
  ( cd "$ws" && printf '{"stop_hook_active": %s}' "$active" | env -u CLAUDE_PROJECT_DIR bash "$STOP" ) 2>/dev/null
}
run_stop_err() { # capture stderr
  local ws="$1" active="$2"
  ( cd "$ws" && printf '{"stop_hook_active": %s}' "$active" | env -u CLAUDE_PROJECT_DIR bash "$STOP" ) 2>&1 1>/dev/null
}

# run_ledger <ws> <json> -> RC via $?; runs from ws cwd
run_ledger() {
  local ws="$1" json="$2"
  ( cd "$ws" && printf '%s' "$json" | env -u CLAUDE_PROJECT_DIR bash "$LEDGER" ) >/dev/null 2>&1
}

assert_rc()     { if [ "$1" -eq "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $3 — expected rc $2 got $1" >&2; fi; }
assert_exists() { if [ -e "$1" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $2 — missing: $1" >&2; fi; }
assert_absent() { if [ ! -e "$1" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $2 — should be absent: $1" >&2; fi; }
assert_eq()     { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $3 — expected [$1] got [$2]" >&2; fi; }

report() { echo "$1: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; }
