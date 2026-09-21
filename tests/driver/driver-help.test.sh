#!/usr/bin/env bash
# --help output integrity for BOTH resume-drivers (unattended-loop.sh /
# unattended-codex.sh). The drivers print their leading comment header as help.
# Regression guard for ISSUE-001/002: the header was printed via a hardcoded
# `sed -n '2,Np'` line range that drifted as the header grew/shrank — loop
# leaked source lines (`set -u`, `PROJECT=""`) past the header, and codex
# truncated its own exit-code-5 explanation mid-sentence. Help must print the
# full contiguous comment block and nothing after it, identically for both.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"   # REPO_ROOT, DRIVER (loop), asserts, report

CODEX="$REPO_ROOT/skills/loop-testing/scripts/unattended-codex.sh"

assert_absent() { # haystack needle label
  if printf '%s\n' "$1" | grep -qF -- "$2"; then
    FAIL=$((FAIL+1)); echo "  FAIL: $3 — help leaked [$2]" >&2
  else PASS=$((PASS+1)); fi
}

for d in "$DRIVER" "$CODEX"; do
  name="$(basename "$d")"
  out="$(bash "$d" --help)"

  # 1. No non-comment source line leaked past the header block.
  assert_absent "$out" 'set -u'      "$name --help stops before code (no set -u)"
  assert_absent "$out" 'PROJECT=""'  "$name --help stops before code (no PROJECT=\"\")"

  # 2. The header prints in full — last line is the final header comment (the
  #    signal exit codes, after the exit-code-5 explanation), so nothing is
  #    truncated mid-sentence.
  last="$(printf '%s\n' "$out" | tail -1)"
  assert_eq '#      outlived SIGKILL, which the message on stderr names.' "$last" "$name --help ends at the full header"

  # 3. The multi-line exit-code-5 body is present (would be cut by an under-range).
  assert_file_contains <(printf '%s\n' "$out") 'progress fingerprint' \
    "$name --help includes the full exit-5 explanation"
done

# --- an unset HOME must not kill either driver before it can say anything -----
# `SKILL_DIR="${CODEX_HOME:-$HOME/.codex}/…"` reads as guarded and is not: the
# `:-` protects the OUTER name, while `$HOME` inside the replacement text is
# expanded unguarded exactly when CODEX_HOME is unset — which is the condition
# the default exists to handle. Under `set -u` that killed the codex driver at
# line one of its configuration, before it could reach any of the teardown paths
# hardened for an unset HOME, and before --help.
#
# It is the last sibling of the two `"$HOME/…"` sites already fixed, and it was
# invisible to the sweep that found them because its `$HOME` sits mid-string
# after a `:-` rather than behind a quote. The sweep that does find this shape is
#   grep -rnE '\$\{[A-Za-z_][A-Za-z0-9_]*:[-=+?]\$' --include='*.sh'
# which returns 7 lines tree-wide, six of them the safe same-name accumulator
# idiom `${x:+$x, }`.
for pair in "loop:$DRIVER" "codex:$CODEX"; do
  name="${pair%%:*}"; path="${pair#*:}"
  out="$(env -u HOME bash "$path" --help 2>&1)"; rc=$?
  assert_rc "$rc" 0 "$name --help still works with HOME unset"
  assert_file_lacks <(printf '%s\n' "$out") "unbound variable" \
    "$name --help does not die on an unbound HOME"
done
# And the refusal, when there is genuinely nowhere to look, names the flags that
# work rather than failing later about something else.
#
# BOTH invocations below pass a --project that does not exist, deliberately. The
# driver's argument checks run in order — skill-dir guard, then `--project is
# required`, then `--project is not a directory` — so a non-existent project is
# enough to distinguish "which check fired" while guaranteeing the driver can
# never reach a session launch. An earlier version of this case passed
# `--project .`: it got past the skill-dir guard exactly as intended and then
# started a real unattended run against this repository, which is not something
# a help-output suite may do.
out="$(env -u HOME bash "$CODEX" --project /nonexistent-project-dir 2>&1)"; rc=$?
assert_rc "$rc" 2 "codex refuses (exit 2) when neither CODEX_HOME nor HOME is set"
assert_file_contains <(printf '%s\n' "$out") "--skill-dir" \
  "and the refusal names --skill-dir"
# Control: an explicit --skill-dir must NOT be refused — a guard that ignores the
# flag it recommends would be worse than the crash it replaced. Reaching the
# NEXT check is the proof that it got past this one.
out="$(env -u HOME bash "$CODEX" --skill-dir /nonexistent-skill-dir --project /nonexistent-project-dir 2>&1)"
assert_file_lacks <(printf '%s\n' "$out") "nowhere to look for the skill" \
  "an explicit --skill-dir is accepted rather than refused by the same guard"
assert_file_contains <(printf '%s\n' "$out") "not a directory" \
  "and the run stops at the next check instead, never reaching a session"

report "driver-help.test.sh"
