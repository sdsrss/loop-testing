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
_ra_rcfail=0   # set when any suite failed through its exit code, so the
               # assertion gate below does not name a cause that is false
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
  if bash "$t" </dev/null >"$_ra_out" 2>&1; then rc=0; else rc=1; fi
  cat "$_ra_out"
  if [ "$rc" -eq 0 ]; then echo "  ok: $t"; else echo "  TEST FAIL: $t"; overall=1; _ra_rcfail=1; fi
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
  tally=$(grep -E '^[^ ]+: [0-9]+ passed, [0-9]+ failed$' "$_ra_out" | tail -1)
  if [ -z "$tally" ]; then
    # A suite that reports no tally cannot be counted, and a suite that cannot be
    # counted is where a zero-assertion suite hides. Fail rather than skip.
    echo "  GATE FAIL: $t printed no assertion tally"; overall=1
  else
    p=${tally#*: }; p=${p%% passed,*}
    f=${tally#* passed, }; f=${f%% failed}
    [ "$p" -gt 0 ] || { echo "  GATE FAIL: $t reported 0 assertions"; overall=1; }
    asserts=$((asserts + p)); afails=$((afails + f))
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
# When node is absent the moa suites are skipped, so the counts cover shell only
# and this line says so rather than quietly reporting a smaller total.
if [ "$node_counted" -eq 1 ]; then
  printf 'TOTAL: %d suites, %d assertions, %d failed\n' "$suites" "$asserts" "$afails"
else
  printf 'TOTAL: %d suites, %d assertions, %d failed (shell only — node not run)\n' \
    "$suites" "$asserts" "$afails"
fi
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
if [ "$overall" -eq 0 ]; then echo "ALL GREEN"; else echo "FAILED"; fi
exit "$overall"
