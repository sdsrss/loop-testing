#!/usr/bin/env bash
# Regression cover for the suite-level precondition protocol in tests/run-all.sh.
#
# WHY this file exists. The protocol lets a suite stop before its first case and
# have the run stay green — the one thing this repo has most reason to distrust,
# having once printed ALL GREEN over 12 of 35 suites. Its checks were written
# fail-closed and verified by injecting each break into a throwaway fixture, which
# is the convention the runner's other gates were built on. That was not enough:
# an independent review of the protocol found four defects in it, and every one
# would have been caught by running the breaks again — a rejected claim dropped
# the offending suite's whole tally out of TOTAL, failures included; a rejected
# suite was also announced `ok:` one line later; `head -1` let a first declaration
# speak for a second the runner would have refused; and a CRLF token was refused
# with a message that printed the token it was refusing, CR invisible.
#
# So the breaks live here now rather than in a scratch directory. Each scenario
# runs the REAL tests/run-all.sh against a fixture repo and asserts two things:
# that the output names the right cause, and that the verdict is right. Naming the
# cause matters as much as the verdict — three of the four defects above produced
# a correct FAILED for a reason the output stated wrongly or not at all.
#
# Deliberately asserted on TEXT and VERDICT, never on totals: the fixture's
# numbers depend on whether the host has node, and a suite that pins them would
# fail on a host it has nothing to say about.
set -u
cd "$(cd "$(dirname "$0")" && pwd)/../.." || { echo "FAILED: cannot cd to repo root"; exit 1; }

# For TIMEOUT_BIN only. One scenario below needs the HOST to have a watchdog
# binary — it checks that a suite claiming the binary is missing where one exists
# is refused — and this file is itself run on the binary-less arm, where that
# premise does not hold. Resolved from the shared lib rather than re-derived here,
# so there is still one answer to the question in this tree.
. "$(cd "$(dirname "$0")" && pwd)/../lib-watchdog.sh"

PASS=0
FAIL=0

WORK=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-meta.XXXXXX") || { echo "FAILED: mktemp"; exit 1; }
trap 'chmod -R u+w "${WORK:?}" 2>/dev/null; rm -rf "${WORK:?}"' EXIT

# --- the fixture repo ---------------------------------------------------------
# The smallest tree tests/run-all.sh will run: it gates on zero discovery in four
# places, so skills/, hooks/, install/ and tests/moa/ all have to exist and hold
# something. `good.test.sh` is the control suite that must stay unaffected by
# whatever `mut.test.sh` does.
R="$WORK/repo"
mkdir -p "$R/skills" "$R/hooks" "$R/install" "$R/tests/moa" "$R/tests/fake" "$WORK/tmp"
printf '#!/usr/bin/env bash\necho x\n' > "$R/skills/x.sh"
cp "$R/skills/x.sh" "$R/hooks/x.sh"
cp "$R/skills/x.sh" "$R/install/x.sh"
cp tests/run-all.sh "$R/tests/run-all.sh"
printf "import {test} from 'node:test';\ntest('t', () => {});\n" > "$R/tests/moa/ok.test.mjs"
printf '#!/usr/bin/env bash\necho "good.test.sh: 3 passed, 0 failed"\n' > "$R/tests/fake/good.test.sh"
MUT="$R/tests/fake/mut.test.sh"

# --- a PATH that resolves no watchdog binary ----------------------------------
# Everything executable in /bin and /usr/bin, minus the two binaries under test.
# An explicit hand-written tool list was tried first and is the wrong instrument:
# it omitted `env`, then `tail`, and each omission surfaced as scenarios failing
# with a message that read like a protocol defect and was the harness's own
# missing tool. That is the same mistake, in the same file, that this release
# spent seven commits removing from the suites — so the farm is built by copying
# a directory rather than by remembering a list.
FARM="$WORK/bin"
mkdir -p "$FARM"
for fp in /bin/* /usr/bin/*; do
  [ -x "$fp" ] && ln -sf "$fp" "$FARM/${fp##*/}" 2>/dev/null
