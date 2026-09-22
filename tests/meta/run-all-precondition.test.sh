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
# runs the REAL tests/run-all.sh against a fixture repo and asserts three things:
# that the output names the right cause, that the verdict is right, and that the
# EXIT STATUS agrees with the verdict. Naming the cause matters as much as the
# verdict — three of the four defects above produced a correct FAILED for a reason
# the output stated wrongly or not at all — and the status matters most of all,
# because it is the only part of this output that CI reads. A second review round
# found that the first version of this file asserted neither the status nor an
# anchored needle, so `exit 0` substituted for `exit "$overall"` left it green.
#
# Asserted on text, verdict and status, never on the fixture's TOTALS: those depend
# on whether the host has node, and a suite that pinned them would fail on a host
# it has nothing to say about.
set -u
cd "$(cd "$(dirname "$0")" && pwd)/../.." || { echo "FAILED: cannot cd to repo root"; exit 1; }

# For TIMEOUT_BIN only. One scenario below needs the HOST to have a watchdog
# binary — it checks that a suite claiming the binary is missing where one exists
# is refused — and this file is itself run on the binary-less arm, where that
# premise does not hold. Resolved from the shared lib rather than re-derived here,
# so there is still one answer to the question in this tree.
. "$(cd "$(dirname "$0")" && pwd)/../lib-watchdog.sh" || {
  echo "FAILED: cannot source tests/lib-watchdog.sh" >&2; exit 1; }

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
GOOD="$R/tests/fake/good.test.sh"
MUT="$R/tests/fake/mut.test.sh"
MOA="$R/tests/moa/ok.test.mjs"
# Two scenarios below overwrite the control suite and the node suite — one needs
# every shell suite in the tree to skip, the other needs node's own output to
# carry a NUL byte — and each restores what it changed through these. Written
# once rather than retyped at the restore site: a fixture retyped from memory is
# the shape this tree spent a release removing from its cleanup lists.
write_good() { printf '#!/usr/bin/env bash\necho "good.test.sh: 3 passed, 0 failed"\n' > "$GOOD"; }
write_moa()  { printf '%s\n' "import {test} from 'node:test';" "test('t', () => {});" > "$MOA"; }
write_good
write_moa

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
    # derives it from ours — so sixteen inner runs would each create and remove a
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

# scenario <label> <mode> <expected-exit 0|1> <verdict-ERE> <cause-ERE> [env…]
#
# THREE assertions, always: the cause, the verdict, and the inner run's EXIT
# STATUS. The status is the addition that matters — without it every scenario
# checked only what the runner SAYS, while the code under test says the status is
# the only part CI reads. Mutating `exit "$overall"` to `exit 0` in run-all.sh left
# this file 33/0 green over a run that had printed every FAILED string.
#
# Needles are EREs matched with grep, not `case` globs. As globs they were
# unanchored substrings, and `SKIP: …` is a substring of `NOT A SKIP: …`, so the
# accepted-skip scenario would have passed on the line that means the opposite.
# `1` for the expected exit means "any non-zero": the distinction that matters is
# green against not-green, and pinning a specific code would tie this file to
# whichever gate fired first.
#
# On failure the inner output is printed indented by four spaces, which keeps its
# own tally and `skip:` lines from being read as this suite's by the runner one
# level up.
scenario() {
  local label="$1" mode="$2" want_rc="$3" vre="$4" cre="$5"; shift 5
  local out rc
  out=$(run_inner "$mode" "$@"); rc=$?
  if printf '%s\n' "$out" | grep -qE -- "$cre"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "  FAIL: $label — output does not name the cause [$cre]" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
  fi
  if printf '%s\n' "$out" | grep -qE -- "$vre"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "  FAIL: $label — verdict is not [$vre]" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
  fi
  if { [ "$want_rc" -eq 0 ] && [ "$rc" -eq 0 ]; } || { [ "$want_rc" -ne 0 ] && [ "$rc" -ne 0 ]; }; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "  FAIL: $label — exit status $rc, wanted $( [ "$want_rc" -eq 0 ] && echo 0 || echo 'non-zero' )" >&2
  fi
}

