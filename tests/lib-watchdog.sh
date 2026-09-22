#!/usr/bin/env bash
# The watchdog binary, for the TEST HARNESS. Source, don't execute.
#
# One home for three things every suite that needs a wall-clock bound was
# otherwise writing for itself: which binary this host has, how to run a command
# under it, and how a suite declines to run at all without one.
#
# Why it is a file rather than three lines in each lib: it already went wrong
# that way. `timeout` is GNU; stock macOS ships none, and homebrew coreutils
# installs it as `gtimeout` — the exact host the driver's own fallback
# (unattended-loop.sh) exists to serve and the one the portability gate treats as
# supported. Review T-D found the harness calling bare `timeout` at five sites in
# the two driver libs, so on that host the no-hang guards died at 127 and the
# suites reported 35/3 and 46/2 while the PRODUCT was fine. That fix landed in
# v0.15.0 — and missed six more sites of the same shape in
# tests/hooks/stop-gate.test.sh and tests/sandbox/setup.test.sh, because there
# was nowhere for the answer to live and each suite had to remember separately.
# One of those six was worse than a failure: `setup.test.sh`'s dangling-flag
# guards assert `rc != 124`, and an absent binary returns 127, so three no-hang
# guards PASSED on a host where nothing had run.
#
# The check that keeps this from happening a third time is not this file, it is
# the bare-`timeout` scan in tests/portability/bash3.test.sh. This file is what
# gives that scan something to point at.

# Resolved exactly as the drivers resolve it (unattended-loop.sh:680,
# unattended-codex.sh) — if these two ever disagree the harness is testing a
# different host than the product runs on.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN=gtimeout; fi

# bounded <secs> <cmd...> — run under the wall-clock bound, or report the missing
# precondition and return 127.
#
# The call sites are regression guards against an infinite loop, so falling back
# to running UNBOUNDED would turn a caught hang into a hung suite — strictly
# worse than a reported failure. With neither binary present this says which
# precondition is missing instead of failing as though the product misbehaved.
bounded() { # secs cmd...
  local secs="$1"; shift
  if [ -z "$TIMEOUT_BIN" ]; then
    echo "  FAIL: precondition — no timeout/gtimeout on PATH, so the no-hang guards cannot run" >&2
    return 127
  fi
  "$TIMEOUT_BIN" "$secs" "$@"
}

# --- suite-level precondition: this suite cannot run on this host -------------
# For a suite whose SUBJECT needs the binary, not just whose guards do. On a host
# with neither, the drivers are not what break: they REFUSE to start (DR-7),
# correctly, and every case that needs a running driver then measures that
# refusal instead of the thing it is named after. Measured on a PATH farm of
# /bin + /usr/bin minus both binaries: eleven driver suites fail, driver-limits
# 14 passed / 21 failed and codex-limits 27 / 17 among them, first failure in
# each `expected rc 5 got 2`.
#
# Per-case skips were the other candidate and two reviewers rejected them
# independently: these cases are not ABOUT the watchdog, so the guard would have
# to be pasted onto nearly every case in eleven files, and each suite would still
# publish a tally for a run that proved nothing.
#
# What it costs, stated: on such a host the DR-7 cases stop running too, even
# though they pass there (they build their own binary-less PATH and need nothing
# from the host). They still run wherever a watchdog binary exists, which is
# every host this project is developed and released on.
#
# A skip is the dangerous direction here — a suite that stops running reads
# exactly like a suite that passes, and this runner has printed ALL GREEN over 12
# of 35 suites once. So this is a protocol rather than an early exit. The first
# line is machine-read by tests/run-all.sh, which does not take the suite's word
# for it: it re-checks the precondition against the host, refuses a token it does
# not know, requires the exit status and the line to agree, fails the run if a
# skipped suite also reported assertions, and prints the count in TOTAL so no
# reader can mistake 43 suites for 32 that ran.
# 77 is automake's SKIP convention, not a number of our own.
require_watchdog_binary() {
  [ -n "$TIMEOUT_BIN" ] && return 0
  echo "PRECONDITION NOT MET: watchdog-binary"
  echo "  Neither timeout nor gtimeout is on PATH. The driver under test refuses to"
  echo "  start without a wall-clock watchdog (DR-7), so these cases would measure that"
  echo "  refusal and not what they are named after. This suite ran NOTHING."
  echo "  Install GNU coreutils to run it (on macOS, brew install coreutils gives gtimeout)."
  exit 77
}
