#!/usr/bin/env bash
# Shared helpers for install/ component tests. Sourced by *.test.sh.
# Every test runs entirely inside a mktemp sandbox and NEVER writes real $HOME
# or the real ~/.codex — the installer is always invoked with --target <sandbox>.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$REPO_ROOT/install/install-codex.sh"

_fails=0
_name="${0##*/}"

pass() { printf '  ok: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; _fails=1; }

assert_path()    { if [ -e "$1" ]; then pass "exists: $1"; else fail "missing: $1 ($2)"; fi; }
assert_no_path() { if [ ! -e "$1" ]; then pass "absent: $1"; else fail "should not exist: $1 ($2)"; fi; }
assert_eq()      { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (want '$2', got '$1')"; fi; }
assert_ne()      { if [ "$1" != "$2" ]; then pass "$3"; else fail "$3 (both '$1')"; fi; }
assert_contains(){ if printf '%s' "$1" | grep -qF "$2"; then pass "$3"; else fail "$3 (missing '$2')"; fi; }

# Make a fresh sandbox skills dir; echo its path. Registers cleanup via trap.
make_sandbox() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/loop-install-test.XXXXXX")"
  printf '%s\n' "$d"
}

finish() {
  if [ "$_fails" -eq 0 ]; then printf '%s: PASS\n' "$_name"; exit 0
  else printf '%s: FAIL\n' "$_name"; exit 1; fi
}
