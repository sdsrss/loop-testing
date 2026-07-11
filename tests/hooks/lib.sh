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

PASS=0
FAIL=0

# mk_lt: throwaway workspace with a docs/looptesting/ skeleton. Echoes its path.
mk_lt() {
  local ws
  ws=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-hooks.XXXXXX")
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
run_stop() {
  local ws="$1" active="$2"
  ( cd "$ws" && printf '{"stop_hook_active": %s}' "$active" | bash "$STOP" ) 2>/dev/null
}
run_stop_err() { # capture stderr
  local ws="$1" active="$2"
  ( cd "$ws" && printf '{"stop_hook_active": %s}' "$active" | bash "$STOP" ) 2>&1 1>/dev/null
}

# run_ledger <ws> <json> -> RC via $?; runs from ws cwd
run_ledger() {
  local ws="$1" json="$2"
  ( cd "$ws" && printf '%s' "$json" | bash "$LEDGER" ) >/dev/null 2>&1
}

assert_rc()     { if [ "$1" -eq "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $3 — expected rc $2 got $1" >&2; fi; }
assert_exists() { if [ -e "$1" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $2 — missing: $1" >&2; fi; }
assert_absent() { if [ ! -e "$1" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $2 — should be absent: $1" >&2; fi; }
assert_eq()     { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $3 — expected [$1] got [$2]" >&2; fi; }

report() { echo "$1: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; }
