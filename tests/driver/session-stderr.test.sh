#!/usr/bin/env bash
# unattended-loop.sh: a failed session must say WHY (audit D-05).
#
# The agent session's stderr — an expired key, a rate limit, an unknown flag, a
# bad working directory — went to /dev/null, so every one of those reached
# driver.log as `exit=N` and the no-progress breaker's verdict, with nothing to
# tell them apart. D-02 survived to the audit for exactly that reason.
#
# What is locked here: the tail lands in driver.log, it is redacted first, the
# transcript on stdout still does NOT, the capture is switchable off, the tail is
# bounded, and the capture file does not outlive the run.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

LOG=docs/looptesting/driver.log

# A. the session's stderr reaches the log.
WS=$(mk_proj); trap 'rm -rf "$WS"' EXIT
stub=$(write_stub "$WS"); write_state "$WS" RUNNING 0
STUB_STDERR='API Error: 401 invalid bearer token' STUB_EXIT=1 \
  bash "$DRIVER" --project "$WS" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_file_contains "$WS/$LOG" "401 invalid bearer token" "driver.log carries the session's stderr (D-05)"

# B. and is redacted on the way in. driver.log sits in the evidence directory the
#    user is told to read and attach, so a key echoed by a failing endpoint must
#    not be what this fix delivers there.
WS2=$(mk_proj); trap 'rm -rf "$WS" "$WS2"' EXIT
stub=$(write_stub "$WS2"); write_state "$WS2" RUNNING 0
KEY='sk-proj-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
STUB_STDERR="auth failed for key $KEY" STUB_EXIT=1 \
  bash "$DRIVER" --project "$WS2" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_file_lacks    "$WS2/$LOG" "$KEY"      "the key itself never reaches driver.log (D-05)"
assert_file_contains "$WS2/$LOG" "REDACTED"  "the redaction is visible, not a silent drop"
assert_file_contains "$WS2/$LOG" "auth failed for key" "redaction keeps the diagnostic around the secret"

# C. stdout is NOT captured. It is the agent transcript; capturing it would grow
#    the evidence directory without bound, which is a worse bug than the one
#    being fixed.
WS3=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3"' EXIT
stub=$(write_stub "$WS3"); write_state "$WS3" RUNNING 0
bash "$DRIVER" --project "$WS3" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_file_lacks "$WS3/$LOG" "stub: round=" "session stdout stays on /dev/null (transcript is not evidence)"

# D. switchable off for anyone who would rather the agent's stderr never be
#    written down at all.
WS4=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4"' EXIT
stub=$(write_stub "$WS4"); write_state "$WS4" RUNNING 0
STUB_STDERR='API Error: 401 invalid bearer token' STUB_EXIT=1 LOOP_TESTING_DISABLE_SESSION_STDERR=1 \
  bash "$DRIVER" --project "$WS4" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_file_lacks "$WS4/$LOG" "401 invalid bearer token" "LOOP_TESTING_DISABLE_SESSION_STDERR=1 captures nothing"
assert_file_contains "$WS4/$LOG" "session 1: exit=" "the session itself still ran and was logged"

# E. the tail is bounded: a chatty session must not turn driver.log into its
#    transcript by the back door.
WS5=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5"' EXIT
stub=$(write_stub "$WS5"); write_state "$WS5" RUNNING 0
STUB_STDERR_LINES=200 STUB_EXIT=1 \
  bash "$DRIVER" --project "$WS5" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_file_contains "$WS5/$LOG" "stderr line 200." "the TAIL is kept (the last line survives)"
assert_file_lacks    "$WS5/$LOG" "stderr line 1."   "the head is dropped (the tail is capped)"

# F. the capture file does not outlive the run. A driver that leaves one temp
#    file per session behind is the residue shape this project keeps auditing.
WS6=$(mk_proj); TD=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-errtmp.XXXXXX")
trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$TD"' EXIT
stub=$(write_stub "$WS6"); write_state "$WS6" RUNNING 0
STUB_STDERR='API Error: 401 invalid bearer token' STUB_EXIT=1 TMPDIR="$TD" \
  bash "$DRIVER" --project "$WS6" --claude-bin "$stub" --max-sessions 2 >/dev/null 2>&1
LEFT=$(find "$TD" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
assert_eq "0" "$LEFT" "no session-stderr temp file survives the driver (TMPDIR residue)"

report "session-stderr.test.sh"
