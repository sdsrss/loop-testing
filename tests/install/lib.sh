#!/usr/bin/env bash
# Shared helpers for install/ component tests. Sourced by *.test.sh.
# Every test runs entirely inside a mktemp sandbox and NEVER writes real $HOME
# or the real ~/.codex — the installer is always invoked with --target <sandbox>.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$REPO_ROOT/install/install-codex.sh"

_fails=0
_name="${0##*/}"
# Assertion counters. `_fails` stays a 0/1 exit flag; these two feed the tally
# line `finish` prints, which tests/run-all.sh sums into its TOTAL. Every suite
# must report a tally — a suite that prints none, or reports zero assertions,
# is a gate failure there rather than a silent pass (audit T-03/T-04).
_pass=0
_failn=0

pass() { printf '  ok: %s\n' "$1"; _pass=$((_pass + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; _fails=1; _failn=$((_failn + 1)); }

assert_path()    { if [ -e "$1" ]; then pass "exists: $1"; else fail "missing: $1 ($2)"; fi; }
assert_no_path() { if [ ! -e "$1" ]; then pass "absent: $1"; else fail "should not exist: $1 ($2)"; fi; }
assert_eq()      { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (want '$2', got '$1')"; fi; }
assert_ne()      { if [ "$1" != "$2" ]; then pass "$3"; else fail "$3 (both '$1')"; fi; }
# `--` before the needle: without it a needle that starts with a dash — `--target`,
# `-h`, any flag this installer's messages are supposed to name — is parsed as a
# grep option, and the assertion dies with a usage error instead of asserting.
# The sandbox and driver libs already terminate their options this way.
assert_contains(){ if printf '%s' "$1" | grep -qF -- "$2"; then pass "$3"; else fail "$3 (missing '$2')"; fi; }

# Make a fresh sandbox skills dir; echo its path. Registers cleanup via trap.
make_sandbox() {
  local d
  # Unchecked, an empty $d makes every caller's --target an absolute path outside
  # any fixture — and this one hands that path to an installer.
  d="$(mktemp -d "${TMPDIR:-/tmp}/loop-install-test.XXXXXX")" || return 1
  printf '%s\n' "$d"
}

finish() {
  # Same one-line format the sandbox/driver/hook suites use, so run-all.sh has a
  # single shape to parse: "<suite>: <N> passed, <M> failed".
  printf '%s: %d passed, %d failed\n' "$_name" "$_pass" "$_failn"
  [ "$_fails" -eq 0 ]
}
