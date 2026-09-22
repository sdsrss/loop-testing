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

# Without timeout/gtimeout the driver refuses to start (DR-7), so every case here
# would measure that refusal; skip the file whole via the run-all protocol.
require_watchdog_binary

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
# A CANARY, not a discriminator, and it is labelled as one because it has been
# mistaken for coverage twice in review. No mutation of this driver can fail it
# — it passes with the feature deleted entirely — and it cannot establish WHAT
# replaced the device node if it ever does fail. It is here because the pulled
# design did replace it, and because the check is one stat.
[ -c /dev/null ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: /dev/null is not a character device on this host — something replaced it; this canary cannot say what" >&2; }

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
FP=$(printf 'monkey: eating_all_the_bananas\nkeyboard: /dev/input/by-id/usb-kbd-event\ntoken: expected %s;%s at line 42\nsecretary: Jane Smith Esquire III\n' "'" "'")
STUB_STDERR="$FP" STUB_EXIT=1 \
  bash "$CODEX_DRIVER" --project "$WS9" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_contains "$WS9/$LOG" "monkey: eating_all_the_bananas"  "'monkey' + a long value is not a key in this copy (start boundary)"
assert_file_contains "$WS9/$LOG" "/dev/input/by-id/usb-kbd-event"  "'keyboard' + a long value is not a key in this copy (end boundary)"
assert_file_contains "$WS9/$LOG" "token: expected ';'"             "a parser error after 'token:' survives in this copy too"
assert_file_contains "$WS9/$LOG" "secretary: Jane Smith Esquire III" "'secretary' is not a secret in this copy (end boundary alone)"

# J. and the true positives it must still mask.
WS10=$(mk_proj); CLEAN="$CLEAN $WS10"
stub=$(write_stub "$WS10"); write_state "$WS10" RUNNING 0
TP=$(printf 'call failed X-Api-Key: deadbeefdeadbeefdeadbeef\nheader Authorization: Basic dXNlcjpwYXNzd29yZA==\nenv AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY rejected\nconfig apikey=zyxwvu9876543210 refused\nbody {\"accessToken\": \"aaaaaaaaaa1111111111\"} denied\nenv dbPassword=cccccccccc3333333333 denied\n')
STUB_STDERR="$TP" STUB_EXIT=1 \
  bash "$CODEX_DRIVER" --project "$WS10" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_lacks    "$WS10/$LOG" "deadbeefdeadbeefdeadbeef"        "X-Api-Key's value is masked in this copy"
assert_file_lacks    "$WS10/$LOG" "dXNlcjpwYXNzd29yZA=="            "Authorization: takes the rest of the line in this copy"
assert_file_lacks    "$WS10/$LOG" "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" "AWS_SECRET_ACCESS_KEY's value is masked in this copy"
assert_file_contains "$WS10/$LOG" "rejected"                        "and the verdict after it survives"
assert_file_lacks    "$WS10/$LOG" "zyxwvu9876543210"                "a glued 'apikey=' is still masked in this copy (listed prefix)"
assert_file_lacks    "$WS10/$LOG" "aaaaaaaaaa1111111111"            "camelCase accessToken is masked in this copy too"
assert_file_lacks    "$WS10/$LOG" "cccccccccc3333333333"            "camelCase dbPassword is masked in this copy too"
assert_file_contains "$WS10/$LOG" "denied"                          "and the verdicts after those survive"

# K. one file per session, as a property. Reusing one file and relying on the
#    redirect's O_TRUNC leaves every other case in this suite green — O_TRUNC
#    resets SIZE, not the OFFSET of an already-open file description, so a
#    grandchild holding fd 2 from session 1 writes into session 2's file at its
#    stale offset and pushes session 2's own error out of the tail window.
WS11=$(mk_proj); CLEAN="$CLEAN $WS11"
stub=$(write_stub "$WS11"); write_state "$WS11" RUNNING 0
STUB_GRANDCHILD=1 \
  bash "$CODEX_DRIVER" --project "$WS11" --codex-bin "$stub" --no-protect --max-sessions 2 >/dev/null 2>&1
assert_file_contains "$WS11/$LOG" "THE REAL ERROR OF SESSION 2 WAS AN EXPIRED KEY" \
  "session 2's own stderr survives a session-1 grandchild holding fd 2"
assert_file_lacks    "$WS11/$LOG" "LATE WRITE FROM SESSION ONE GRANDCHILD" \
  "and session 1's late write is not filed under session 2"
[ -f "$WS11/gc-done" ] && PASS=$((PASS+1)) \
  || { FAIL=$((FAIL+1)); echo "  FAIL: the grandchild never wrote — case K proved nothing (self-probe)" >&2; }

# L. the byte cap amputates labels: a credential straddling 4000 bytes loses its
#    `"api_key":"` before any rule sees it. The partial first line is dropped.
WS12=$(mk_proj); CLEAN="$CLEAN $WS12"
stub=$(write_stub "$WS12"); write_state "$WS12" RUNNING 0
STUB_STDERR_LONGLINE=1 STUB_EXIT=1 \
  bash "$CODEX_DRIVER" --project "$WS12" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_lacks    "$WS12/$LOG" "6543210ABCDEFGHIJK" "a credential straddling the byte cap is not published as a fragment"
assert_file_lacks    "$WS12/$LOG" "ENDOFLONGLINE"      "and no other part of the over-long line is published either"
assert_file_contains "$WS12/$LOG" "nothing shown"      "and the log says why it is empty"

# M. lexer/parser vocabulary, in this copy too — lowercase glued names and
#    UpperCamelCase class names must both survive the camelCase rule.
WS13=$(mk_proj); CLEAN="$CLEAN $WS13"
stub=$(write_stub "$WS13"); write_state "$WS13" RUNNING 0
LX=$(printf 'nexttoken: IDENTIFIER_FOO\nSyntaxToken: unexpected_end_of_input\nHTMLToken: unexpected end of input\n')
STUB_STDERR="$LX" STUB_EXIT=1 \
  bash "$CODEX_DRIVER" --project "$WS13" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_contains "$WS13/$LOG" "nexttoken: IDENTIFIER_FOO"            "a lexer's lowercase 'nexttoken' survives in this copy"
assert_file_contains "$WS13/$LOG" "SyntaxToken: unexpected_end_of_input" "an UpperCamelCase class name survives in this copy"
assert_file_contains "$WS13/$LOG" "HTMLToken: unexpected end of input"   "and so does HTMLToken"

# N. the quoted JSON authorization header — review's CRITICAL — in this copy.
WS14=$(mk_proj); CLEAN="$CLEAN $WS14"
stub=$(write_stub "$WS14"); write_state "$WS14" RUNNING 0
STUB_STDERR='{"status":429,"headers":{"authorization":"Basic Y2ktYm90OnN1cGVyc2VjcmV0"},"retry_after":30}' STUB_EXIT=1 \
  bash "$CODEX_DRIVER" --project "$WS14" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_lacks    "$WS14/$LOG" "Y2ktYm90OnN1cGVyc2VjcmV0" "a quoted JSON authorization header is masked in this copy"
assert_file_contains "$WS14/$LOG" "retry_after"              "and the rest of the JSON survives"

# O. the URL-userinfo rule, which this copy had no case for at all.
WS15=$(mk_proj); CLEAN="$CLEAN $WS15"
stub=$(write_stub "$WS15"); write_state "$WS15" RUNNING 0
STUB_STDERR='fetch https://ci-bot:glpat-SECRETVALUE123@git.example.com/r failed' STUB_EXIT=1 \
  bash "$CODEX_DRIVER" --project "$WS15" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_lacks    "$WS15/$LOG" "glpat-SECRETVALUE123" "URL userinfo is masked in this copy too"
assert_file_contains "$WS15/$LOG" "git.example.com"      "and the host it was failing against survives"

# P. PascalCase credentials — the leak the first camelCase rule left open in this
#    copy too. .NET appsettings.json convention plus Go's %+v on oauth2 structs.
WS16=$(mk_proj); CLEAN="$CLEAN $WS16"
stub=$(write_stub "$WS16"); write_state "$WS16" RUNNING 0
PC=$(printf 'config AccessToken=aaaaaaaaaa1111111111 rejected\nconfig ClientSecret=bbbbbbbbbb2222222222 rejected\ndump &Token{AccessToken:eeeeeeeeee5555555555 TokenType:Bearer}\n')
STUB_STDERR="$PC" STUB_EXIT=1 \
  bash "$CODEX_DRIVER" --project "$WS16" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_lacks    "$WS16/$LOG" "aaaaaaaaaa1111111111" "PascalCase AccessToken is masked in this copy"
assert_file_lacks    "$WS16/$LOG" "bbbbbbbbbb2222222222" "PascalCase ClientSecret is masked in this copy"
assert_file_lacks    "$WS16/$LOG" "eeeeeeeeee5555555555" "a Go %+v oauth2.Token dump is masked in this copy"
assert_file_contains "$WS16/$LOG" "TokenType:Bearer"     "and the struct's other fields survive"

# Q. the lexer API names this copy must also leave alone.
WS17=$(mk_proj); CLEAN="$CLEAN $WS17"
stub=$(write_stub "$WS17"); write_state "$WS17" RUNNING 0
API=$(printf 'nextToken: IDENTIFIER_FOO_X\nreadToken: unexpected_char_here\nexpectToken: PUNCTUATION_SEMI\n')
STUB_STDERR="$API" STUB_EXIT=1 \
  bash "$CODEX_DRIVER" --project "$WS17" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_contains "$WS17/$LOG" "nextToken: IDENTIFIER_FOO_X"    "lexer API name nextToken survives in this copy"
assert_file_contains "$WS17/$LOG" "readToken: unexpected_char_here" "and readToken"
assert_file_contains "$WS17/$LOG" "expectToken: PUNCTUATION_SEMI"  "and expectToken"

# M. THE BYTE CAP MUST SURVIVE A PADDING `wc`. BSD/macOS `wc` right-aligns its
#    count in a fixed-width field, and command substitution strips trailing
#    newlines but not leading spaces — so a bare `wc -c` returns "      4091",
#    a numeric guard reads the space as non-numeric, the size becomes 0, the
#    truncation branch is never taken, and the cap does not exist on that
#    platform. CI is ubuntu-only on purpose, so nothing mechanical would catch
#    it; this shim is the mechanism. Six other places in the repo already strip
#    that padding, including :150 and :159 of the driver itself.
WS19=$(mk_proj); SHIM=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-wcshim.XXXXXX"); CLEAN="$CLEAN $WS19 $SHIM"
# `command -v wc` is resolved HERE, while the shim is not yet on PATH, so it
# names the real binary — same idiom as run_broken_ps at shutdown.test.sh:306.
# Hard-coding /usr/bin/wc emits nothing on a host that keeps it elsewhere
# (NixOS, minimal containers), which fails this case SAFE but for the wrong
# reason.
cat > "$SHIM/wc" <<WCSHIM
#!/usr/bin/env bash
# BSD/macOS wc: right-aligned in a fixed-width field.
printf '%10s\\n' "\$($(command -v wc) "\$@" | tr -d ' ')"
WCSHIM
chmod +x "$SHIM/wc"
stub=$(write_stub "$WS19"); write_state "$WS19" RUNNING 0
STUB_STDERR_LONGLINE=1 STUB_EXIT=1 PATH="$SHIM:$PATH" \
  bash "$CODEX_DRIVER" --project "$WS19" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_lacks    "$WS19/$LOG" "6543210ABCDEFGHIJK" "no fragment is published under a padding wc either"
assert_file_contains "$WS19/$LOG" "nothing shown"      "a padding wc does not disable the byte cap (BSD/macOS) — this is the discriminating one"

# N. …and the empty body's OTHER cause. `[ -z "$body" ]` is reached whenever the
#    body ends up empty, and truncation is only one way. A capture holding a
#    single newline used to produce "the tail was one line longer than 4000
#    bytes" about a 1-byte file — a false statement written into the evidence
#    directory the user is told to attach.
WS20=$(mk_proj); CLEAN="$CLEAN $WS20"
stub=$(write_stub "$WS20"); write_state "$WS20" RUNNING 0
STUB_STDERR_BLANK=1 STUB_EXIT=1 \
  bash "$CODEX_DRIVER" --project "$WS20" --codex-bin "$stub" --no-protect --max-sessions 1 >/dev/null 2>&1
assert_file_contains "$WS20/$LOG" "no printable line"   "a blank capture says what actually happened"
assert_file_lacks    "$WS20/$LOG" "one line longer than" "and does not claim a cause it never checked"

# O. THE DISPOSAL BRANCH, which no end-to-end fixture can reach. `session_err_close`
#    clears SESSION_ERR before any normal exit reaches shutdown_handler, so both
#    arms are dead on every path the driver can be driven down — review inverted
#    the whole condition and this suite stayed green. It cannot be staged either:
#    `kill` is a shell builtin so no PATH shim intercepts the liveness check, a
#    `ps` shim sits on a branch that never runs (child_alive does `kill -0`
#    first), and the zombie route was measured and disproved. An env var that
#    forces the verdict was rejected as disproportionate: faking liveness is the
#    safety property the whole D-01 design rests on.
#
#    So it is extracted and exercised directly. The anchor is the function's own
#    definition line — NOT surrounding prose, which was tried and rejected: the
#    block's comments quote the code around it, so renaming the real anchor still
#    matched inside a comment and the harness silently tested the wrong region.
#    The first assertion is the rot guard: if the function is renamed or reshaped,
#    the extraction stops looking like a function and this fails loudly instead of
#    passing against nothing.
DISP=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-cxdisp.XXXXXX"); CLEAN="$CLEAN $DISP"
{ echo '#!/usr/bin/env bash'
  echo 'set -u'
  echo 'CHILD_SURVIVED="${CHILD_SURVIVED:-}"; SESSION_ERR="${SESSION_ERR:-}"'
  awk '/^session_err_dispose\(\) \{/,/^\}/' "$REPO_ROOT/skills/loop-testing/scripts/unattended-codex.sh"
  echo 'session_err_dispose'
} > "$DISP/dispose.sh"
if grep -qF 'session_err_dispose() {' "$DISP/dispose.sh" && grep -qF 'rm -f' "$DISP/dispose.sh"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); echo "  FAIL: session_err_dispose could not be extracted — this case is testing nothing" >&2
fi

# survivor arm: the file is the only record of what the unkillable session was
# doing, so it is kept and its path is named.
: > "$DISP/keep.err"
CHILD_SURVIVED=999999 SESSION_ERR="$DISP/keep.err" bash "$DISP/dispose.sh" 2>"$DISP/keep.stderr"
[ -f "$DISP/keep.err" ] && PASS=$((PASS+1)) \
  || { FAIL=$((FAIL+1)); echo "  FAIL: a session that outlived SIGKILL had its stderr capture deleted" >&2; }
assert_file_contains "$DISP/keep.stderr" "$DISP/keep.err" "and the kept capture's path is named on stderr"
assert_file_contains "$DISP/keep.stderr" "NOT redacted"   "and the message says the kept file is not redacted"

# normal arm: nothing survived, so nothing is kept.
: > "$DISP/drop.err"
CHILD_SURVIVED="" SESSION_ERR="$DISP/drop.err" bash "$DISP/dispose.sh" 2>"$DISP/drop.stderr"
[ -f "$DISP/drop.err" ] \
  && { FAIL=$((FAIL+1)); echo "  FAIL: a normal stop left its stderr capture behind" >&2; } \
  || PASS=$((PASS+1))

report "codex-session-stderr.test.sh"
