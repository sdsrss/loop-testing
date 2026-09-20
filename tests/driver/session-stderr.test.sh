#!/usr/bin/env bash
# unattended-loop.sh: a failed session must say WHY (audit D-05).
#
# The agent session's stderr — an expired key, a rate limit, an unknown flag, a
# bad working directory — went to /dev/null, so every one of those reached
# driver.log as `exit=N` and the no-progress breaker's verdict, with nothing to
# tell them apart. D-02 survived to the audit for exactly that reason.
#
# THIS IS THE SECOND ATTEMPT. The first shipped as a bounded writer —
# `2> >(tail -c … > "$SINK.part"; mv -f "$SINK.part" "$SINK")` — and was pulled
# from v0.12.0 whole (98095b7) after two review passes found 1 CRITICAL, 2 HIGH,
# 4 MEDIUM and 3 LOW inside it. The CRITICAL came from the design, not the
# instance: with the documented opt-out the sink is /dev/null, a normal user
# cannot create /dev/null.part, so the writer exited, the session's stderr pipe
# had no reader and every session died of SIGPIPE at round 0 — and under root
# (Docker's default) the rename replaced the /dev/null device node with a
# regular file holding the unredacted tail.
#
# So the capture is now a PLAIN FILE REDIRECT, `2>"$file"`, whose O_TRUNC is
# itself the per-session truncator. There is no writer process, no .part, no
# rename and nothing to wait for — cases D2 and D3 below exist to keep it that
# way, and they are the two halves of that CRITICAL.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

LOG=docs/looptesting/driver.log
CLEAN=""
cleanup() { [ -n "$CLEAN" ] && chmod -R u+rwX $CLEAN 2>/dev/null; rm -rf $CLEAN; }  # unquoted: a list
trap cleanup EXIT

# A. the session's stderr reaches the log.
WS=$(mk_proj); CLEAN="$WS"
stub=$(write_stub "$WS"); write_state "$WS" RUNNING 0
STUB_STDERR='API Error: 401 invalid bearer token' STUB_EXIT=1 \
  bash "$DRIVER" --project "$WS" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_file_contains "$WS/$LOG" "401 invalid bearer token" "driver.log carries the session's stderr (D-05)"

# B. and is redacted on the way in. driver.log sits in the evidence directory the
#    user is told to read and attach, so a key echoed by a failing endpoint must
#    not be what this fix delivers there.
WS2=$(mk_proj); CLEAN="$CLEAN $WS2"
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
WS3=$(mk_proj); CLEAN="$CLEAN $WS3"
stub=$(write_stub "$WS3"); write_state "$WS3" RUNNING 0
bash "$DRIVER" --project "$WS3" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_file_lacks "$WS3/$LOG" "stub: round=" "session stdout stays on /dev/null (transcript is not evidence)"

# D. switchable off for anyone who would rather the agent's stderr never be
#    written down at all.
WS4=$(mk_proj); CLEAN="$CLEAN $WS4"
stub=$(write_stub "$WS4"); write_state "$WS4" RUNNING 0
STUB_STDERR='API Error: 401 invalid bearer token' STUB_EXIT=1 LOOP_TESTING_DISABLE_SESSION_STDERR=1 \
  bash "$DRIVER" --project "$WS4" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_file_lacks "$WS4/$LOG" "401 invalid bearer token" "LOOP_TESTING_DISABLE_SESSION_STDERR=1 captures nothing"
assert_file_contains "$WS4/$LOG" "session 1: exit=" "the session itself still ran and was logged"

# D2. THE CRITICAL, first half. The opt-out must not cost the session its life.
#     The pulled design turned the sink into /dev/null.part, which a normal user
#     cannot create, leaving the stderr pipe without a reader: every session died
#     of SIGPIPE at round 0 and reported exit=13. The stub exits 0 here, so the
#     logged code IS the discriminator — 13 is the pulled design, 0 is a session
#     that ran. A plain redirect to /dev/null has no reader to lose.
WS5=$(mk_proj); CLEAN="$CLEAN $WS5"
stub=$(write_stub "$WS5"); write_state "$WS5" RUNNING 0
STUB_STDERR='some stderr chatter' LOOP_TESTING_DISABLE_SESSION_STDERR=1 \
  bash "$DRIVER" --project "$WS5" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_file_contains "$WS5/$LOG" "session 1: exit=0" "the opt-out does not SIGPIPE the session (98095b7 CRITICAL)"