done
: "${FARM:?}" && rm -f "$FARM/timeout" "$FARM/gtimeout"
# node commonly lives outside both directories; the runner has its own branch for
# an absent node, so this is best-effort rather than required.
fnode=$(command -v node 2>/dev/null) || fnode=""
[ -n "$fnode" ] && ln -sf "$fnode" "$FARM/node"

# The control, first and counted. If this PATH still resolves either binary then
# every binary-less scenario below proves nothing, and a probe that cannot answer
# must never be read as the answer. The spot-check on the other side matters just
# as much: a farm missing the tools the runner needs fails the scenarios for a
# reason that has nothing to do with the protocol.
farm_wd="$(PATH="$FARM" command -v timeout 2>/dev/null)$(PATH="$FARM" command -v gtimeout 2>/dev/null)"
farm_missing=""
for tool in bash dirname find sort mktemp cat grep wc tr chmod rm sed head tail; do
  PATH="$FARM" command -v "$tool" >/dev/null 2>&1 || farm_missing="$farm_missing $tool"
done
if [ -z "$farm_wd" ] && [ -z "$farm_missing" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "  FAIL: the synthesized PATH is not the host this file claims to synthesize —" >&2
  [ -n "$farm_wd" ] && echo "        it still resolves a watchdog binary [$farm_wd]" >&2
  [ -n "$farm_missing" ] && echo "        it is missing:$farm_missing" >&2
fi

# run_inner <host|farm> [NAME=value…] -> the run's combined output
#
# No `env`: the synthesized PATH holds only what the runner itself needs, and
# reaching for a tool that is not on it produced `env: command not found` inside
# nine scenarios — failures that looked like protocol defects and were the
# harness's, which is the shape this whole release is about. Assignments are
# matched by name instead, and an unrecognised one fails rather than being
# silently dropped.
run_inner() {
  local mode="$1"; shift
  (
    cd "$R" || exit 1
    [ "$mode" = farm ] && PATH="$FARM"
    export PATH
    # The inner runner exports a $TMPDIR of its own and cleans it up, but it
    # derives it from ours — so fourteen inner runs would each create and remove a
    # root inside the root the OUTER runner is watching, and one failed cleanup
    # would be reported against this suite. Give them somewhere of their own.
    TMPDIR="$WORK/tmp"
    export TMPDIR
    # Isolate the knob this file is about, every time, and set it only when a
    # scenario asks. Inherited instead, it silently reverses two of them: running
    # the OUTER suite with LOOP_TESTING_ALLOW_SKIP=1 handed the value to every
    # inner run, so "an unacknowledged skip fails the run" passed its skip through
    # acknowledged and the assertion failed for a reason that was the harness's.
    # Audit T-16, same shape: a case that does not neutralise an ambient variable
    # is testing the environment it happens to be in.
    unset LOOP_TESTING_ALLOW_SKIP
    while [ "$#" -gt 0 ]; do
      case "$1" in
        LOOP_TESTING_ALLOW_SKIP=*)
          LOOP_TESTING_ALLOW_SKIP=${1#*=}
          export LOOP_TESTING_ALLOW_SKIP ;;
        *)
          echo "run_inner: unknown assignment [$1]" >&2; exit 1 ;;
      esac
      shift
    done
    bash tests/run-all.sh </dev/null 2>&1
  )
}

# scenario <label> <mode> <expected-verdict> <expected-cause> [env…]
# Two assertions, always: the cause and the verdict. On failure the inner output
# is printed indented by four spaces, which keeps its own tally and `skip:` lines
# from being read as this suite's by the runner one level up.
scenario() {
  local label="$1" mode="$2" verdict="$3" cause="$4"; shift 4
  local out
  out=$(run_inner "$mode" "$@")
  case "$out" in
    *"$cause"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1))
       echo "  FAIL: $label — output does not name the cause [$cause]" >&2
       printf '%s\n' "$out" | sed 's/^/    /' >&2 ;;
  esac
  case "$out" in
    *"$verdict"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1))
       echo "  FAIL: $label — verdict is not [$verdict]" >&2
       printf '%s\n' "$out" | sed 's/^/    /' >&2 ;;
  esac
}

