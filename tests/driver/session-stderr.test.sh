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
# So the capture is now a PLAIN FILE REDIRECT, `2>"$file"`, into a FRESH file per
# session. There is no writer process, no .part, no rename and nothing to wait
# for — cases D2 and D3 are the two halves of that CRITICAL. The per-session file
# is case K: reusing one file and leaning on the redirect's O_TRUNC passed every
# other case here, because O_TRUNC resets SIZE and not the OFFSET of an
# already-open fd.
#
# Cases I and J are the redaction corpus. Read the note on case I before adding
# to it: two separate versions of these assertions have been green against the
# very rule they named.
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
# A CANARY, not a discriminator, and it is labelled as one because it has been
# mistaken for coverage twice in review. No mutation of this driver can fail it
# — it passes with the feature deleted entirely — and it cannot establish WHAT
# replaced the device node if it ever does fail. It is here because the pulled
# design did replace it, and because the check is one stat.
[ -c /dev/null ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: /dev/null is not a character device on this host — something replaced it; this canary cannot say what" >&2; }

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
FP=$(printf 'monkey: eating_all_the_bananas\nmonkeypatch: applied_to_module_alpha\nkeyboard: /dev/input/by-id/usb-kbd-event\ntoken: expected %s;%s at line 42\nmodule not found: ./src/keys.js\nsecretary: Jane Smith Esquire III\n' "'" "'")
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
# 'secret' has no start boundary (that is what closes the camelCase leaks), so
# the END boundary is the only thing between 'secretary:' and a redaction.
assert_file_contains "$WS10/$LOG" "secretary: Jane Smith Esquire III"  "'secretary' is not a secret (end boundary carries it alone)"

# I2. LEXER AND PARSER VOCABULARY — the collision class that matters, and the one
#     two rounds of these assertions missed by testing English instead. This
#     feature exists to carry a failing agent's diagnostics, and a failing agent
#     prints parser errors. Both halves of the case test are pinned here:
#     lowercase glued names (a hand-written lexer's locals) must not match the
#     camelCase rule, and UpperCamelCase names (real shipped class names —
#     SyntaxToken, LexToken, HTMLToken, CommentToken) must not match it either.
#     An [A-Za-z] prefix on that rule redacts all four of the latter; that was
#     the reviewer's own recommendation and it failed on its own list.
WS13=$(mk_proj); CLEAN="$CLEAN $WS13"
stub=$(write_stub "$WS13"); write_state "$WS13" RUNNING 0
LX=$(printf 'betoken: something_long_here\nnexttoken: IDENTIFIER_FOO\npeektoken: RBRACE_EXPECTED\nSyntaxToken: unexpected_end_of_input\nLexToken: NUMBER_LITERAL_42\nHTMLToken: unexpected end of input\n')
STUB_STDERR="$LX" STUB_EXIT=1 \
  bash "$DRIVER" --project "$WS13" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_file_contains "$WS13/$LOG" "betoken: something_long_here"    "'betoken' is English, not a token name"
assert_file_contains "$WS13/$LOG" "nexttoken: IDENTIFIER_FOO"       "a lexer's lowercase 'nexttoken' is not a credential"
assert_file_contains "$WS13/$LOG" "peektoken: RBRACE_EXPECTED"      "nor is 'peektoken'"
assert_file_contains "$WS13/$LOG" "SyntaxToken: unexpected_end_of_input" "a PascalCase class name is not a credential"
assert_file_contains "$WS13/$LOG" "LexToken: NUMBER_LITERAL_42"     "nor is LexToken, whose value even carries digits"
assert_file_contains "$WS13/$LOG" "HTMLToken: unexpected end of input" "nor HTMLToken, a real shipped class name"

# I3. THE LEXER API, which is where the first version of the camelCase rule did
#     its damage. It keyed on the case of the first letter — lowercase meant a
#     credential field, uppercase a type name — and that is not true in either
#     direction: accessToken and nextToken are both lowerCamelCase, AccessToken
#     and SyntaxToken are both PascalCase. These are the names it redacted.
WS16=$(mk_proj); CLEAN="$CLEAN $WS16"
stub=$(write_stub "$WS16"); write_state "$WS16" RUNNING 0
API=$(printf 'nextToken: IDENTIFIER_FOO_X\npeekToken: RBRACE_EXPECTED\nreadToken: unexpected_char_here\nexpectToken: PUNCTUATION_SEMI\nconsumeToken: END_OF_STREAM\n')
STUB_STDERR="$API" STUB_EXIT=1 \
  bash "$DRIVER" --project "$WS16" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
for n in "nextToken: IDENTIFIER_FOO_X" "peekToken: RBRACE_EXPECTED" "readToken: unexpected_char_here" \
         "expectToken: PUNCTUATION_SEMI" "consumeToken: END_OF_STREAM"; do
  assert_file_contains "$WS16/$LOG" "$n" "lexer API name survives: ${n%%:*}"
done

# I4. …and the other direction, which is a LEAK rather than a diagnostics loss.
#     PascalCase is .NET appsettings.json convention, and Go's %+v on
#     oauth2.Config / oauth2.Token prints exported — hence capitalised — fields.
#     The name rule wants a separator before the secret word, so all of these
#     passed straight through until the prefix was enumerated.
WS17=$(mk_proj); CLEAN="$CLEAN $WS17"
stub=$(write_stub "$WS17"); write_state "$WS17" RUNNING 0
PC=$(printf 'config AccessToken=aaaaaaaaaa1111111111 rejected\nconfig ClientSecret=bbbbbbbbbb2222222222 rejected\nconfig UserPassword=cccccccccc3333333333 rejected\ndump oauth2.Config{ClientID:abc ClientSecret:dddddddddd4444444444 Scopes:[]}\ndump &Token{AccessToken:eeeeeeeeee5555555555 TokenType:Bearer}\n')
STUB_STDERR="$PC" STUB_EXIT=1 \
  bash "$DRIVER" --project "$WS17" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_file_lacks    "$WS17/$LOG" "aaaaaaaaaa1111111111" "PascalCase AccessToken is masked (.NET appsettings convention)"
assert_file_lacks    "$WS17/$LOG" "bbbbbbbbbb2222222222" "PascalCase ClientSecret is masked"
assert_file_lacks    "$WS17/$LOG" "cccccccccc3333333333" "PascalCase UserPassword is masked"
assert_file_lacks    "$WS17/$LOG" "dddddddddd4444444444" "a Go %+v oauth2.Config dump is masked"
assert_file_lacks    "$WS17/$LOG" "eeeeeeeeee5555555555" "a Go %+v oauth2.Token dump is masked"
assert_file_contains "$WS17/$LOG" "TokenType:Bearer"     "and the struct's other fields survive"

# J. redaction true positives, in the shapes a failing endpoint actually prints.
#    Each line keeps a word of diagnostic around the secret, so the assertions
#    below cannot pass by the whole line having been dropped.
WS11=$(mk_proj); CLEAN="$CLEAN $WS11"
stub=$(write_stub "$WS11"); write_state "$WS11" RUNNING 0
TP=$(printf 'call failed X-Api-Key: deadbeefdeadbeefdeadbeef\nheader Authorization: Basic dXNlcjpwYXNzd29yZA==\nfetch https://ci-bot:glpat-SECRETVALUE123@git.example.com/r failed\nenv AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY rejected\nconfig apikey=zyxwvu9876543210 refused\nbody {"accessToken": "aaaaaaaaaa1111111111"} denied\nbody {"clientSecret": "bbbbbbbbbb2222222222"} denied\nenv dbPassword=cccccccccc3333333333 denied\n')
STUB_STDERR="$TP" STUB_EXIT=1 \
  bash "$DRIVER" --project "$WS11" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_file_lacks    "$WS11/$LOG" "deadbeefdeadbeefdeadbeef"        "X-Api-Key's value is masked (boundary is '-', not a letter)"
assert_file_contains "$WS11/$LOG" "call failed"                     "and the line around it survives"
assert_file_lacks    "$WS11/$LOG" "dXNlcjpwYXNzd29yZA=="            "Authorization: takes the rest of the line, not just the scheme word"
assert_file_lacks    "$WS11/$LOG" "glpat-SECRETVALUE123"            "URL userinfo is masked"
assert_file_contains "$WS11/$LOG" "git.example.com"                 "and the host it was failing against survives"
assert_file_lacks    "$WS11/$LOG" "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" "AWS_SECRET_ACCESS_KEY's value is masked"
assert_file_contains "$WS11/$LOG" "rejected"                        "and the verdict after it survives"
# The glued compounds are listed, not inferred: 'apikey' has no separator before
# 'key', so the start-boundary rule would drop it without the explicit prefix.
assert_file_lacks    "$WS11/$LOG" "zyxwvu9876543210"                "a glued 'apikey=' is still masked (listed prefix)"
assert_file_contains "$WS11/$LOG" "refused"                         "and the verdict after that one survives too"
# camelCase Token/Secret/Password. Review found twelve of these leaking because
# the start boundary required a separator before the word and only 'key' had a
# glued-name list. These three stand for the class; the rule that covers them
# covers slackToken and npmToken too, which no list would have.
assert_file_lacks    "$WS11/$LOG" "aaaaaaaaaa1111111111"            "camelCase accessToken is masked (no start boundary on token)"
assert_file_lacks    "$WS11/$LOG" "bbbbbbbbbb2222222222"            "camelCase clientSecret is masked"
assert_file_lacks    "$WS11/$LOG" "cccccccccc3333333333"            "camelCase dbPassword is masked"
assert_file_contains "$WS11/$LOG" "denied"                          "and the verdicts after those survive"

# J2. THE QUOTED Authorization HEADER — review's CRITICAL. Every JSON, Python-dict
#     and Ruby-hash rendering puts a quote between the name and the colon, which
#     the bare rule's literal ':' cannot match, and the base64 of a short
#     credential pair is under the 32-character fallback. `base64 -d` on the
#     value below gives ci-bot:supersecret. The Bearer form was always caught by
#     its own rule, which is what made this easy to miss.
#     The second assertion is the other half: stopping at the closing quote
#     rather than running to end of line, so the rest of the JSON survives.
WS14=$(mk_proj); CLEAN="$CLEAN $WS14"
stub=$(write_stub "$WS14"); write_state "$WS14" RUNNING 0
STUB_STDERR='{"status":429,"headers":{"authorization":"Basic Y2ktYm90OnN1cGVyc2VjcmV0"},"retry_after":30}' STUB_EXIT=1 \
  bash "$DRIVER" --project "$WS14" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_file_lacks    "$WS14/$LOG" "Y2ktYm90OnN1cGVyc2VjcmV0" "a quoted JSON authorization header is masked (review CRITICAL)"
assert_file_contains "$WS14/$LOG" "retry_after"              "and the rest of the JSON after it survives"

# J3. the three other quoted renderings review found still leaking afterwards.
#     Each carries the same base64 — 24 characters, under the fallback — so each
#     assertion fails on its own if its rendering stops matching.
WS18=$(mk_proj); CLEAN="$CLEAN $WS18"
stub=$(write_stub "$WS18"); write_state "$WS18" RUNNING 0
AU=$(printf 'ruby "authorization" => "Basic UlVCWVJVQllSVUJZUlVCWVJV" here\nnode {"x-authorization": "Basic WFhYWFhYWFhYWFhYWFhYWFhYWFg="} here\nnode {"proxy-authorization": "Basic UFJPWFlQUk9YWVBST1hZUFJP"} here\n')
STUB_STDERR="$AU" STUB_EXIT=1 \
  bash "$DRIVER" --project "$WS18" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
assert_file_lacks "$WS18/$LOG" "UlVCWVJVQllSVUJZUlVCWVJV" "a Ruby hashrocket authorization is masked"
assert_file_lacks "$WS18/$LOG" "WFhYWFhYWFhYWFhYWFhYWFhYWFg=" "a quoted x-authorization header is masked"
assert_file_lacks "$WS18/$LOG" "UFJPWFlQUk9YWVBST1hZUFJP" "a quoted proxy-authorization header is masked"

# K. ONE FILE PER SESSION, tested as a property rather than as a flag. Reusing a
#    single file and letting the redirect's O_TRUNC reset it passes every other
#    case in this suite — reverting to a shared file left all 30 green, which is
#    how this defect reached review. O_TRUNC resets the file's SIZE, not the
#    OFFSET of an already-open file description: a grandchild that inherited fd 2
#    from session 1 keeps writing at its old offset, so its output is filed under
#    session 2 and, once that offset passes the 4000-byte window, session 2's own
#    error is pushed out of the log altogether. That is the D-05 symptom produced
#    by the D-05 fix, so it is asserted from both sides.
WS12=$(mk_proj); CLEAN="$CLEAN $WS12"
stub=$(write_stub "$WS12"); write_state "$WS12" RUNNING 0
STUB_GRANDCHILD=1 \
  bash "$DRIVER" --project "$WS12" --claude-bin "$stub" --max-sessions 2 >/dev/null 2>&1
assert_file_contains "$WS12/$LOG" "THE REAL ERROR OF SESSION 2 WAS AN EXPIRED KEY" \
  "session 2's own stderr survives a session-1 grandchild holding fd 2"
assert_file_lacks    "$WS12/$LOG" "LATE WRITE FROM SESSION ONE GRANDCHILD" \
  "and session 1's late write is not filed under session 2"
# Self-probe. Both assertions above pass if the grandchild never wrote at all, so
# without this the case can become a permanent no-op the day the timing shifts.
[ -f "$WS12/gc-done" ] && PASS=$((PASS+1)) \
  || { FAIL=$((FAIL+1)); echo "  FAIL: the grandchild never wrote — case K proved nothing (self-probe)" >&2; }

# L. THE BYTE CAP AMPUTATES LABELS. `tail -c` cuts on a byte boundary BEFORE
#    redaction runs, so a credential straddling 4000 bytes loses its `"api_key":"`
#    label and reaches the rules as a bare alphanumeric run — under the 32-char
#    fallback, with nothing to identify it. Review reproduced 18 of a 31-character
#    secret reaching driver.log verbatim, with the filler after it masked so the
#    line read as redacted. No rule fixes this; the partial first line is dropped
#    instead. One 4091-byte line is the whole trigger.
WS15=$(mk_proj); CLEAN="$CLEAN $WS15"
stub=$(write_stub "$WS15"); write_state "$WS15" RUNNING 0
STUB_STDERR_LONGLINE=1 STUB_EXIT=1 \
  bash "$DRIVER" --project "$WS15" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
# chars 14..31 of the canary — what the amputated cut published last time.
assert_file_lacks    "$WS15/$LOG" "6543210ABCDEFGHIJK" "a credential straddling the byte cap is not published as a fragment"
# NOT `lacks LEAKCANARY`: the canary's first 13 characters sit BEFORE the cut and
# were never at risk, so that assertion could not fail while the bug was present.
# ENDOFLONGLINE is at the far end of the same line, which a drop-the-LAST-line or
# drop-N-bytes variant would publish — so this one moves under a real mutation.
assert_file_lacks    "$WS15/$LOG" "ENDOFLONGLINE"      "and no other part of the over-long line is published either"
assert_file_contains "$WS15/$LOG" "nothing shown"      "and the log says why it is empty rather than looking broken"

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
  bash "$DRIVER" --project "$WS19" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
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
  bash "$DRIVER" --project "$WS20" --claude-bin "$stub" --max-sessions 1 >/dev/null 2>&1
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
DISP=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-disp.XXXXXX"); CLEAN="$CLEAN $DISP"
{ echo '#!/usr/bin/env bash'
  echo 'set -u'
  echo 'CHILD_SURVIVED="${CHILD_SURVIVED:-}"; SESSION_ERR="${SESSION_ERR:-}"'
  awk '/^session_err_dispose\(\) \{/,/^\}/' "$REPO_ROOT/skills/loop-testing/scripts/unattended-loop.sh"
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

report "session-stderr.test.sh"
