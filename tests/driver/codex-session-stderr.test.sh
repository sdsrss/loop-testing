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

# E. Parity for the review findings, because "fixed on one driver" is what D-02
#    was. Authorization credential, the four redaction shapes, a relative
#    $TMPDIR, the byte cap, and temp-file residue — all on the codex side.
WS5=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5"' EXIT
stub=$(write_stub "$WS5"); write_state "$WS5" RUNNING 0
B64='YWRtaW46aHVudGVyMg=='
SECRETS="> Authorization: Basic $B64
repo: https://ci-bot:glpat-SECRETVALUE123@gitlab.example.com/x.git
X-Api-Key: 3f8a9b2c1d4e5f60
{\"api_key\":\"0123456789abcdef0123456789abcdef\"}
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
STUB_STDERR="$SECRETS" STUB_EXIT=1 \
  bash "$CODEX_DRIVER" --project "$WS5" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_lacks "$WS5/$LOG" "$B64"                                     "Authorization: Basic credential is redacted (HIGH-3)"
assert_file_lacks "$WS5/$LOG" "glpat-SECRETVALUE123"                     "URL userinfo is redacted (MEDIUM-6)"
assert_file_lacks "$WS5/$LOG" "3f8a9b2c1d4e5f60"                         "a 16-char labelled key is redacted (MEDIUM-6)"
assert_file_lacks "$WS5/$LOG" "0123456789abcdef0123456789abcdef"         "a JSON api_key value is redacted (MEDIUM-6)"
assert_file_lacks "$WS5/$LOG" "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY" "an AWS secret is redacted (MEDIUM-6)"
assert_file_contains "$WS5/$LOG" "gitlab.example.com" "the host survives, so the line still diagnoses"

# F. relative $TMPDIR (MEDIUM-5) — the codex driver builds the same path the
#    same way and evaluates it in a subshell that has cd'd to the project.
WS6=$(mk_proj); RELHOME=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-cxrelhome.XXXXXX")
trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$RELHOME"' EXIT
mkdir -p "$RELHOME/reltmp"
stub=$(write_stub "$WS6"); write_state "$WS6" RUNNING 0
( cd "$RELHOME" && TMPDIR=reltmp bash "$CODEX_DRIVER" --project "$WS6" --codex-bin "$stub" --no-protect --max-sessions 1 ) >/dev/null 2>&1
assert_file_contains "$WS6/$LOG" "session 1: exit=0" "a relative TMPDIR still launches the codex session (MEDIUM-5)"

# G. the byte cap and temp-file residue, which this suite omitted entirely.
WS7=$(mk_proj); TD=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-cxerrtmp.XXXXXX")
trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$RELHOME" "$WS7" "$TD"' EXIT
stub=$(write_stub "$WS7"); write_state "$WS7" RUNNING 0
STUB_STDERR_LINES=200 STUB_EXIT=1 TMPDIR="$TD" \
  bash "$CODEX_DRIVER" --project "$WS7" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_contains "$WS7/$LOG" "stderr line 200." "the TAIL is kept on the codex driver too"
assert_file_lacks    "$WS7/$LOG" "stderr line 1."   "the head is dropped on the codex driver too"
LEFTC=$(find "$TD" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
assert_eq "0" "$LEFTC" "no capture file survives the codex driver (TMPDIR residue)"

report "codex-session-stderr.test.sh"