# --- the five ways to break the protocol, each fail-closed --------------------
printf '#!/usr/bin/env bash\necho "PRECONDITION NOT MET: watchdog-binary"\nexit 0\n' > "$MUT"
scenario "declared but exited 0" host 1 '^FAILED$' "but exited 0, not 77"

printf '#!/usr/bin/env bash\necho nothing\nexit 77\n' > "$MUT"
scenario "exited 77 with no declaration" host 1 '^FAILED$' "exited 77 \\(skip\\) but declared no precondition"

printf '#!/usr/bin/env bash\necho "PRECONDITION NOT MET: no-such-token"\nexit 77\n' > "$MUT"
scenario "unknown token" farm 1 '^FAILED$' "declared an unknown precondition \\[no-such-token\\]"

# Premise-guarded: this is the one scenario whose subject is the HOST having a
# watchdog binary, and this file runs on the arm where it does not. Counting
# nothing there is right; asserting it would fail a host the scenario has nothing
# to say about. The `skip:` line is what the runner's case-skips field counts.
if [ -n "$TIMEOUT_BIN" ]; then
  printf '#!/usr/bin/env bash\necho "PRECONDITION NOT MET: watchdog-binary"\nexit 77\n' > "$MUT"
  scenario "claimed on a host that has one" host 1 '^FAILED$' "but $TIMEOUT_BIN is on PATH"
else
  echo "  skip: no timeout/gtimeout on PATH — the refusal of a false watchdog claim needs a host that has one"
fi

printf '#!/usr/bin/env bash\necho "mut.test.sh: 9 passed, 4 failed"\necho "PRECONDITION NOT MET: watchdog-binary"\nexit 77\n' > "$MUT"
scenario "skipped yet reported assertions" farm 1 '^FAILED$' "but also reported assertions"

# The two dodges that made the arm above pass VACUOUSLY. The runner's tally regex
# is anchored and space-free, so a suite whose tally it cannot parse left `tally`
# empty and the skip was honoured over a run that had printed four failures — exit
# 1 at v0.15.0, exit 0 and ALL GREEN with the protocol as first written. Neither
# shape is reachable in this tree today, which is exactly why they belong here: the
# thing that made them unreachable is a naming habit, not a check.
printf '#!/usr/bin/env bash\necho "  FAIL: case one — expected rc 5 got 2"\necho "atk suite: 9 passed, 4 failed"\necho "PRECONDITION NOT MET: watchdog-binary"\nexit 77\n' > "$MUT"
scenario "a tally with a space in its name buys no skip" farm 1 '^FAILED$' "carries case results"

printf '#!/usr/bin/env bash\necho "  FAIL: case one — expected rc 5 got 2"\necho "  atk: 9 passed, 4 failed"\necho "PRECONDITION NOT MET: watchdog-binary"\nexit 77\n' > "$MUT"
scenario "an indented tally buys no skip" farm 1 '^FAILED$' "carries case results"

# The third dodge, and the one the residual scan first missed: a suite that ran
# cases and PASSED them. Its output carries no `FAIL:` and no tally, only the
# `  ok: <case>` lines this tree uses for a passing case — so the scan looked for
# failures and found none, and the skip was honoured over a run that had executed
# its whole fixture. Nothing covered it, which is how it survived a review round.
printf '#!/usr/bin/env bash\necho "  ok: case one ran and passed"\necho "PRECONDITION NOT MET: watchdog-binary"\nexit 77\n' > "$MUT"
scenario "a suite that ran cases and passed them buys no skip" farm 1 '^FAILED$' "carries case results"

