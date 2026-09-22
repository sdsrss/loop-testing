#!/usr/bin/env bash
# script-help.test.sh — the two hand-run sandbox scripts must answer --help.
#
# The gap this locks: every other entry point in the repo answers --help/-h
# (install-codex.sh, unattended-loop.sh, unattended-codex.sh, moa.mjs), but
# sandbox-setup.sh and sandbox-clean.sh replied "unknown argument: --help" and
# exited 2. These are the two scripts the README tells a USER to run by hand —
# including `sandbox-clean.sh --purge`, which deletes branches and directories —
# so "what are my options?" answering with an error is the worst place for it.
#
# --help must also be INERT: printing usage must never create a sandbox or remove
# anything, so it has to be handled before the scripts touch the filesystem.
set -u

. "$(dirname "$0")/lib.sh"

WS=$(mk_ws)
trap 'rm -rf "$WS"' EXIT
PROJ="$WS/proj"

for flag in --help -h; do
  for pair in "SETUP:$SETUP:sandbox-setup" "CLEAN:$CLEAN:sandbox-clean"; do
    rest="${pair#*:}"; script="${rest%:*}"; label="${rest##*:}"
    out=$( cd "$PROJ" && bash "$script" "$flag" 2>&1 ); rc=$?
    assert_eq 0 "$rc" "$label $flag exits 0"
    printf '%s' "$out" | grep -qF 'Usage:' \
      && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: $label $flag must print a Usage: line" >&2; }
    printf '%s' "$out" | grep -qF 'Exit codes:' \
      && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: $label $flag must print its exit codes" >&2; }
    if printf '%s' "$out" | grep -qF 'unknown argument'; then
      FAIL=$((FAIL+1)); echo "  FAIL: $label $flag must not be treated as an unknown argument" >&2
    else PASS=$((PASS+1)); fi
    # the help text must not still be commented out
    if printf '%s' "$out" | grep -qE '^#'; then
      FAIL=$((FAIL+1)); echo "  FAIL: $label $flag leaks raw '#' comment markers" >&2
    else PASS=$((PASS+1)); fi
  done
done

# each script's own flags have to appear in its help
out=$( cd "$PROJ" && bash "$SETUP" --help 2>&1 )
for f in --mode --worktree-path --branch --baseline-tag --allow-dirty; do
  printf '%s' "$out" | grep -qF -- "$f" \
    && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: sandbox-setup help omits $f" >&2; }
done
out=$( cd "$PROJ" && bash "$CLEAN" --help 2>&1 )
for f in --purge --discard-fixes; do
  printf '%s' "$out" | grep -qF -- "$f" \
    && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: sandbox-clean help omits $f" >&2; }
done

# --help is inert: no sandbox built, nothing removed
assert_absent "$PROJ/docs/looptesting" "--help does not create the evidence dir"
assert_absent "$WS/proj-qa-loop" "--help does not create a worktree"

# a genuinely unknown flag must STILL be a usage error (exit 2), not help
out=$( cd "$PROJ" && bash "$SETUP" --not-a-flag 2>&1 ); rc=$?
assert_eq 2 "$rc" "sandbox-setup still rejects an unknown flag with exit 2"
out=$( cd "$PROJ" && bash "$CLEAN" --not-a-flag 2>&1 ); rc=$?
assert_eq 2 "$rc" "sandbox-clean still rejects an unknown flag with exit 2"

# --help wins even when combined with a destructive flag, and stays inert
( cd "$PROJ" && bash "$SETUP" ) >/dev/null 2>&1
sed -i.bak 's/^status: .*/status: CONVERGED/' "$PROJ/docs/looptesting/STATE.md"; rm -f "$PROJ/docs/looptesting/STATE.md.bak"
out=$( cd "$PROJ" && bash "$CLEAN" --purge --help 2>&1 ); rc=$?
assert_eq 0 "$rc" "sandbox-clean --purge --help exits 0 (help, not a purge)"
assert_exists "$PROJ/docs/looptesting" "--purge --help purged nothing"
git -C "$PROJ" rev-parse -q --verify refs/tags/qa-baseline >/dev/null 2>&1 \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: --purge --help must not delete the baseline tag" >&2; }

report "script-help.test.sh"
