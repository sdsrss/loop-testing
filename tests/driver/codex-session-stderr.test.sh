#!/usr/bin/env bash
# unattended-codex.sh: the D-05 stderr capture, on the second driver.
#
# The two drivers maintain the same logic in two files, so a fix applied to one
# of them is not a fix — D-02 was exactly that (the loop driver absolutized its
# project path, the codex driver did not). These cases exist so the codex side
# cannot quietly keep sending the session's stderr to /dev/null.
set -u
. "$(cd "$(dirname "$0")" && pwd)/codex-lib.sh"

LOG=docs/looptesting/driver.log

# A. the session's stderr reaches the log.
WS=$(mk_proj); trap 'rm -rf "$WS"' EXIT
stub=$(write_stub "$WS"); write_state "$WS" RUNNING 0
STUB_STDERR='stream error: 429 rate limit exceeded' STUB_EXIT=1 \
  bash "$CODEX_DRIVER" --project "$WS" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_contains "$WS/$LOG" "429 rate limit exceeded" "codex driver.log carries the session's stderr (D-05)"

# B. redacted on the way in, same as the loop driver.
WS2=$(mk_proj); trap 'rm -rf "$WS" "$WS2"' EXIT
stub=$(write_stub "$WS2"); write_state "$WS2" RUNNING 0
KEY='sk-proj-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
STUB_STDERR="auth failed for key $KEY" STUB_EXIT=1 \
  bash "$CODEX_DRIVER" --project "$WS2" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_lacks    "$WS2/$LOG" "$KEY"     "the key itself never reaches the codex driver.log (D-05)"
assert_file_contains "$WS2/$LOG" "REDACTED" "the redaction is visible, not a silent drop"

# C. stdout is still not captured.
WS3=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3"' EXIT
stub=$(write_stub "$WS3"); write_state "$WS3" RUNNING 0
bash "$CODEX_DRIVER" --project "$WS3" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_lacks "$WS3/$LOG" "stub-codex: round=" "session stdout stays on /dev/null (transcript is not evidence)"

# D. same switch, same name — an escape hatch that works on only one of the two
#    drivers is not an escape hatch.
WS4=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4"' EXIT
stub=$(write_stub "$WS4"); write_state "$WS4" RUNNING 0
STUB_STDERR='stream error: 429 rate limit exceeded' STUB_EXIT=1 LOOP_TESTING_DISABLE_SESSION_STDERR=1 \
  bash "$CODEX_DRIVER" --project "$WS4" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_lacks "$WS4/$LOG" "429 rate limit exceeded" "LOOP_TESTING_DISABLE_SESSION_STDERR=1 captures nothing"

report "codex-session-stderr.test.sh"