# --- and the four repairs the review produced --------------------------------
# The failures of a rejected claim must reach the TOTAL line. This is the defect
# that made the runner under-report failures it had already printed, so the
# assertion is on the number, not on a message.
printf '#!/usr/bin/env bash\necho "mut.test.sh: 9 passed, 4 failed"\necho "PRECONDITION NOT MET: watchdog-binary"\nexit 77\n' > "$MUT"
scenario "a rejected claim still counts its failures" farm 1 "^TOTAL:.*, 4 failed," "but also reported assertions"

printf '#!/usr/bin/env bash\necho "mut.test.sh: 6 passed, 0 failed"\necho "PRECONDITION NOT MET: watchdog-binary"\nexit 0\n' > "$MUT"
scenario "a rejected claim is not announced ok" host 1 "^  NOT A SKIP: " "but exited 0, not 77"

printf '#!/usr/bin/env bash\necho "PRECONDITION NOT MET: watchdog-binary"\necho "PRECONDITION NOT MET: no-such-token"\nexit 77\n' > "$MUT"
scenario "two declarations" farm 1 '^FAILED$' "printed 2 precondition declarations"

printf '#!/usr/bin/env bash\nprintf "PRECONDITION NOT MET: watchdog-binary\\r\\n"\nexit 77\n' > "$MUT"
scenario "a CR in the token is shown, not hidden" farm 1 '^FAILED$' 'watchdog-binary\\r'

# --- the honest skip, and what it costs --------------------------------------
# A correct skip is verified and counted — and by default it still fails the run,
# because the exit status is the only part of this output that CI reads.
printf '#!/usr/bin/env bash\necho "PRECONDITION NOT MET: watchdog-binary"\nexit 77\n' > "$MUT"
scenario "a correct skip is honoured" farm 1 "^  SKIP: tests/fake/mut\\.test\\.sh" "^TOTAL:.*, 1 skipped,"
scenario "an unacknowledged skip fails the run" farm 1 '^FAILED$' "did not run on this host"
scenario "acknowledged, the same run is green" farm 0 '^ALL GREEN \(1 suite\(s\) skipped' '^TOTAL:.*, 1 skipped,' \
  LOOP_TESTING_ALLOW_SKIP=1
# Fail-closed on the acknowledgement itself: any value but 1 leaves it refused.
scenario "a mistyped acknowledgement is refused" farm 1 '^FAILED$' 'did not run on this host' \
  LOOP_TESTING_ALLOW_SKIP=yes

# --- the floor under the acknowledgement --------------------------------------
# The switch was written as a blanket: any number of suites, for as long as the
# variable is set. So the sentence the gate exists to prevent came back on the one
# arm that needs the switch — set it on a host where every shell suite declares a
# precondition and the run printed ALL GREEN and exited 0 over a tree that
# executed nothing. Both fixture suites skip here, which makes the floor the only
# thing that can fail this run, and the acknowledgement is SET so that an
# unacknowledged skip cannot be what fails it.
printf '#!/usr/bin/env bash\necho "PRECONDITION NOT MET: watchdog-binary"\nexit 77\n' > "$MUT"
cp "$MUT" "$GOOD"
scenario "no acknowledgement covers a run where every suite skipped" farm 1 \
  '^FAILED$' 'shell suite\(s\) discovered were skipped' LOOP_TESTING_ALLOW_SKIP=1
write_good

# --- a NUL byte in what a suite printed ---------------------------------------
# Every check above reads the runner's capture file as text, and that file is a
# suite's output verbatim: a driver capture, a killed child or a terminal escape
# can put a NUL in it. Without `-a`, grep then answers about a BINARY file — the
# matching line becomes a note on stderr and the command substitution that wanted
# it comes back empty. The run still fails, which is why this survived: it fails
# for "printed no assertion tally" over a suite that printed one, and for
# "declared no precondition" over a suite that declared one. Naming a cause that
# is false already has three comments in run-all.sh; this is the same defect
# arriving through the instrument rather than through the logic.
#
# The byte is emitted BY the fixture rather than embedded in this file, so what
# reaches the capture file is a byte a suite wrote, not one this file's quoting
# produced. One definition for all four scenarios.
nul_line() { printf 'printf "capture\\000junk\\n"\n'; }

