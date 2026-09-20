#!/usr/bin/env bash
# convergence-criteria.test.sh — the stopping rule has to be decidable.
#
# `converged_streak` and `max_rounds` are read by NO script: stop-gate and both
# drivers only check that a terminal status was written. What decides whether the
# loop stops is references/exit-and-report.md §1, read by the model — so a
# criterion that cannot be evaluated from the text is not a soft spot, it is the
# whole gate.
#
# Locked here (audit K-06, K-07, and the K-21/K-22 copies they run through):
#   - criterion 3 names every parking state the issue state machine defines, and
#     says what FIXED_UNVERIFIED is (an unfinished replay, not a resolution);
#   - criterion 7 carries a NUMBER and names which file's field it is read from,
#     instead of "明显低于此前轮次";
#   - a shrunk-coverage round ZEROES the streak rather than merely "not counting",
#     which let A-converged / B-shrunk / C-converged reach streak=2 on two
#     non-consecutive rounds;
#   - the STATE.md template does not carry a second, shorter zero-list that
#     silently disagrees with §1 — the template is what the model instantiates.
#
# WHAT THESE ASSERTIONS ARE. An independent pre-ship reviewer showed the first
# version of this suite green against four separate reverts of the rule it claims
# to hold — including restoring the previous-round baseline and turning 归零 back
# into 不计入, the two defects the change existed to fix. They passed because the
# assertions matched the rule's VOCABULARY (`80%`, `cases_this_round`,
# `runs/round-N.md`) and every revert kept that vocabulary intact.
#
# So each assertion below names a DISCRIMINATING phrase: one that a correct
# statement of the rule must contain and the known-wrong statements do not, plus
# `hasnt` for the wrong forms themselves. That is the most a text predicate over
# a prompt document can do — it cannot tell that a rewording in different words
# still means the rule. Rewriting §1 SHOULD fail this suite: re-derive the
# assertions against the new text, and mutation-check them the way this header
# was earned.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXITDOC="$REPO_ROOT/skills/loop-testing/references/exit-and-report.md"
RULES="$REPO_ROOT/skills/loop-testing/references/issue-rules.md"
STATE_TPL="$REPO_ROOT/skills/loop-testing/templates/STATE.md"
FM_TPL="$REPO_ROOT/skills/loop-testing/templates/FEATURE_MATRIX.md"

