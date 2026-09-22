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

# --- §7 must say WHICH states can reach those four ----------------------------
# Naming the four is not enough, and the loop above is satisfied by a document
# that names them and says nothing about how an issue gets there. §7 used to be
# an arrow diagram with `↓` hanging under FIXED_UNVERIFIED, which reads as "only
# an issue somebody worked on can be parked" — while criterion 3 requires EVERY
# P0-P2 that is not VERIFIED at round end to land in one of the four, an issue
# still at OPEN included. Under that reading the two documents order opposite
# things and criterion 3 is unsatisfiable for an untouched P1.
#
# The transition table can state the sources and the diagram could not, so these
# are the discriminating phrases: a revert to the diagram loses exactly them.
has "$RULES" "不在表内的迁移不存在" "§7 states its own closure (a table, not a sketch)"
has "$RULES" "\`OPEN\` · \`FIXING\` · \`FIXED_UNVERIFIED\`" \
  "§7 names OPEN and FIXING as sources of the parking transition, not just FIXED_UNVERIFIED"
hasnt "$RULES" "OPEN → FIXING → FIXED_UNVERIFIED → VERIFIED" \
  "the arrow diagram that could not express that source set is gone"
# The other end: VERIFIED is terminal and a regression opens a new entry. Without
# this the table would be read as licensing an edit back to OPEN, which hides the
# regression that criterion 1's zero-list is supposed to catch.
has "$RULES" "另立新条" "§7 says a later regression opens a NEW entry instead of reopening VERIFIED"

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
has  "$S1" "此前最近 3 轮" "the baseline is bounded: the max over the last 3 rounds (K-06)"
has  "$S1" "不是上一轮" "criterion 7 rules out the previous round alone (a two-round walk-down)"
has  "$S1" "也不是全部历史" "criterion 7 rules out all-history too (one huge round -> false INCOMPLETE)"
hasnt "$S1" "上一轮的 80%" "the previous-round baseline is not what the rule settles on"
# A criterion that cannot be evaluated at round 1, or against a log that will not
# parse, is decided by the model — which is what K-06 set out to stop.
has  "$S1" "第 1 轮没有此前轮次" "criterion 7 has a base case (round 0 writes no runs/round-N.md)"
has  "$S1" "按缩水轮处理" "an unreadable prior cases_this_round costs the round, rather than lowering the bar"
# The unit has to exist or the ratio compares nothing to nothing.
has  "$S1" "一个用例 = \`FEATURE_MATRIX.md\`" "criterion 7 defines what one case IS"
# The escape must stay the one bounded exception it was written as, and must be
# settled by arithmetic rather than by the model judging its own prose.
has  "$S1" "唯一例外" "the shrink escape is singular and named, not a general discretion"
has  "$S1" "扣除后的可比基数 B" "the exception names the adjusted baseline as a number"
has  "$S1" "B × 80%" "the exception is settled by an inequality, not by whether it reads convincingly"
hasnt "$S1" "豁免" "no blanket self-exemption clause was added to criterion 7"
# The zero-trigger must key on criterion 7 as a whole: keying on the 80% clause
# alone let a round skip the full regression entirely and keep its streak.
has  "$ZERO" "判据 7 未满足" "the zero-trigger fires on ALL of criterion 7, not just the ratio"

# loop-round.md is the only per-round instruction telling the model what to
# compare a case count against. It said 对比上轮 — the baseline §1 now rules out —
# one bullet above the line that defers to §1 for the streak. Two prompt files
# giving opposite orders is what K-02 was.
LOOP_ROUND="$REPO_ROOT/skills/loop-testing/references/loop-round.md"
has  "$LOOP_ROUND" "此前最近 3 轮" "loop-round.md's progress line names the same baseline as criterion 7"
hasnt "$LOOP_ROUND" "对比上轮" "loop-round.md no longer orders the comparison criterion 7 rules out"
# Criterion 7 binds on EVERY round, so a focused round after a converged one
# zeroes the streak by construction. Nothing told the model that, and a rule
# whose cost is only discovered by paying it is not a rule the model can follow.
has "$LOOP_ROUND" "converged_streak ≥ 1" "loop-round.md says when every round must be a full regression"
hasnt "$S1" "明显低于此前轮次" "the unfalsifiable phrasing is gone"

# The other copy of the field must defer to that one rather than compete.
has "$FM_TPL" "runs/round-N.md" "FEATURE_MATRIX.md template defers to the round log for cases_this_round (K-21)"
has "$FM_TPL" "此前最近 3 轮" "FEATURE_MATRIX.md template carries the same baseline as criterion 7"

# The round log is where criterion 7 reads from and where its one exception is
# written, so the template must carry both or the rule has no slot to land in.
ROUND_TPL="$REPO_ROOT/skills/loop-testing/templates/round-N.md"
has "$ROUND_TPL" "cases_this_round" "round-N.md template carries the field criterion 7 reads"
has "$ROUND_TPL" "80%" "round-N.md template states the threshold at the point of entry"
has "$ROUND_TPL" "此前最近 3 轮" "round-N.md template carries the same baseline as criterion 7"
has "$ROUND_TPL" "B × 80%" "round-N.md's exception slot demands the inequality, not just a reason"
has "$ROUND_TPL" "覆盖缩减说明" "round-N.md template has a slot for the one documented exception"

# --- K-22: the template must not carry a second, shorter zero-list -----------
has "$STATE_TPL" "exit-and-report.md" "STATE.md template points at the authoritative zero-list (K-22)"
has "$STATE_TPL" "缩水" "STATE.md template's zero-list carries the shrunk-round trigger too (K-22)"
has "$STATE_TPL" "此前最近 3 轮" "STATE.md template's copy of the trigger carries the same baseline (K-22)"

finish() {
  printf '%s: %d passed, %d failed\n' "$_name" "$_pass" "$_failn"
  [ "$_fails" -eq 0 ]
}
finish
