#!/usr/bin/env bash
# loop-testing test entry point.
#   1. bash -n syntax check on every tracked *.sh
#   2. shellcheck (errors only) when available
#   3. every tests/**/*.test.sh shell test
#   4. node --test tests/moa/*.test.mjs when that dir exists (glob form: bare-dir positional is not discovered on node v22)
set -u
cd "$(dirname "$0")/.." || { echo "FAILED: cannot cd to repo root"; exit 1; }

overall=0

echo "== bash -n =="
sh_found=0
while IFS= read -r -d '' f; do
  sh_found=1
  if bash -n "$f"; then echo "  ok: $f"; else echo "  SYNTAX FAIL: $f"; overall=1; fi
done < <(find skills tests hooks install -name '*.sh' -type f -print0 2>/dev/null)
# Zero discovery is a gate failure, not a pass: an empty find (wrong cwd, moved
# tree) must never yield a green run that checked nothing (audit TS-1).
[ "$sh_found" -eq 1 ] || { echo "  GATE FAIL: no *.sh files discovered"; overall=1; }

if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck (errors only) =="
  # No `mapfile`: it is bash 4+, and this runner has to start on macOS's bash 3.2
  # (audit T-09) — a runner that cannot run is worse than any test it would skip.
  sh_files=()
  while IFS= read -r f; do sh_files+=("$f"); done < <(find skills tests hooks install -name '*.sh' -type f 2>/dev/null)
  if [ "${#sh_files[@]}" -gt 0 ] && shellcheck -S error -e SC1091 "${sh_files[@]}"; then
    echo "  ok: no errors"
  else overall=1; fi
else
  echo "== shellcheck not installed, skipping (bash -n only) =="
fi

echo "== shell tests =="
tests_found=0
suites=0
asserts=0
afails=0
skipped=0      # suites that declared a host precondition this runner verified
_ra_rcfail=0   # set when any suite failed through its exit code, so the
               # assertion gate below does not name a cause that is false

