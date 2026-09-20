#!/usr/bin/env bash
# resume-protocol.test.sh — "restart resumes" has to be decidable from the files.
#
# The product's central promise is that a crash is recoverable: state lives in
# docs/looptesting/, and re-triggering the skill continues from it. No script
# implements that — stop-gate and both drivers only check whether a TERMINAL
# status was written. What decides what happens after a crash is the prompt text
# in references/round-0.md §0, read by the model. So a crash-adjacent situation
# the text does not name is not a soft spot, it is the whole recovery path.
#
# Locked here (audit K-09, K-10, K-11, and the K-03 read-only-mode interaction):
#   - a TERMINAL status re-triggered with empty $ARGUMENTS does not open a new
#     round (the drivers exit 0 there; the skill has to agree, or rounds keep
#     climbing past a delivered report);
#   - FINAL_REPORT.md present while status is RUNNING is the interrupted exit
#     sequence (step 1 done, step 2 not), and is resolved by COMPLETENESS, not
#     by a blanket rule in either direction;
#   - a runs/round-N.md numbered above STATE.md's round: is an interrupted round
#     — redone, and not credited to converged_streak;
#   - .active is re-armed on the resume path, which never reaches round-0 §7
#     where the sentinel is normally created;
#   - `status` and `report` are read-only modes that the Stop hook cannot see, so
#     the skill says what to do when the gate blocks them instead of leaving the
#     model to satisfy the gate by starting a run.
#
# WHAT THESE ASSERTIONS ARE. Same contract as convergence-criteria.test.sh: a
# text predicate over a prompt document cannot tell that a rewording still means
# the rule, so each assertion names a DISCRIMINATING phrase — one a correct
# statement of the rule must contain and the known-wrong statements do not —
# plus `hasnt` for the wrong forms themselves. Every assertion below was run
# against the pre-fix text and failed there. Rewriting §0 SHOULD fail this
# suite: re-derive the assertions against the new text and mutation-check them.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROUND0="$REPO_ROOT/skills/loop-testing/references/round-0.md"
SKILL="$REPO_ROOT/skills/loop-testing/SKILL.md"
EXITDOC="$REPO_ROOT/skills/loop-testing/references/exit-and-report.md"
GATE="$REPO_ROOT/hooks/stop-gate.sh"

