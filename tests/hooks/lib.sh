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

# TIMEOUT_BIN + bounded(): stop-gate's fail-open cases use a wall-clock bound AS
# the assertion (rc 124 = the platform would have killed the hook = ALLOW), and
# they were calling bare `timeout`, which returns 127 on a host that has only
# `gtimeout` or neither. Same shape as review T-D, six sites it did not reach.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib-watchdog.sh" || {
  echo "FAILED: cannot source tests/lib-watchdog.sh — TIMEOUT_BIN, bounded and the suite-level guard are then all absent. Measured, the outcome depends on which reference comes first: set -u aborts at a bare \$TIMEOUT_BIN (stop-gate stops with no tally at all), or bounded reports command-not-found and cases fail (driver-limits: 35 passed, 3 failed). Either way the precondition guard never applies, so on a host with no watchdog binary every case runs and the run fills with the failures this lib exists to prevent." >&2
  exit 1
}

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
  # `2>&1 1>/dev/null` is the stderr-ONLY capture and the order is deliberate:
  # stderr first inherits the substitution's stdout, then stdout is dropped. The
  # order shellcheck asks for (`1>/dev/null 2>&1`) would discard both and hand
  # every caller an empty string, which is the failure mode that reads as "the
  # hook printed no diagnostic".
  # shellcheck disable=SC2069
  ( cd "$ws" && printf '{"stop_hook_active": %s}' "$active" | env -u CLAUDE_PROJECT_DIR bash "$STOP" ) 2>&1 1>/dev/null
}

# run_ledger <ws> <json> -> RC via $?; runs from ws cwd
run_ledger() {
  local ws="$1" json="$2"
  ( cd "$ws" && printf '%s' "$json" | env -u CLAUDE_PROJECT_DIR bash "$LEDGER" ) >/dev/null 2>&1
}

# set_mtime_epoch <file> <epoch> — portable `touch -d @<epoch>`, verified.
#
# GNU and uutils take `-d @<epoch>`; BSD/macOS touch does not and exits with a
# usage error. Discarded, that error leaves the file at its CURRENT mtime, and
# every "N days old" premise built on it becomes false while the case still runs.
# One of the three call sites in stop-gate.test.sh asserts that an OLD remnant
# still blocks when staleness is switched off — a premise-free file blocks for the
# ordinary reason, so that case would have passed on macOS having tested nothing.
#
# `date -r <epoch>` is the BSD spelling for formatting an epoch and GNU date
# rejects it (its -r takes a FILE), so the second branch only yields a stamp on
# the platform it exists for.
#
# The result is checked, not assumed: a reference file created now must be NEWER
# than the target. That is what makes "the touch silently did nothing" a failure
# here instead of a green case somewhere else.
set_mtime_epoch() {
  local f="$1" e="$2" stamp ref rc=0
  if ! touch -d "@$e" "$f" 2>/dev/null; then
    stamp=$(date -r "$e" +%Y%m%d%H%M.%S 2>/dev/null) || return 1
    touch -t "$stamp" "$f" 2>/dev/null || return 1
  fi
  ref="$f.mtimeref.$$"
  : > "$ref" || return 1
  [ "$f" -ot "$ref" ] || rc=1
  rm -f "$ref"
  return "$rc"
}

# age_file <file> <seconds-ago> <what-it-is-for> — set_mtime_epoch as a COUNTED
# assertion, so the premise is reported in both directions rather than only when
# something downstream happens to notice.
age_file() {
  if set_mtime_epoch "$1" "$(( $(date +%s) - $2 ))"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "  FAIL: fixture: could not age $1 by ${2}s — $3" >&2
  fi
}

# mk_gtimeout_farm <dir> — a PATH directory that is the macOS arm: everything the
# hooks need EXCEPT `timeout`, plus a `gtimeout` that records each call in
# <dir>/gtimeout.calls and then runs the command it was given.
#
# Built by copying /bin and /usr/bin rather than from a remembered tool list: a
# hand-written list in this tree has already omitted `env` and then `tail`, and
# each omission surfaced as a case failing with a message that read like a defect
# in the thing under test and was the harness's own missing tool.
#
# The shim strips timeout's own leading arguments itself instead of delegating to
# a real watchdog binary. Delegating would make the case depend on the host having
# `timeout` — the very binary this arm is defined by NOT having — so a host
# without one would silently test nothing.
mk_gtimeout_farm() {
  local d="$1" fp c p
  for fp in /bin/* /usr/bin/*; do
    [ -x "$fp" ] && ln -sf "$fp" "$d/${fp##*/}" 2>/dev/null
  done
  for c in git jq python3 bash; do
    p=$(command -v "$c" 2>/dev/null) && [ -n "$p" ] && ln -sf "$p" "$d/$c" 2>/dev/null
  done
  : "${d:?}" && rm -f "$d/timeout" "$d/gtimeout"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "call\\n" >> "%s/gtimeout.calls"\n' "$d"
    printf 'while [ $# -gt 0 ]; do case "$1" in -k) shift 2 ;; -*) shift ;; [0-9]*) shift; break ;; *) break ;; esac; done\n'
    printf 'exec "$@"\n'
  } > "$d/gtimeout"
  chmod +x "$d/gtimeout"
}

assert_rc()     { if [ "$1" -eq "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $3 — expected rc $2 got $1" >&2; fi; }
assert_exists() { if [ -e "$1" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $2 — missing: $1" >&2; fi; }
assert_absent() { if [ ! -e "$1" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $2 — should be absent: $1" >&2; fi; }
assert_eq()     { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $3 — expected [$1] got [$2]" >&2; fi; }

report() { echo "$1: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; }