_fails=0
_pass=0
_failn=0
_name="${0##*/}"
pass() { printf '  ok: %s\n' "$1"; _pass=$((_pass + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; _fails=1; _failn=$((_failn + 1)); }
# whitespace-flattened substring match: markdown wraps phrases across lines.
has()  { if tr '[:space:]' ' ' < "$1" | tr -s ' ' | grep -qF -- "$2"; then pass "$3"; else fail "$3 (missing '$2' in ${1##*/})"; fi; }
hasnt(){ if tr '[:space:]' ' ' < "$1" | tr -s ' ' | grep -qF -- "$2"; then fail "$3 (unexpected '$2' in ${1##*/})"; else pass "$3"; fi; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-conv.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# §1 only: every other section of the file mentions these states for other
# reasons, so asserting over the whole file would pass on the wrong sentence.
S1="$TMP/s1.md"
awk '/^## 1\./{f=1;next} /^## 2\./{f=0} f' "$EXITDOC" > "$S1"
[ -s "$S1" ] && pass "exit-and-report.md §1 (单轮判据) is extractable" \
              || fail "exit-and-report.md §1 could not be extracted — the section heading moved"

ZERO="$TMP/zero.txt"
grep -F 'converged_streak = 0' "$S1" > "$ZERO" || true
[ -s "$ZERO" ] && pass "§1 states a zero-the-streak rule" \
                || fail "§1 no longer says when converged_streak is zeroed"

# --- K-07: criterion 3 must accept every parking state the machine defines ----
# issue-rules.md §7 mandates CANNOT_REPRODUCE for anything that will not
# reproduce; a criterion that omits it makes such an issue block convergence
# forever, with the two documents ordering opposite things.
for st in NEEDS_CONFIRMATION BLOCKED WONT_FIX CANNOT_REPRODUCE; do
  has "$S1" "$st" "criterion 3 accepts $st (parity with issue-rules.md §7)"
  has "$RULES" "$st" "issue-rules.md §7 still defines $st"
done

# FIXED_UNVERIFIED is the other half: it must be named and refused, or the model
# has to guess whether "fixed but not replayed" counts as resolved.
has "$S1" "FIXED_UNVERIFIED" "criterion 3 says what FIXED_UNVERIFIED means for convergence"
# NOT a bare `has VERIFIED`: that is satisfied by the string FIXED_UNVERIFIED
# itself, so it stayed green with the whole exit route deleted. Name the route.
has "$S1" "写进 \`runs/round-N.md\`" "criterion 3's exit route says WHERE the replay evidence goes"
has "$S1" "再标 \`VERIFIED\`" "criterion 3's exit route says the replay comes BEFORE the VERIFIED mark"

# --- K-06 part 1: shrunk coverage must ZERO the streak, not merely not count --
has "$ZERO" "缩水" "a shrunk-coverage round is in the zero-the-streak list (K-06)"
# The A/B/C hole is reopened by changing exactly one word in criterion 7 while
# leaving the zero-line intact, which the first version of this suite allowed.
has  "$S1" "converged_streak\` 归零" "criterion 7 itself says the streak is ZEROED (K-06)"
hasnt "$S1" "不计入连续计数" "the 'does not count' phrasing that left A/B/C reachable is gone"

# --- K-06 part 2 + K-21: a number, and one named source for it ---------------
has "$S1" "80%" "criterion 7 states a numeric threshold, not '明显低于'"
has "$S1" "cases_this_round" "criterion 7 names the field it compares"
has "$S1" "runs/round-N.md" "criterion 7 names WHICH file's cases_this_round is authoritative (K-21)"
# `80%` alone is vocabulary: it survives a revert to the previous-round baseline,
# which is the defect that lets two shrinking rounds walk the floor down.
has  "$S1" "此前所有轮次最大值" "the baseline is the maximum over ALL prior rounds (K-06)"
has  "$S1" "不是上一轮" "criterion 7 says out loud that the previous round alone is not the baseline"
hasnt "$S1" "上一轮的 80%" "the previous-round baseline is not what the rule settles on"
# The escape must stay the one bounded, documented exception it was written as.
has  "$S1" "唯一例外" "the shrink escape is singular and named, not a general discretion"
hasnt "$S1" "豁免" "no blanket self-exemption clause was added to criterion 7"
hasnt "$S1" "明显低于此前轮次" "the unfalsifiable phrasing is gone"

# The other copy of the field must defer to that one rather than compete.
has "$FM_TPL" "runs/round-N.md" "FEATURE_MATRIX.md template defers to the round log for cases_this_round (K-21)"

# The round log is where criterion 7 reads from and where its one exception is
# written, so the template must carry both or the rule has no slot to land in.
ROUND_TPL="$REPO_ROOT/skills/loop-testing/templates/round-N.md"
has "$ROUND_TPL" "cases_this_round" "round-N.md template carries the field criterion 7 reads"
has "$ROUND_TPL" "80%" "round-N.md template states the threshold at the point of entry"
has "$ROUND_TPL" "覆盖缩减说明" "round-N.md template has a slot for the one documented exception"

# --- K-22: the template must not carry a second, shorter zero-list -----------
has "$STATE_TPL" "exit-and-report.md" "STATE.md template points at the authoritative zero-list (K-22)"
has "$STATE_TPL" "缩水" "STATE.md template's zero-list carries the shrunk-round trigger too (K-22)"

finish() {
  printf '%s: %d passed, %d failed\n' "$_name" "$_pass" "$_failn"
  [ "$_fails" -eq 0 ]
}
finish
