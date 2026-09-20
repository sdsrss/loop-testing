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

# G. MEDIUM-5: a RELATIVE $TMPDIR. mktemp honours it, and the redirect is
#    evaluated inside the subshell AFTER `cd "$PROJECT"`, where it no longer
#    resolves — the subshell died before exec and the session never ran at all.
#    Pre-fix driver was immune (it redirected to &1, no path), so this fix
#    introduced a way for the driver to launch nothing and report only exit=1.
WS7=$(mk_proj); RELHOME=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-relhome.XXXXXX")
trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$TD" "$WS7" "$RELHOME"' EXIT
mkdir -p "$RELHOME/reltmp"
stub=$(write_stub "$WS7"); write_state "$WS7" RUNNING 0
STUB_STDERR='RELATIVE-TMPDIR-MARKER' STUB_EXIT=1 \
  bash -c 'cd "$1" && TMPDIR=reltmp bash "$2" --project "$3" --claude-bin "$4" --max-sessions 1' \
  _ "$RELHOME" "$DRIVER" "$WS7" "$stub" >/dev/null 2>&1
assert_file_contains "$WS7/$LOG" "session 1: exit=" "a relative TMPDIR still launches the session (MEDIUM-5)"
# The capture must also ARRIVE. Bounding the writer already stopped the launch
# from dying, so "the session ran" no longer discriminates — without the
# absolutise the path resolves nowhere and the stderr is silently lost, which is
# the same silence D-05 exists to remove.
assert_file_contains "$WS7/$LOG" "RELATIVE-TMPDIR-MARKER" "and its stderr still reaches driver.log (MEDIUM-5)"

# H. HIGH-3: `Authorization: Basic <base64>` reached driver.log with the
#    credential intact — the rule matched, redacted the SCHEME word, and left the
#    secret. Both READMEs name Authorization: as masked, so this contradicted the
#    disclosure rather than being a gap outside it.
WS8=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$TD" "$WS7" "$RELHOME" "$WS8"' EXIT
stub=$(write_stub "$WS8"); write_state "$WS8" RUNNING 0
B64='YWRtaW46aHVudGVyMg=='
STUB_STDERR="> Authorization: Basic $B64" STUB_EXIT=1 \
  bash "$DRIVER" --project "$WS8" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_file_lacks "$WS8/$LOG" "$B64" "Authorization: Basic credential never reaches driver.log (HIGH-3)"
assert_file_contains "$WS8/$LOG" "Authorization" "the header name survives, so the line is still diagnostic"

# I. MEDIUM-6: the shapes the first redactor missed, each emerging byte-identical.
WS9=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$TD" "$WS7" "$RELHOME" "$WS8" "$WS9"' EXIT
stub=$(write_stub "$WS9"); write_state "$WS9" RUNNING 0
SECRETS='repo: https://ci-bot:glpat-SECRETVALUE123@gitlab.example.com/x.git
X-Api-Key: 3f8a9b2c1d4e5f60
{"api_key":"0123456789abcdef0123456789abcdef"}
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY'
STUB_STDERR="$SECRETS" STUB_EXIT=1 \
  bash "$DRIVER" --project "$WS9" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_file_lacks "$WS9/$LOG" "glpat-SECRETVALUE123"                      "URL userinfo is redacted (MEDIUM-6)"
assert_file_lacks "$WS9/$LOG" "3f8a9b2c1d4e5f60"                          "a 16-char labelled key is redacted (MEDIUM-6)"
assert_file_lacks "$WS9/$LOG" "0123456789abcdef0123456789abcdef"          "a JSON api_key value is redacted (MEDIUM-6)"
assert_file_lacks "$WS9/$LOG" "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"  "an AWS secret (with / and +) is redacted (MEDIUM-6)"
assert_file_contains "$WS9/$LOG" "gitlab.example.com" "the host survives redaction, so the line still diagnoses"

# J. HIGH-2: the capture file must not grow. Only the tail written to driver.log
#    was bounded; the file itself accumulated for a whole session — measured at
#    ~14 MB/s, which is 3 GB+ over a default 50-minute session, into what is
#    tmpfs on most Linux. The bound now sits on the WRITER, so nothing large is
#    ever on disk: sample $TMPDIR while a storming session runs.
WS10=$(mk_proj); TD2=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-storm.XXXXXX")
trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$TD" "$WS7" "$RELHOME" "$WS8" "$WS9" "$WS10" "$TD2"' EXIT
stub=$(write_stub "$WS10"); write_state "$WS10" RUNNING 0
( STUB_STDERR_STORM=12 STUB_EXIT=1 TMPDIR="$TD2" \
    bash "$DRIVER" --project "$WS10" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1 ) &
DRVPID=$!
PEAK=0; i=0
while kill -0 "$DRVPID" 2>/dev/null && [ "$i" -lt 100 ]; do
  sz=$(find "$TD2" -type f -exec wc -c {} + 2>/dev/null | awk 'END{print $1+0}')
  [ "${sz:-0}" -gt "$PEAK" ] && PEAK=$sz
  sleep 0.1 2>/dev/null || sleep 1
  i=$((i + 1))
done
wait "$DRVPID" 2>/dev/null
if [ "$PEAK" -le 65536 ]; then PASS=$((PASS+1));
else FAIL=$((FAIL+1)); echo "  FAIL: capture file grew to $PEAK bytes during a storming session (HIGH-2)" >&2; fi
assert_file_contains "$WS10/$LOG" "session 1 stderr" "a storming session still gets its tail logged"
LEFT2=$(find "$TD2" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
assert_eq "0" "$LEFT2" "no capture file (or .part) survives the storming run"

# K. LOW: the byte cap had no test — removing SESSION_ERR_BYTES stayed green.
#    One long single line must come back truncated, not whole.
WS11=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$TD" "$WS7" "$RELHOME" "$WS8" "$WS9" "$WS10" "$TD2" "$WS11"' EXIT
stub=$(write_stub "$WS11"); write_state "$WS11" RUNNING 0
# Spaces on purpose: one unbroken 5000-char alphanumeric run is exactly what the
# catch-all redaction rule masks, which would prove nothing about the byte cap.
LONG="HEADMARKER $(i=0; while [ "$i" -lt 600 ]; do printf 'filler%s ' "$i"; i=$((i+1)); done)TAILMARKER"
STUB_STDERR="$LONG" STUB_EXIT=1 \
  bash "$DRIVER" --project "$WS11" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_file_contains "$WS11/$LOG" "TAILMARKER" "the END of an over-long line is what is kept"
assert_file_lacks    "$WS11/$LOG" "HEADMARKER" "the head of an over-long line is dropped by the byte cap"

report "session-stderr.test.sh"
