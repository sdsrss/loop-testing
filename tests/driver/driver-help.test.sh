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

  # 2. The header prints in full — last line is the final header comment, so the
  #    exit-code-5 explanation is complete, not truncated mid-sentence.
  last="$(printf '%s\n' "$out" | tail -1)"
  assert_eq '#      round-0 bootstrap bytes).' "$last" "$name --help ends at the full header"

  # 3. The multi-line exit-code-5 body is present (would be cut by an under-range).
  assert_file_contains <(printf '%s\n' "$out") 'progress fingerprint' \
    "$name --help includes the full exit-5 explanation"
done

report "driver-help.test.sh"