_fails=0
_pass=0
_failn=0
_name="${0##*/}"
pass() { printf '  ok: %s\n' "$1"; _pass=$((_pass + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; _fails=1; _failn=$((_failn + 1)); }
# whitespace-flattened substring match: markdown wraps phrases across lines.
has()  { if tr '[:space:]' ' ' < "$1" | tr -s ' ' | grep -qF -- "$2"; then pass "$3"; else fail "$3 (missing '$2' in ${1##*/})"; fi; }
hasnt(){ if tr '[:space:]' ' ' < "$1" | tr -s ' ' | grep -qF -- "$2"; then fail "$3 (unexpected '$2' in ${1##*/})"; else pass "$3"; fi; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-resume.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# §0 only. Every other section of round-0.md mentions STATE.md, .active and the
# round log for other reasons, so asserting over the whole file would pass on
# the wrong sentence — §7 in particular already tells the model to arm .active
# when it builds the sandbox, which is the path a resume never takes.
S0="$TMP/s0.md"
awk '/^## 0\./{f=1;next} /^## 1\./{f=0} f' "$ROUND0" > "$S0"
[ -s "$S0" ] && pass "round-0.md §0 (续跑检测) is extractable" \
              || fail "round-0.md §0 could not be extracted — the section heading moved"

# The entry triage is the only part of SKILL.md a read-only mode reads; the rest
# of the file describes the loop it is forbidden to start.
TRIAGE="$TMP/triage.md"
awk '/^## 入口与参数分诊/{f=1;next} /^## 双重身份/{f=0} f' "$SKILL" > "$TRIAGE"
[ -s "$TRIAGE" ] && pass "SKILL.md 入口与参数分诊 is extractable" \
                 || fail "SKILL.md triage section could not be extracted — the heading moved"

# --- K-11 part 1: a terminal status re-triggered must not open a new round ----
# The drivers exit 0 on a terminal status. If the skill instead resumes, a
# project that already delivered FINAL_REPORT.md grows new rounds on top of it,
# and the round count in the delivered report stops being true.
has "$S0" "不开新一轮" "§0 refuses a new round on a terminal status (K-11)"
has "$S0" "CONVERGED\` / \`INCOMPLETE\` / \`BLOCKED" "§0 names which statuses are terminal, rather than 'non-RUNNING'"
has "$S0" "驱动读到终态即 exit 0" "§0 says WHY: the skill and the unattended drivers must agree"
has "$S0" "归档" "§0 names the way to deliberately start over (archive the evidence dir)"
# The same branch has to exist at the entry point, or the model reaches round-0
# only after deciding to resume — the decision this rule exists to change.
has "$TRIAGE" "不开新一轮" "SKILL.md's empty-argument branch carries the terminal-status rule too (K-11)"

# --- K-09: FINAL_REPORT.md present while RUNNING ------------------------------
# Resolved by completeness. A blanket "delete and continue" throws away a
# finished report; a blanket "it is done" ships a half-written one as final.
has "$S0" "FINAL_REPORT.md\` 已存在而" "§0 names the interrupted-exit-sequence situation (K-09)"
has "$S0" "第 1 步与第 2 步之间" "§0 locates it in the exit sequence rather than describing it vaguely"
has "$S0" "十节齐备" "§0's branch tests the report for completeness"
has "$S0" "converged_streak\` 已达 2" "§0's branch also tests that the stop condition actually held"
has "$S0" "第 2 步接着做" "§0 says a COMPLETE report resumes the exit sequence"
has "$S0" "删除 \`FINAL_REPORT.md\`" "§0 says an INCOMPLETE one is deleted, not kept"
hasnt "$S0" "一律删除" "§0 does not resolve K-09 with a blanket deletion"
# `report` mode is read-only and never loads round-0.md, so the check has to be
# stated where that mode is defined.
has "$TRIAGE" "先读 \`STATE.md\` 的机器 \`status:\` 再决定" "SKILL.md's report mode checks status before printing (K-09)"
has "$TRIAGE" "半成品" "SKILL.md's report mode says what a RUNNING-state report IS"

# --- K-11 part 2: a round log numbered past STATE.md's round: -----------------
has "$S0" "编号大于" "§0 names the half-written round log by how it is recognised (K-11)"
has "$S0" "重做该轮" "§0 says the interrupted round is redone"
has "$S0" "不得计入 \`converged_streak\`" "§0 refuses to credit a round that never settled"
has "$S0" "总账只追加" "§0 keeps the already-filed issues rather than re-finding them"

# --- K-10: the sentinel is re-armed on the resume path ------------------------
# round-0 §7 arms .active when the sandbox is built. A resume jumps from §0 to
# STATE.md's 下一动作 and never reaches §7, so without this the mechanism-layer
# guardrail is absent for the whole continuation.
has "$S0" ": > docs/looptesting/.active" "§0 gives the resume path the command to re-arm the sentinel (K-10)"
has "$S0" "不经过" "§0 says why the resume path does not get it from §7"
has "$S0" "stop-gate 静默失效" "§0 states the cost of a missing sentinel"

# --- K-03: the Stop hook cannot see $ARGUMENTS --------------------------------
# A `status` query in a project with a live loop is blocked by the gate, which
# tells the model to continue the round loop — the one thing this mode forbids.
has "$TRIAGE" "stop-gate 会拦停这次只读会话" "SKILL.md's status mode warns that the gate blocks it (K-03)"
has "$TRIAGE" "hook 看不到 \`\$ARGUMENTS\`" "SKILL.md says why the gate cannot distinguish the two"
has "$TRIAGE" "不要为了满足它而开跑" "SKILL.md forbids satisfying the gate by starting a run"
# Disarming is the other wrong exit, and the costlier one: the loop it would
# strip the guardrail from is someone else's live run.
has "$TRIAGE" "也不要删 \`.active\`" "SKILL.md forbids disarming a live loop's sentinel to get out"
has "$TRIAGE" "3 次" "SKILL.md states the gate's ceiling, so the model knows it terminates"

# The ceiling is a number in the hook. If it changes there, the prompt above is
# wrong and this pins them together.
grep -qE '^[[:space:]]*MAX_BLOCKS=3([[:space:]]|$)' "$GATE" \
  && pass "stop-gate's MAX_BLOCKS is still 3, the number SKILL.md quotes" \
  || fail "stop-gate's MAX_BLOCKS changed — SKILL.md's status-mode text quotes 3"

# --- the two documents must point at each other, or they drift apart ----------
# exit-and-report.md §4 owns the exit sequence; round-0 §0 owns what to do when
# it was interrupted. K-02 was exactly this: two prompt files ordering opposite
# things because neither referenced the other.
S4="$TMP/s4.md"
awk '/^## 4\./{f=1;next} /^## 5\./{f=0} f' "$EXITDOC" > "$S4"
[ -s "$S4" ] && pass "exit-and-report.md §4 (退出序) is extractable" \
             || fail "exit-and-report.md §4 could not be extracted — the section heading moved"
has "$S4" "round-0.md\` §0" "§4 points at the rule for its own interrupted window (K-09)"

finish() {
  printf '%s: %d passed, %d failed\n' "$_name" "$_pass" "$_failn"
  [ "$_fails" -eq 0 ]
}
finish
