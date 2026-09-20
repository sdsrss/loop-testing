#!/usr/bin/env bash
# unattended-codex.sh: a failed session must say WHY (audit D-05).
#
# The codex driver carries its own copy of the capture — same shape as
# unattended-loop.sh, separate code. This project has been bitten twice by
# testing one copy of a duplicated routine and shipping the other (the audit's
# structural finding #2), so the copy gets its own cases, including its own
# redaction cases: a boundary rule fixed in one sed pipeline and not the other
# is exactly the failure this file exists to catch.
#
# See tests/driver/session-stderr.test.sh for why the capture is a plain file
# redirect rather than the bounded writer pulled in 98095b7.
set -u
. "$(cd "$(dirname "$0")" && pwd)/codex-lib.sh"

LOG=docs/looptesting/driver.log
CLEAN=""
cleanup_ws() { [ -n "$CLEAN" ] && chmod -R u+rwX $CLEAN 2>/dev/null; rm -rf $CLEAN; }  # unquoted: a list
trap cleanup_ws EXIT

# A. the session's stderr reaches the log.
WS=$(mk_proj); CLEAN="$WS"
stub=$(write_stub "$WS"); write_state "$WS" RUNNING 0
STUB_STDERR='codex: stream error: 429 rate limited' STUB_EXIT=1 \
  bash "$CODEX_DRIVER" --project "$WS" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_contains "$WS/$LOG" "429 rate limited" "driver.log carries the session's stderr (D-05)"

# B. redacted on the way in.
WS2=$(mk_proj); CLEAN="$CLEAN $WS2"
stub=$(write_stub "$WS2"); write_state "$WS2" RUNNING 0
KEY='sk-proj-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
STUB_STDERR="auth failed for key $KEY" STUB_EXIT=1 \
  bash "$CODEX_DRIVER" --project "$WS2" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_lacks    "$WS2/$LOG" "$KEY"     "the key itself never reaches driver.log (D-05)"
assert_file_contains "$WS2/$LOG" "REDACTED" "the redaction is visible, not a silent drop"
assert_file_contains "$WS2/$LOG" "auth failed for key" "redaction keeps the diagnostic around the secret"

# C. stdout is NOT captured — it is the transcript.
WS3=$(mk_proj); CLEAN="$CLEAN $WS3"
stub=$(write_stub "$WS3"); write_state "$WS3" RUNNING 0
bash "$CODEX_DRIVER" --project "$WS3" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_lacks "$WS3/$LOG" "stub-codex: round=" "session stdout stays on /dev/null"

# D + D2. the opt-out captures nothing AND does not cost the session its life.
#         The pulled design resolved the sink to /dev/null.part here, lost the
#         pipe's reader and killed every session with SIGPIPE (exit=13). The stub
#         exits 0, so the logged code is the discriminator.
WS4=$(mk_proj); CLEAN="$CLEAN $WS4"
stub=$(write_stub "$WS4"); write_state "$WS4" RUNNING 0
STUB_STDERR='codex: stream error: 429 rate limited' LOOP_TESTING_DISABLE_SESSION_STDERR=1 \
  bash "$CODEX_DRIVER" --project "$WS4" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_lacks    "$WS4/$LOG" "429 rate limited" "LOOP_TESTING_DISABLE_SESSION_STDERR=1 captures nothing"