# --- the five ways to break the protocol, each fail-closed --------------------
printf '#!/usr/bin/env bash\necho "PRECONDITION NOT MET: watchdog-binary"\nexit 0\n' > "$MUT"
scenario "declared but exited 0" host "FAILED" "but exited 0, not 77"

printf '#!/usr/bin/env bash\necho nothing\nexit 77\n' > "$MUT"
scenario "exited 77 with no declaration" host "FAILED" "exited 77 (skip) but declared no precondition"

printf '#!/usr/bin/env bash\necho "PRECONDITION NOT MET: no-such-token"\nexit 77\n' > "$MUT"
scenario "unknown token" farm "FAILED" "declared an unknown precondition"

# Premise-guarded: this is the one scenario whose subject is the HOST having a
# watchdog binary, and this file runs on the arm where it does not. Counting
# nothing there is right; asserting it would fail a host the scenario has nothing
# to say about. The `skip:` line is what the runner's case-skips field counts.
if [ -n "$TIMEOUT_BIN" ]; then
  printf '#!/usr/bin/env bash\necho "PRECONDITION NOT MET: watchdog-binary"\nexit 77\n' > "$MUT"
  scenario "claimed on a host that has one" host "FAILED" "but $TIMEOUT_BIN is on PATH"
else
  echo "  skip: no timeout/gtimeout on PATH — the refusal of a false watchdog claim needs a host that has one"
fi

printf '#!/usr/bin/env bash\necho "mut.test.sh: 9 passed, 4 failed"\necho "PRECONDITION NOT MET: watchdog-binary"\nexit 77\n' > "$MUT"
scenario "skipped yet reported assertions" farm "FAILED" "but also reported assertions"

# --- and the four repairs the review produced --------------------------------
# The failures of a rejected claim must reach the TOTAL line. This is the defect
# that made the runner under-report failures it had already printed, so the
# assertion is on the number, not on a message.
printf '#!/usr/bin/env bash\necho "mut.test.sh: 9 passed, 4 failed"\necho "PRECONDITION NOT MET: watchdog-binary"\nexit 77\n' > "$MUT"
scenario "a rejected claim still counts its failures" farm ", 4 failed," "but also reported assertions"

printf '#!/usr/bin/env bash\necho "mut.test.sh: 6 passed, 0 failed"\necho "PRECONDITION NOT MET: watchdog-binary"\nexit 0\n' > "$MUT"
scenario "a rejected claim is not announced ok" host "NOT A SKIP" "but exited 0, not 77"

printf '#!/usr/bin/env bash\necho "PRECONDITION NOT MET: watchdog-binary"\necho "PRECONDITION NOT MET: no-such-token"\nexit 77\n' > "$MUT"
scenario "two declarations" farm "FAILED" "precondition declarations"

printf '#!/usr/bin/env bash\nprintf "PRECONDITION NOT MET: watchdog-binary\\r\\n"\nexit 77\n' > "$MUT"
scenario "a CR in the token is shown, not hidden" farm "FAILED" 'watchdog-binary\r'

# --- the honest skip, and what it costs --------------------------------------
# A correct skip is verified and counted — and by default it still fails the run,
# because the exit status is the only part of this output that CI reads.
printf '#!/usr/bin/env bash\necho "PRECONDITION NOT MET: watchdog-binary"\nexit 77\n' > "$MUT"
scenario "a correct skip is honoured" farm "SKIP: tests/fake/mut.test.sh" "1 skipped"
scenario "an unacknowledged skip fails the run" farm "FAILED" "did not run on this host"
scenario "acknowledged, the same run is green" farm "ALL GREEN (1 suite(s) skipped" "1 skipped" \
  LOOP_TESTING_ALLOW_SKIP=1
# Fail-closed on the acknowledgement itself: any value but 1 leaves it refused.
scenario "a mistyped acknowledgement is refused" farm "FAILED" "did not run on this host" \
  LOOP_TESTING_ALLOW_SKIP=yes

# --- and the control: an ordinary suite is untouched by all of it -------------
printf '#!/usr/bin/env bash\necho "mut.test.sh: 2 passed, 0 failed"\n' > "$MUT"
scenario "an ordinary suite still passes" host "ALL GREEN" ", 0 skipped, 0 case-skips"

echo "run-all-precondition.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