{ printf '#!/usr/bin/env bash\n'; nul_line
  printf 'echo "mut.test.sh: 2 passed, 0 failed"\n'; } > "$MUT"
scenario "a NUL does not cost a passing suite its tally" farm 0 \
  '^ALL GREEN$' '^  ok: tests/fake/mut\.test\.sh'

# The same defect measured on the number instead of the verdict: a tally the
# runner cannot read is a tally whose FAILURES never reach TOTAL, which is the
# under-reporting a review already found once on the rejected-claim path.
{ printf '#!/usr/bin/env bash\n'; nul_line
  printf 'echo "mut.test.sh: 3 passed, 2 failed"\n'; printf 'exit 1\n'; } > "$MUT"
scenario "a NUL does not cost a failing suite its failures" farm 1 \
  '^FAILED$' '^TOTAL:.*, 2 failed,'

# The precondition line, where the two forms disagreed with each other: the
# count is read with `-c` and survives the NUL, the line is read without and does
# not — so the runner held "one declaration" and "no declaration" at once, and
# refused the skip for the second of them.
{ printf '#!/usr/bin/env bash\n'; nul_line
  printf 'echo "PRECONDITION NOT MET: watchdog-binary"\n'; printf 'exit 77\n'; } > "$MUT"
scenario "a NUL does not erase a precondition declaration" farm 0 \
  '^ALL GREEN \(1 suite\(s\) skipped' '^  SKIP: tests/fake/mut\.test\.sh' \
  LOOP_TESTING_ALLOW_SKIP=1

# The gate that catches an assertion which never ran has to say WHICH command was
# not found: its `-q` test survives a NUL and the line it prints as evidence does
# not, so it fired with nothing under it.
#
# The needle is the INDENTED evidence line, not the command name. Written as the
# bare name first, this scenario passed against the unfixed runner on all three
# assertions — the runner echoes the whole capture a few lines earlier, so the
# name was already in the output and the assertion was about the suite's own
# stderr rather than about anything the gate did. Which is why the gate now
# indents what it quotes: an assertion that cannot tell the two apart is the
# shape this file exists to catch, and it appeared while writing this file.
{ printf '#!/usr/bin/env bash\n'; nul_line
  printf 'nosuchcommand_xyz\n'
  printf 'echo "mut.test.sh: 2 passed, 0 failed"\n'; } > "$MUT"
scenario "the command-not-found gate still names what was not found" farm 1 \
  '^FAILED$' '^      .*nosuchcommand_xyz: command not found'

# And node's totals, read the same way from the same file. Premise-guarded on the
# host having node at all: the runner has its own branch for an absent one, and
# the arms clause on the TOTAL line is what says which branch ran — `node present`
# is therefore the needle, because a run whose totals could not be read reports
# `shell only` there and counts none of them.
printf '#!/usr/bin/env bash\necho "mut.test.sh: 2 passed, 0 failed"\n' > "$MUT"
if [ -n "$fnode" ]; then
  printf '%s\n' "import {test} from 'node:test';" \
    "test('t', () => { process.stdout.write('\\u0000'); });" > "$MOA"
  scenario "a NUL in node's output does not erase its totals" farm 0 \
    '^ALL GREEN$' 'node present\)$'
  write_moa
else
  echo "  skip: no node on PATH — node's totals are read only on a host that has one"
fi

# --- and the control: an ordinary suite is untouched by all of it -------------
printf '#!/usr/bin/env bash\necho "mut.test.sh: 2 passed, 0 failed"\n' > "$MUT"
scenario "an ordinary suite still passes" host 0 '^ALL GREEN$' "^TOTAL:.*, 0 skipped, 0 case-skips"

echo "run-all-precondition.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