assert_file_lacks    "$WS5/$LOG" "exit=13"           "and specifically not exit=13, which is what it looked like"

# D3. THE CRITICAL, second half. Under a root user /dev/null.part IS creatable,
#     and the pulled design's rename replaced the /dev/null DEVICE NODE with a
#     regular file holding the unredacted tail — a system-wide corruption from a
#     diagnostics feature. Nothing in this design writes a path derived from the
#     sink, but the check is one stat and it names what must never happen again.
[ -c /dev/null ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: /dev/null is no longer a character device — a driver run replaced it" >&2; }

# E. the tail is bounded: a chatty session must not turn driver.log into its
#    transcript by the back door.
WS6=$(mk_proj); CLEAN="$CLEAN $WS6"
stub=$(write_stub "$WS6"); write_state "$WS6" RUNNING 0
STUB_STDERR_LINES=200 STUB_EXIT=1 \
  bash "$DRIVER" --project "$WS6" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_file_contains "$WS6/$LOG" "stderr line 200." "the TAIL is kept (the last line survives)"
assert_file_lacks    "$WS6/$LOG" "stderr line 1."   "the head is dropped (the tail is capped)"

# F. the capture file does not outlive the run. A driver that leaves one temp
#    file per session behind is the residue shape this project keeps auditing.
WS7=$(mk_proj); TD=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-errtmp.XXXXXX"); CLEAN="$CLEAN $WS7 $TD"
stub=$(write_stub "$WS7"); write_state "$WS7" RUNNING 0
STUB_STDERR='API Error: 401 invalid bearer token' STUB_EXIT=1 TMPDIR="$TD" \
  bash "$DRIVER" --project "$WS7" --claude-bin "$stub" --max-sessions 2 >/dev/null 2>&1
LEFT=$(find "$TD" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
assert_eq "0" "$LEFT" "no session-stderr temp file survives the driver (TMPDIR residue)"

# G. MEDIUM-5 from the pulled round: a RELATIVE $TMPDIR. mktemp honours it, and
#    the redirect is evaluated inside the subshell AFTER `cd "$PROJECT"`, where
#    it no longer resolves — the subshell died before exec and the session never
#    ran at all. The pre-fix driver was immune (it redirected to &1, no path), so
#    this feature is what introduces the possibility; it stays tested.
WS8=$(mk_proj); RELHOME=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-relhome.XXXXXX"); CLEAN="$CLEAN $WS8 $RELHOME"
mkdir -p "$RELHOME/reltmp"
stub=$(write_stub "$WS8"); write_state "$WS8" RUNNING 0
STUB_STDERR='RELATIVE-TMPDIR-MARKER' STUB_EXIT=1 \
  bash -c 'cd "$1" && TMPDIR=reltmp bash "$2" --project "$3" --claude-bin "$4" --max-sessions 1' \
  _ "$RELHOME" "$DRIVER" "$WS8" "$stub" >/dev/null 2>&1
assert_file_contains "$WS8/$LOG" "session 1: exit=" "a relative TMPDIR still launches the session (MEDIUM-5)"
assert_file_contains "$WS8/$LOG" "RELATIVE-TMPDIR-MARKER" "and its stderr still reaches driver.log (MEDIUM-5)"

# H. an UNWRITABLE $TMPDIR degrades the capture, never the run. mktemp fails,
#    there is no file, and the session goes back to what v0.11.0 did. The pulled
#    design died here too (read-only TMPDIR was the other trigger of the
#    SIGPIPE). Under a root user this case is not discriminating — root writes
#    into a 0500 directory anyway — so it asserts the invariant that holds for
#    both: the session ran.
WS9=$(mk_proj); ROTMP=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-rotmp.XXXXXX"); CLEAN="$CLEAN $WS9 $ROTMP"
stub=$(write_stub "$WS9"); write_state "$WS9" RUNNING 0
chmod 500 "$ROTMP"
STUB_STDERR='READONLY-TMPDIR-MARKER' TMPDIR="$ROTMP" \
  bash "$DRIVER" --project "$WS9" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
chmod 700 "$ROTMP"
assert_file_contains "$WS9/$LOG" "session 1: exit=0" "an unwritable TMPDIR costs the capture, not the session"

# I. redaction false positives. The pulled round's rule matched `key` as a
#    SUBSTRING and took any value after it, so `monkey:`, `keyboard:` and
#    `token: expected ';'` were rewritten to ***REDACTED*** — the feature
#    deleting exactly the diagnostics it exists to deliver.
#
#    Three bounds do this, and the cases are written so that each is the ONLY
#    thing saving its line. A first version of this case used short values
#    (`monkey: 3`), which the 10-character value floor alone already saves — it
#    stayed green with both boundary rules reverted, i.e. it asserted the fix and
#    tested the floor. Every value below is 10+ characters for that reason.
WS10=$(mk_proj); CLEAN="$CLEAN $WS10"
stub=$(write_stub "$WS10"); write_state "$WS10" RUNNING 0
FP=$(printf 'monkey: eating_all_the_bananas\nmonkeypatch: applied_to_module_alpha\nkeyboard: /dev/input/by-id/usb-kbd-event\ntoken: expected %s;%s at line 42\nmodule not found: ./src/keys.js\n' "'" "'")
STUB_STDERR="$FP" STUB_EXIT=1 \
  bash "$DRIVER" --project "$WS10" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
# START boundary: 'key' preceded by a letter is not a key name.
assert_file_contains "$WS10/$LOG" "monkey: eating_all_the_bananas"    "'monkey' + a long value is not a key (start boundary)"
assert_file_contains "$WS10/$LOG" "monkeypatch: applied_to_module_alpha" "'monkeypatch' + a long value is not a key either"
# END boundary: 'key' at the start of a line passes the start rule, so only the
# trailing one keeps 'keyboard' out.
assert_file_contains "$WS10/$LOG" "/dev/input/by-id/usb-kbd-event"   "'keyboard' + a long value is not a key (end boundary)"
# Value floor: the label IS a real one here, and the value is a parser message.
assert_file_contains "$WS10/$LOG" "token: expected ';'"              "a parser error after 'token:' survives (value floor)"
assert_file_contains "$WS10/$LOG" "./src/keys.js"                    "a path containing 'keys' is not a credential"

# J. redaction true positives, in the shapes a failing endpoint actually prints.
#    Each line keeps a word of diagnostic around the secret, so the assertions
#    below cannot pass by the whole line having been dropped.
WS11=$(mk_proj); CLEAN="$CLEAN $WS11"
stub=$(write_stub "$WS11"); write_state "$WS11" RUNNING 0
TP=$(printf 'call failed X-Api-Key: deadbeefdeadbeefdeadbeef\nheader Authorization: Basic dXNlcjpwYXNzd29yZA==\nfetch https://ci-bot:glpat-SECRETVALUE123@git.example.com/r failed\nenv AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIbPxRfiCYEXAMPLEKEY rejected\nconfig apikey=zyxwvu9876543210 refused\n')
STUB_STDERR="$TP" STUB_EXIT=1 \
  bash "$DRIVER" --project "$WS11" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_file_lacks    "$WS11/$LOG" "deadbeefdeadbeefdeadbeef"        "X-Api-Key's value is masked (boundary is '-', not a letter)"
assert_file_contains "$WS11/$LOG" "call failed"                     "and the line around it survives"
assert_file_lacks    "$WS11/$LOG" "dXNlcjpwYXNzd29yZA=="            "Authorization: takes the rest of the line, not just the scheme word"
assert_file_lacks    "$WS11/$LOG" "glpat-SECRETVALUE123"            "URL userinfo is masked"
assert_file_contains "$WS11/$LOG" "git.example.com"                 "and the host it was failing against survives"
assert_file_lacks    "$WS11/$LOG" "wJalrXUtnFEMIbPxRfiCYEXAMPLEKEY" "AWS_SECRET_ACCESS_KEY's value is masked"
assert_file_contains "$WS11/$LOG" "rejected"                        "and the verdict after it survives"
# The glued compounds are listed, not inferred: 'apikey' has no separator before
# 'key', so the start-boundary rule would drop it without the explicit prefix.
assert_file_lacks    "$WS11/$LOG" "zyxwvu9876543210"                "a glued 'apikey=' is still masked (listed prefix)"
assert_file_contains "$WS11/$LOG" "refused"                         "and the verdict after that one survives too"

report "session-stderr.test.sh"
