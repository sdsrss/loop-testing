#!/usr/bin/env bash
# sandbox-fixture.test.sh — mk_ws is load-bearing for 96 assertions, so it has to
# fail closed.
#
# mk_ws builds the throwaway git repository every tests/sandbox/ suite runs
# against. Thirteen suites call it, ninety-six times, and NOT ONE checks its
# return value — the value is used as `$WS/proj` two lines later. That is fine
# only while mk_ws cannot hand back a workspace it did not build.
#
# It could. The `|| exit 1` guards inside its subshell (added when the unchecked
# `cd proj` was found) stop the stray writes; they do not stop the function from
# printing the path anyway, because the subshell's status was discarded and
# `echo "$ws"` ran unconditionally. A fixture that died halfway returned 0 with a
# directory whose `proj/` does not exist, and the suite that received it then made
# assertions about a repository that was never created. Those assertions fail —
# loudly enough — but they name the wrong thing: the script under test, not the
# fixture. This suite is what makes the diagnosis come from mk_ws.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$REPO_ROOT/tests/sandbox/lib.sh"

_name="${0##*/}"

count_ws() { find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'loop-testing-sb.*' -type d 2>/dev/null | wc -l | tr -d ' '; }

# --- control: an intact fixture is built and reported -------------------------
# Without this, every assertion below is satisfied by a mk_ws that always fails.
CTL=$(mk_ws); ctl_rc=$?
assert_eq "0" "$ctl_rc" "control: mk_ws succeeds on this host"
if [ -n "$CTL" ] && [ -d "$CTL/proj/.git" ]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: control: mk_ws returned [$CTL] with no proj/.git — the rest of this suite proves nothing" >&2; fi
[ -n "$CTL" ] && rm -rf "$CTL"

# --- a fixture that dies halfway must not be handed out -----------------------
# `git` is shadowed by a function, which the subshell inherits: mktemp, cd and
# mkdir still work, so the guards inside do NOT fire and the failure lands exactly
# where it used to be swallowed — on the subshell's own exit status.
BEFORE=$(count_ws)
git() { return 1; }
BROKEN=$(mk_ws 2>/dev/null); broken_rc=$?
unset -f git

assert_nonzero "$broken_rc" "mk_ws reports failure when the fixture repo could not be built"
if [ -z "$BROKEN" ]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: mk_ws printed a path [$BROKEN] for a workspace it did not finish building — 96 call sites take that value unchecked" >&2; fi
AFTER=$(count_ws)
assert_eq "$BEFORE" "$AFTER" "the half-built workspace was removed rather than left in \$TMPDIR"

# The diagnosis has to come from mk_ws: the calling suite cannot produce it,
# because it never sees the status.
ERRTXT=$( { git() { return 1; }; mk_ws >/dev/null; unset -f git; } 2>&1 )
case "$ERRTXT" in
  *"mk_ws:"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: mk_ws failed silently — the suite that receives it has no way to say why — got: [$ERRTXT]" >&2 ;;
esac

report "$_name"