# Which watchdog binary this host has, resolved ONCE. Two things read it: the
# precondition gate inside the loop, and the arms clause on the TOTAL line. They
# must not be able to disagree — a gate that honours "no watchdog here" while the
# line printed below says `timeout` would be the same drift between a number and
# its qualification that put the arms on that line in the first place.
_ra_wd=""
if command -v timeout >/dev/null 2>&1; then _ra_wd=timeout
elif command -v gtimeout >/dev/null 2>&1; then _ra_wd=gtimeout; fi
# Each suite's last tally line is "<suite>: <N> passed, <M> failed". Capturing
# the run lets us sum those into one TOTAL, so a published assertion count is
# recomputable from `bash tests/run-all.sh | tail -1` instead of being summed by
# hand over whichever suites happened to print a number (audit T-04).
_ra_out="$(mktemp "${TMPDIR:-/tmp}/loop-runall.XXXXXX")" || { echo "FAILED: mktemp"; exit 1; }
# Give this run its own TMPDIR. Every suite resolves its fixtures through
# `${TMPDIR:-/tmp}` — the seven helpers across five test libs, and the 14 suites
# that call mktemp directly, alike — so exporting one here puts all of them
# inside a single directory this runner owns, with no suite edits at all. That
# containment IS the fixture identity: what leaked is what is still in here,
# established by position rather than by name.
#
# `_ra_out` is created BEFORE the root on purpose, so this runner's own capture
# file sits outside the watched directory and cannot register as residue.
_ra_root="$(mktemp -d "${TMPDIR:-/tmp}/loop-runroot.XXXXXX")" || { echo "FAILED: mktemp -d"; exit 1; }
export TMPDIR="$_ra_root"
# One cleanup path on bare EXIT, and the signal arms only `exit` into it. A bash
# trap handler RETURNS to the interrupted point unless it exits, so handling the
# signals directly here deleted the directory every suite is using as $TMPDIR and
# then carried on running the remaining suites against a path that no longer
# exists — with the mk_* helpers' unchecked `cd "$ws"` turning that into `mkdir
# proj; git init` in the runner's own cwd, which is the repository root.
#
# This repo already documents this exact shape twice, in driver-limits.test.sh
# and codex-limits.test.sh ("the handler ran and RETURNED into the loop, so the
# signal only dropped the lock while the driver kept launching sessions"), and
# all three shipped scripts use the form below. This was the one site that did
# not; 128+n matches them.
# `chmod -R u+w` first: the worktree-identity cases that make `.git/worktrees`
# unreadable restore the mode themselves, but an interrupted run does not reach
# that line, and `rm -rf` over a 000 subtree fails with its status discarded —
# stranding the whole root rather than the one directory.
_ra_cleanup() {
  rm -f "$_ra_out"
  chmod -R u+w "${_ra_root:?}" 2>/dev/null
  rm -rf "${_ra_root:?}"
}
trap _ra_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
# Fixture-leak gate. Every suite builds its workspaces under $TMPDIR and removes
# them in an EXIT trap. A trap that misses one leaks silently: the suite is green,
# the tally is right, and the only evidence is a directory nobody looks at — one
# suite left six per run for months (audit T-10). Counted per suite so the report
# names the file to fix.
#
# This counted a hand-maintained list of name prefixes until the run root above
# replaced it. That list was the same "ownership claimed by a NAME, with nothing
# verifying it" shape this project keeps finding in its own product code — living
# in the gate whose whole job is to catch sloppiness — and it had already missed
# once: the gate watched `loop-testing-*` while suites also used
# `loop-install-test.*` and `lt-upd.*`, so two thirds of the tree was unwatched
# and the comment said "add a prefix here when a suite starts using one", which
# is a request that nothing enforces. Containment needs no list: a suite that
# invents a new prefix tomorrow is covered the day it is written.
#
# Two things the old form could not do, now free: a concurrent copy of this
# runner gets its own root and can no longer be blamed on whichever suite the
# sampling window landed on, and residue from an earlier crashed run is outside
# this root instead of being baked into the first sample as the baseline.
#
# Files as well as directories: a suite that leaves a stray capture file behind
# has leaked too, and the drivers under test write their session-err captures
# into $TMPDIR — inside the root now, which is correct, because an orphaned one
# is a real leak.
_ra_tmp="$_ra_root"
_leak_n() {
  find "$_ra_tmp" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '
}
_leak_before=$(_leak_n)
while IFS= read -r -d '' t; do
  tests_found=1
  suites=$((suites + 1))
  # `</dev/null` is load-bearing, not hygiene. The loop reads the file list on
  # stdin, so a suite that reads stdin ate the rest of that list and the runner
  # stopped early while still printing ALL GREEN: 12 of 35 suites ran.
  #
  # The real exit status, not a collapsed 0-or-1: the precondition protocol below
  # distinguishes 77 from every other non-zero code, and cannot if the status is
  # flattened on the way in.
  bash "$t" </dev/null >"$_ra_out" 2>&1; rc=$?
  cat "$_ra_out"
  # --- suite-level precondition protocol ---------------------------------------
  # A suite whose host cannot run it AT ALL may stop before its first case by
  # printing one line — `PRECONDITION NOT MET: <token>` — and exiting 77
  # (automake's SKIP convention). The driver suites use it for the host with
  # neither `timeout` nor `gtimeout`: there the driver REFUSES to start, which is
  # correct, so every case needing a running driver measures that refusal instead
  # of its own subject. How many suites and how many assertions that is are
  # deliberately NOT written here — the SKIP lines and the TOTAL line carry them,
  # and a count hand-written beside a mechanism is the drift this release is
  # about. Per-case skips were the rejected alternative.
  #
  # The line is matched at column 0, so a suite that needs to print the literal
  # (a future test OF this protocol) must indent it.
  #
  # Skipping is the direction that hides things here — this runner once printed
  # ALL GREEN having run 12 of 35 suites — so none of it is taken on the suite's
  # word. Four checks, each fail-closed:
  #   * the line and the exit status must agree, in both directions;
  #   * the token must be one this runner knows, so a typo cannot buy silence;
  #   * the precondition is re-evaluated HERE, against this host. A suite
  #     claiming the watchdog is missing where one exists is a gate failure —
  #     that check is what stops a suite from quietly excusing itself forever;
  #   * a skipped suite must report no assertions (enforced at the tally below):
  #     one that ran cases and then bailed is not a skip.
  # Read the tally here rather than after the verdict: one of the four checks is
  # about the tally, and a claim rejected for reporting assertions must not first
  # be announced as a suite that "ran nothing".
  tally=$(grep -E '^[^ ]+: [0-9]+ passed, [0-9]+ failed$' "$_ra_out" | tail -1)
  _ra_pre=""
  _ra_precount=$(grep -c '^PRECONDITION NOT MET: ' "$_ra_out")
  _ra_preline=$(grep '^PRECONDITION NOT MET: ' "$_ra_out" | head -1)
  [ -n "$_ra_preline" ] && _ra_pre=${_ra_preline#PRECONDITION NOT MET: }
  # Shown rather than pasted: a token carrying a CR (a suite saved with CRLF line
  # endings) is correctly rejected as unknown, but printing it raw made the message
  # read `[watchdog-binary]` — the exact token it was refusing — with the CR
  # invisible. Escape it so the reason is legible.
  _ra_pre_show=$(printf '%s' "$_ra_pre" | sed -e 's/\r/\\r/g')
  _ra_skip_this=0
  _ra_pre_seen=0
  if [ -n "$_ra_pre" ] || [ "$rc" -eq 77 ]; then
    _ra_pre_seen=1
    if [ -z "$_ra_pre" ]; then
      echo "  GATE FAIL: $t exited 77 (skip) but declared no precondition"; overall=1
    elif [ "${_ra_precount:-0}" -gt 1 ]; then
      # `head -1` used to settle it, which let a first well-formed declaration
      # cover a second one this runner would have refused.
      echo "  GATE FAIL: $t printed $_ra_precount precondition declarations — one suite, one reason, or the first silently speaks for the rest"
      overall=1
    elif [ "$rc" -ne 77 ]; then
      echo "  GATE FAIL: $t declared precondition [$_ra_pre_show] but exited $rc, not 77"; overall=1
    elif [ -n "$tally" ]; then
      echo "  GATE FAIL: $t declared precondition [$_ra_pre] but also reported assertions [$tally] — a suite that ran cases and then declared the host unfit is not a skip"
      overall=1
    else
      case "$_ra_pre" in
        watchdog-binary)
          if [ -n "$_ra_wd" ]; then
            echo "  GATE FAIL: $t skipped for a missing watchdog binary, but $_ra_wd is on PATH"
            overall=1
          else
            _ra_skip_this=1
          fi
          ;;
        *)
          echo "  GATE FAIL: $t declared an unknown precondition [$_ra_pre_show]"; overall=1
          ;;
      esac
    fi
  fi
  if [ "$_ra_skip_this" -eq 1 ]; then
    echo "  SKIP: $t — precondition [$_ra_pre] not met on this host; it ran nothing"
    skipped=$((skipped + 1))
  elif [ "$_ra_pre_seen" -eq 1 ]; then
    # A claim the block above rejected. `ok:` was printed here whenever such a
    # suite happened to exit 0, so the run contradicted itself one line apart; a
    # bare TEST FAIL would instead blame the suite's exit code, which is not what
    # went wrong. The GATE FAIL already failed the run.
    echo "  NOT A SKIP: $t — its precondition claim was rejected above (exit $rc)"
    [ "$rc" -eq 0 ] || _ra_rcfail=1
  elif [ "$rc" -eq 0 ]; then echo "  ok: $t"
  else echo "  TEST FAIL: $t"; overall=1; _ra_rcfail=1; fi
  # A helper the suite's lib does not define is not a failing assertion — it is
  # an assertion that never ran. `assert_path` lived in one lib and was called
  # from a suite sourcing another, so two checks printed "command not found" to
  # stderr and the suite still reported 42 passed, 0 failed. The shell says so
  # every time; nothing was reading it.
  if grep -qE 'command not found|: not found' "$_ra_out"; then
    echo "  GATE FAIL: $t called a command that does not exist — an assertion did not run"
    grep -E 'command not found|: not found' "$_ra_out" | head -3
    overall=1
  fi
  _leak_after=$(_leak_n)
  if [ "$_leak_after" -gt "$_leak_before" ]; then
    echo "  GATE FAIL: $t left $((_leak_after - _leak_before)) fixture dir(s) behind in $_ra_tmp"
    overall=1
  fi
  _leak_before=$_leak_after
  # A tally is ACCOUNTED whenever one exists, including for a suite whose
  # precondition claim was just rejected. Skipping the accounting there dropped
  # that suite's whole tally out of TOTAL, failures included: a suite reporting
  # "9 passed, 4 failed" landed in the line as 4 assertions and 0 failed, so the
  # run's own summary under-reported failures it had already printed. Only the
  # redundant no-tally MESSAGE is suppressed for such a suite, never the numbers.
  if [ -n "$tally" ]; then
    p=${tally#*: }; p=${p%% passed,*}
    f=${tally#* passed, }; f=${f%% failed}
    [ "$p" -gt 0 ] || { echo "  GATE FAIL: $t reported 0 assertions"; overall=1; }
    asserts=$((asserts + p)); afails=$((afails + f))
  elif [ "$_ra_pre_seen" -eq 1 ]; then
    # A verified skip reports no tally by contract, and a rejected claim was
    # already named above; "printed no assertion tally" would hand the reader a
    # second cause that is true and not the reason.
    :
  else
    # A suite that reports no tally cannot be counted, and a suite that cannot be
    # counted is where a zero-assertion suite hides. Fail rather than skip.
    echo "  GATE FAIL: $t printed no assertion tally"; overall=1
  fi
done < <(find tests -name '*.test.sh' -type f -print0 2>/dev/null | sort -z)
[ "$tests_found" -eq 1 ] || { echo "  GATE FAIL: no *.test.sh found (zero discovery must not pass)"; overall=1; }
# Ran-everything gate. Zero discovery was already caught; this catches the other
# half, a loop that STOPPED early — which is how 23 suites went unrun while the
# runner printed ALL GREEN. Counting files separately from the loop is the point:
# the two numbers can only agree if every discovered suite was actually executed.
_ra_files=$(find tests -name '*.test.sh' -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$suites" -eq "$_ra_files" ] || {
  echo "  GATE FAIL: ran $suites of $_ra_files suites — the run ended early"; overall=1; }

node_counted=0
if [ -d tests/moa ]; then
  echo "== node --test tests/moa/ =="
  if command -v node >/dev/null 2>&1; then
    # The counted set and the executed set have to be the SAME set. This counted
    # with `find` (recursive) and executed with `tests/moa/*.test.mjs` (one level
    # only), so the first .test.mjs placed in a subdirectory would be counted as
    # a suite, never run, and the run would still print ALL GREEN — the same
    # counted-but-not-executed shape that once let 23 suites go unrun. The two
    # numbers agree today because tests/moa/ is flat; that is a property of the
    # directory, not of the runner. No `mapfile`: bash 4+, and this runner has to
    # start on macOS's bash 3.2.
    node_files=()
    while IFS= read -r f; do node_files+=("$f"); done \
      < <(find tests/moa -name '*.test.mjs' -type f 2>/dev/null | sort)
    nsuites=${#node_files[@]}
    if [ "$nsuites" -eq 0 ]; then
      echo "  GATE FAIL: tests/moa exists but holds no *.test.mjs"; overall=1
    else
    if node --test "${node_files[@]}" >"$_ra_out" 2>&1; then rc=0; else rc=1; fi
    cat "$_ra_out"
    if [ "$rc" -eq 0 ]; then echo "  ok: moa tests"; else echo "  MOA TEST FAIL"; overall=1; fi
    # node --test reports its own totals; fold them in so one number covers the
    # whole run. Each .test.mjs file counts as one suite, same rule as shell.
    np=$(grep -E '^. pass [0-9]+$' "$_ra_out" | tail -1); np=${np##* }
    nf=$(grep -E '^. fail [0-9]+$' "$_ra_out" | tail -1); nf=${nf##* }
    case "${np:-x}" in ''|*[!0-9]*) np="" ;; esac
    case "${nf:-x}" in ''|*[!0-9]*) nf="" ;; esac
    if [ -n "$np" ] && [ -n "$nf" ]; then
      suites=$((suites + nsuites)); asserts=$((asserts + np)); afails=$((afails + nf))
      node_counted=1
    else
      echo "  GATE FAIL: could not read node's pass/fail totals"; overall=1
    fi
    fi   # closes the "no *.test.mjs discovered" guard above
  else
    echo "  node not installed, skipping moa tests"
  fi
else
  echo "  GATE FAIL: tests/moa missing (zero discovery must not pass)"; overall=1
fi

# The line a release note quotes verbatim. "Suite" = one file under tests/
# matching *.test.* ; "assertion" = one pass-or-fail decision a suite reports.
# Recompute with:  bash tests/run-all.sh | grep '^TOTAL:'
#
# The line carries the ARMS it was measured on, because a count is a property of
# a RUN and not of the code, and each of these three predicates moves the total
# BY DESIGN rather than by failure:
#   * node absent          -> the moa suites do not run at all (the original
#                             case this line already handled);
#   * neither timeout nor gtimeout -> the two driver suites declare a host
#                             precondition and are skipped WHOLE, so the total
#                             drops by their assertions and `skipped` says how
#                             many files did not run. This clause used to read
#                             "the watchdog cases skip, so the total is lower
#                             with nothing having failed", and both halves were
#                             false: nothing skipped, and those suites reported
#                             38 failures — every one of them the driver
#                             correctly refusing to start without a watchdog.
#                             The drift this line exists to prevent had been
#                             written into the line's own comment;
#   * a $TMPDIR containing a space -> several suites take a different path, and
#                             `update-check` currently fails five there.
# Printing them here instead of hand-writing them into a release note is the
# whole point: a note quotes ONE line that carries its own conditions, so the
# qualification cannot drift from the number the way a hand-written clause does
# — and demonstrably did, twice, in the notes for this release.
#
# This is not a toolchain inventory and should not become one. Which `grep` or
# `coreutils` produced the run is not an axis that moves these counts; whether a
# skip branch fired is. Name the arms, not the userland.
# Same $_ra_wd the precondition gate honoured, not a second resolution: the arm
# named here and the arm the gate acted on are then the same fact.
case "$_ra_wd" in
  timeout)  _ra_arm_to="timeout" ;;
  gtimeout) _ra_arm_to="gtimeout-only" ;;
  *)        _ra_arm_to="no timeout/gtimeout" ;;