assert_file_contains "$WS4/$LOG" "session 1: exit=0" "the opt-out does not SIGPIPE the session (98095b7 CRITICAL)"
assert_file_lacks    "$WS4/$LOG" "exit=13"           "and specifically not exit=13, which is what it looked like"
[ -c /dev/null ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: /dev/null is no longer a character device — a driver run replaced it" >&2; }

# E. the tail is bounded.
WS5=$(mk_proj); CLEAN="$CLEAN $WS5"
stub=$(write_stub "$WS5"); write_state "$WS5" RUNNING 0
STUB_STDERR_LINES=200 STUB_EXIT=1 \
  bash "$CODEX_DRIVER" --project "$WS5" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_contains "$WS5/$LOG" "stderr line 200." "the TAIL is kept (the last line survives)"
assert_file_lacks    "$WS5/$LOG" "stderr line 1."   "the head is dropped (the tail is capped)"

# F. no temp residue.
WS6=$(mk_proj); TD=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-cxerrtmp.XXXXXX"); CLEAN="$CLEAN $WS6 $TD"
stub=$(write_stub "$WS6"); write_state "$WS6" RUNNING 0
STUB_STDERR='codex: stream error' STUB_EXIT=1 TMPDIR="$TD" \
  bash "$CODEX_DRIVER" --project "$WS6" --codex-bin "$stub" --no-protect --max-sessions 2 >/dev/null 2>&1
LEFT=$(find "$TD" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
assert_eq "0" "$LEFT" "no session-stderr temp file survives the driver (TMPDIR residue)"

# G. a RELATIVE $TMPDIR still launches the session AND still captures.
WS7=$(mk_proj); RELHOME=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-cxrelhome.XXXXXX"); CLEAN="$CLEAN $WS7 $RELHOME"
mkdir -p "$RELHOME/reltmp"
stub=$(write_stub "$WS7"); write_state "$WS7" RUNNING 0
STUB_STDERR='RELATIVE-TMPDIR-MARKER' STUB_EXIT=1 \
  bash -c 'cd "$1" && TMPDIR=reltmp bash "$2" --project "$3" --codex-bin "$4" --no-protect --max-sessions 1' \
  _ "$RELHOME" "$CODEX_DRIVER" "$WS7" "$stub" >/dev/null 2>&1
assert_file_contains "$WS7/$LOG" "session 1: exit=" "a relative TMPDIR still launches the session (MEDIUM-5)"
assert_file_contains "$WS7/$LOG" "RELATIVE-TMPDIR-MARKER" "and its stderr still reaches driver.log (MEDIUM-5)"

# H. an unwritable $TMPDIR costs the capture, not the run. (Not discriminating
#    under root, which writes into a 0500 directory anyway — the asserted
#    invariant holds either way.)
WS8=$(mk_proj); ROTMP=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-cxrotmp.XXXXXX"); CLEAN="$CLEAN $WS8 $ROTMP"
stub=$(write_stub "$WS8"); write_state "$WS8" RUNNING 0
chmod 500 "$ROTMP"
STUB_STDERR='READONLY-TMPDIR-MARKER' TMPDIR="$ROTMP" \
  bash "$CODEX_DRIVER" --project "$WS8" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
chmod 700 "$ROTMP"
assert_file_contains "$WS8/$LOG" "session 1: exit=0" "an unwritable TMPDIR costs the capture, not the session"

# I. this copy's redaction must have the same three bounds: the secret word
#    starts at a non-alphanumeric boundary, ends at one, and the value is long
#    enough to be a credential. Values are 10+ characters so that the boundary
#    rules — not the value floor — are what each line proves.
WS9=$(mk_proj); CLEAN="$CLEAN $WS9"
stub=$(write_stub "$WS9"); write_state "$WS9" RUNNING 0
FP=$(printf 'monkey: eating_all_the_bananas\nkeyboard: /dev/input/by-id/usb-kbd-event\ntoken: expected %s;%s at line 42\n' "'" "'")
STUB_STDERR="$FP" STUB_EXIT=1 \
  bash "$CODEX_DRIVER" --project "$WS9" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_contains "$WS9/$LOG" "monkey: eating_all_the_bananas"  "'monkey' + a long value is not a key in this copy (start boundary)"
assert_file_contains "$WS9/$LOG" "/dev/input/by-id/usb-kbd-event"  "'keyboard' + a long value is not a key in this copy (end boundary)"
assert_file_contains "$WS9/$LOG" "token: expected ';'"             "a parser error after 'token:' survives in this copy too"

# J. and the true positives it must still mask.
WS10=$(mk_proj); CLEAN="$CLEAN $WS10"
stub=$(write_stub "$WS10"); write_state "$WS10" RUNNING 0
TP=$(printf 'call failed X-Api-Key: deadbeefdeadbeefdeadbeef\nheader Authorization: Basic dXNlcjpwYXNzd29yZA==\nenv AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIbPxRfiCYEXAMPLEKEY rejected\nconfig apikey=zyxwvu9876543210 refused\n')
STUB_STDERR="$TP" STUB_EXIT=1 \
  bash "$CODEX_DRIVER" --project "$WS10" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_lacks    "$WS10/$LOG" "deadbeefdeadbeefdeadbeef"        "X-Api-Key's value is masked in this copy"
assert_file_lacks    "$WS10/$LOG" "dXNlcjpwYXNzd29yZA=="            "Authorization: takes the rest of the line in this copy"
assert_file_lacks    "$WS10/$LOG" "wJalrXUtnFEMIbPxRfiCYEXAMPLEKEY" "AWS_SECRET_ACCESS_KEY's value is masked in this copy"
assert_file_contains "$WS10/$LOG" "rejected"                        "and the verdict after it survives"
assert_file_lacks    "$WS10/$LOG" "zyxwvu9876543210"                "a glued 'apikey=' is still masked in this copy (listed prefix)"

report "codex-session-stderr.test.sh"