esac
case "${TMPDIR:-/tmp}" in
  *\ *) _ra_arm_tmp='spaced $TMPDIR' ;;
  *)    _ra_arm_tmp='space-free $TMPDIR' ;;
esac
if [ "$node_counted" -eq 1 ]; then
  _ra_arm_node="node present"
else
  _ra_arm_node="shell only — node not run"
fi
# `skipped` is printed unconditionally, including as `0 skipped`. A field that
# appears only when non-zero makes the line's shape depend on the run, and a
# release note quoting one shape cannot then be compared with another — the same
# reason the arms are always present rather than mentioned only when unusual.
printf 'TOTAL: %d suites, %d assertions, %d failed, %d skipped (%s; %s; %s)\n' \
  "$suites" "$asserts" "$afails" "$skipped" "$_ra_arm_tmp" "$_ra_arm_to" "$_ra_arm_node"
# A failed assertion has to reach the verdict, not just the TOTAL line. `afails`
# was summed from every suite's tally and then printed, while `overall` — the
# only thing ALL GREEN consults — was set by suite exit codes and the gates and
# never by `afails`. A suite reporting "1 failed" and still exiting 0 therefore
# printed its failure one line above ALL GREEN. Unreachable today only because
# every suite ends in report/finish, which returns non-zero when FAIL>0; it
# becomes reachable the moment any suite gains a command after that line.
if [ "$afails" -ne 0 ]; then
  overall=1
  # Only claim the exit-code route was missed when it actually was. A suite that
  # reports "1 failed" AND exits non-zero is already caught by TEST FAIL above,
  # and telling the reader it went unreported names a cause that is false.
  if [ "$_ra_rcfail" -eq 0 ]; then
    echo "  GATE FAIL: $afails assertion(s) failed but no suite reported it through its exit code"
  fi
fi
# A bare "ALL GREEN" over a run that skipped suites is the sentence this repo has
# the most reason to distrust: it is what was printed over 12 of 35 suites. The
# exit status stays 0 — a host without the binary has done everything it can — but
# the word does not stand unqualified.
if [ "$overall" -eq 0 ]; then
  if [ "$skipped" -gt 0 ]; then
    echo "ALL GREEN ($skipped suite(s) skipped on an unmet precondition — see the SKIP lines)"
  else
    echo "ALL GREEN"
  fi
else
  echo "FAILED"
fi
exit "$overall"
