#!/usr/bin/env bash
# stop-gate.sh: allow when disarmed/terminal, block (fail-closed) when RUNNING or
# unparseable, MAX_BLOCKS deadlock valve (T3.5 runaway drill), progress reset.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

CF="docs/looptesting/.gate-count"
ACT="docs/looptesting/.active"

# A. no sentinel -> allow
WS=$(mk_lt); trap 'rm -rf "$WS"' EXIT
write_state "$WS" RUNNING 1
run_stop "$WS" false; assert_rc $? 0 "no .active -> allow stop"

# B. terminal status -> allow + disarm
WS2=$(mk_lt); trap 'rm -rf "$WS" "$WS2"' EXIT
arm "$WS2"; write_state "$WS2" CONVERGED 3 2
run_stop "$WS2" false; assert_rc $? 0 "status CONVERGED -> allow"
assert_absent "$WS2/$ACT" ".active removed on terminal status"
# H. idempotent: second call, no sentinel -> allow
run_stop "$WS2" false; assert_rc $? 0 "post-disarm second call -> allow (idempotent)"

# C. RUNNING -> block (fail-closed) and record counter
WS3=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3"' EXIT
arm "$WS3"; write_state "$WS3" RUNNING 1
run_stop "$WS3" false; assert_rc $? 2 "status RUNNING -> block"
assert_exists "$WS3/$CF" "gate-count written on block"

# D. missing status field -> fail-closed block
WS4=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4"' EXIT
arm "$WS4"; printf '# STATE\nround: 1\n' > "$WS4/docs/looptesting/STATE.md"
run_stop "$WS4" false; assert_rc $? 2 "missing status: -> fail-closed block"

# E. STATE.md absent entirely -> fail-closed block
WS5=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5"' EXIT
arm "$WS5"  # no STATE.md
run_stop "$WS5" false; assert_rc $? 2 "absent STATE.md -> fail-closed block"

# F. T3.5 runaway drill: stuck at same round -> 3 blocks then force-allow on 4th
WS6=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6"' EXIT
arm "$WS6"; write_state "$WS6" RUNNING 1
run_stop "$WS6" false; assert_rc $? 2 "runaway block 1/3"
run_stop "$WS6" true;  assert_rc $? 2 "runaway block 2/3"
run_stop "$WS6" true;  assert_rc $? 2 "runaway block 3/3"
run_stop "$WS6" true;  assert_rc $? 0 "runaway 4th attempt -> force-allow (no deadlock)"
assert_absent "$WS6/$CF" "counter cleared after force-allow"

# G. progress reset: advancing rounds must NOT accumulate toward the ceiling
WS7=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7"' EXIT
arm "$WS7"
for r in 1 2 3 4 5; do
  write_state "$WS7" RUNNING "$r"
  run_stop "$WS7" true; rc=$?
  assert_rc $rc 2 "progressing round $r still blocks (no premature allow)"
done
read -r c _ < "$WS7/$CF"
assert_eq "1" "$c" "counter stays 1 across progressing rounds (progress resets)"

# I. stale remnant: RUNNING + armed but STATE.md untouched for > threshold ->
#    allow + disarm (a crashed run must not tax every future stop) (audit B7).
WS8=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8"' EXIT
arm "$WS8"; write_state "$WS8" RUNNING 2
touch -d "@$(( $(date +%s) - 200000 ))" "$WS8/docs/looptesting/STATE.md"   # ~2.3 days old
run_stop "$WS8" false; assert_rc $? 0 "stale RUNNING remnant -> allow stop"
assert_absent "$WS8/$ACT" "stale remnant disarms the sentinel"

# J. fresh RUNNING (recent STATE mtime) still blocks — staleness must not weaken
#    the live-loop gate.
WS9=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9"' EXIT
arm "$WS9"; write_state "$WS9" RUNNING 2
run_stop "$WS9" false; assert_rc $? 2 "fresh RUNNING still blocks (staleness does not misfire)"

# K. grep-only fallback (no jq / no python3) must still reset the block counter on
#    a fresh stop, so independent stops don't accumulate toward the ceiling (C5).
WS10=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$BINDIR"' EXIT
arm "$WS10"; write_state "$WS10" RUNNING 1
BINDIR=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-nobin.XXXXXX")
for b in bash grep sed head tr cat rm date stat timeout mktemp printf; do
  p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$BINDIR/$b"
done
( cd "$WS10" && printf '{"stop_hook_active": false}' | PATH="$BINDIR" bash "$STOP" ) >/dev/null 2>&1
( cd "$WS10" && printf '{"stop_hook_active": false}' | PATH="$BINDIR" bash "$STOP" ) >/dev/null 2>&1
read -r kc _ < "$WS10/$CF"
assert_eq "1" "$kc" "grep-fallback resets counter on each fresh stop (no jq/python3)"

# L. jq path (jq present, the primary parser on most systems) must reset the block
#    counter on a fresh stop just like the grep fallback. `.stop_hook_active //
#    empty` treated false as empty (jq's // swallows false), so stop_active stayed
#    "unknown" and the reset never fired on the primary path — C5 was only applied
#    to grep (HK-1). Two independent fresh stops must NOT accumulate.
WS11=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$BINDIR" "$WS11"' EXIT
arm "$WS11"; write_state "$WS11" RUNNING 1
run_stop "$WS11" false; run_stop "$WS11" false
read -r lc _ < "$WS11/$CF"
assert_eq "1" "$lc" "jq path resets counter on each fresh stop (HK-1)"

# M. LOOP_TESTING_GATE_STALE_SECONDS=0 disables the stale-remnant escape: an old
#    RUNNING remnant must still BLOCK (the auto-disarm must be opt-out-able — the
#    `0` disable path was previously untested).
WS12=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$BINDIR" "$WS11" "$WS12"' EXIT
arm "$WS12"; write_state "$WS12" RUNNING 2
touch -d "@$(( $(date +%s) - 200000 ))" "$WS12/docs/looptesting/STATE.md"   # ~2.3 days old
( cd "$WS12" && printf '{"stop_hook_active": false}' | LOOP_TESTING_GATE_STALE_SECONDS=0 bash "$STOP" ) >/dev/null 2>&1
assert_rc $? 2 "GATE_STALE_SECONDS=0 disables disarm: old RUNNING remnant still blocks"
assert_exists "$WS12/$ACT" "sentinel NOT disarmed when staleness is disabled"

# N. HK-7: hook run from an UNRELATED cwd with $CLAUDE_PROJECT_DIR pointing at the
#    armed workspace must still block a RUNNING stop — cwd-relative resolution
#    used to miss the sentinel entirely and fail open (allow).
WS13=$(mk_lt); OTHER=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-othercwd.XXXXXX")
trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$BINDIR" "$WS11" "$WS12" "$WS13" "$OTHER"' EXIT
arm "$WS13"; write_state "$WS13" RUNNING 1
( cd "$OTHER" && printf '{"stop_hook_active": false}' | CLAUDE_PROJECT_DIR="$WS13" bash "$STOP" ) >/dev/null 2>&1
assert_rc $? 2 "wrong cwd + CLAUDE_PROJECT_DIR -> still blocks RUNNING (HK-7)"

# O. HK-7: same, but anchored via the stdin JSON "cwd" field (no env var) — the
#    hook input's cwd is the fallback anchor when $CLAUDE_PROJECT_DIR is unset.
WS14=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$BINDIR" "$WS11" "$WS12" "$WS13" "$OTHER" "$WS14"' EXIT
arm "$WS14"; write_state "$WS14" RUNNING 1
( cd "$OTHER" && printf '{"stop_hook_active": false, "cwd": "%s"}' "$WS14" | env -u CLAUDE_PROJECT_DIR bash "$STOP" ) >/dev/null 2>&1
assert_rc $? 2 "wrong cwd + stdin cwd field -> still blocks RUNNING (HK-7)"

# P. python3-only parser path (jq absent, python3 present): fresh stops must
#    reset the counter exactly like the jq (L) and grep (K) paths — the third
#    leg of the three-way parser was previously untested.
WS15=$(mk_lt); BINP=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-py3bin.XXXXXX")
trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$BINDIR" "$WS11" "$WS12" "$WS13" "$OTHER" "$WS14" "$WS15" "$BINP"' EXIT
for b in bash grep sed head tr cat rm date stat timeout mktemp printf python3; do
  p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$BINP/$b"
done
arm "$WS15"; write_state "$WS15" RUNNING 1
( cd "$WS15" && printf '{"stop_hook_active": false}' | env -u CLAUDE_PROJECT_DIR PATH="$BINP" bash "$STOP" ) >/dev/null 2>&1
( cd "$WS15" && printf '{"stop_hook_active": false}' | env -u CLAUDE_PROJECT_DIR PATH="$BINP" bash "$STOP" ) >/dev/null 2>&1
read -r pc _ < "$WS15/$CF"
assert_eq "1" "$pc" "python3-only parser resets counter on each fresh stop (no jq)"

# Q. LOOP_TESTING_DISABLE_STOP_GATE=1 escape hatch: allows the stop and leaves
#    the sentinel untouched (the hook exits before reading any state).
WS16=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$BINDIR" "$WS11" "$WS12" "$WS13" "$OTHER" "$WS14" "$WS15" "$BINP" "$WS16"' EXIT
arm "$WS16"; write_state "$WS16" RUNNING 1
( cd "$WS16" && printf '{"stop_hook_active": false}' | LOOP_TESTING_DISABLE_STOP_GATE=1 env -u CLAUDE_PROJECT_DIR bash "$STOP" ) >/dev/null 2>&1
assert_rc $? 0 "escape hatch allows the stop on a RUNNING armed loop"
assert_exists "$WS16/$ACT" "escape hatch leaves the sentinel in place (not a disarm)"

# R. R59 (NEW-3): orphan sentinel with NO STATE.md at all — the stale escape must
#    fall back to the sentinel's own mtime, or the orphan taxes every future stop
#    forever (the STATE-mtime escape can never fire when STATE.md never existed).
#    Case E already asserts the fresh-orphan side (recent .active, no STATE ->
#    fail-closed block), so this only adds the aged-orphan release.
WS17=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$BINDIR" "$WS11" "$WS12" "$WS13" "$OTHER" "$WS14" "$WS15" "$BINP" "$WS16" "$WS17"' EXIT
arm "$WS17"   # deliberately NO STATE.md
touch -d "@$(( $(date +%s) - 200000 ))" "$WS17/$ACT"   # ~2.3 days old
run_stop "$WS17" false; assert_rc $? 0 "stale orphan .active (no STATE.md) -> allow stop (R59)"
assert_absent "$WS17/$ACT" "stale orphan sentinel disarmed (R59)"

# S. H-03: two DIFFERENT `status:` values are ambiguous -> fail-closed block, and
#    the sentinel survives. The old `head -1` resolved the ambiguity by position,
#    so an example line written ABOVE the machine field disarmed the gate and
#    deleted .active — fail-open in the destructive direction.
WS18=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$BINDIR" "$WS11" "$WS12" "$WS13" "$OTHER" "$WS14" "$WS15" "$BINP" "$WS16" "$WS17" "$WS18"' EXIT
arm "$WS18"
cat > "$WS18/docs/looptesting/STATE.md" <<'EOF'
# STATE

示例（勿照抄）：收敛时机器字段写成
status: CONVERGED

## 机器判读字段（勿改键名）

```
round: 3
converged_streak: 0
status: RUNNING
max_rounds: 12
```
EOF
run_stop "$WS18" false; assert_rc $? 2 "example 'status:' above the machine field -> block (H-03)"
assert_exists "$WS18/$ACT" "conflicting status: values leave the sentinel armed (H-03)"
ERRTXT=$(run_stop_err "$WS18" false)
case "$ERRTXT" in
  *"conflicting 'status:' values"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: block reason must name the conflict — got [$ERRTXT]" >&2 ;;
esac

# T. Same ambiguity with the terminal value LAST: blocking must not depend on
#    which value happens to come first, or the fix is just a different position rule.
WS19=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$BINDIR" "$WS11" "$WS12" "$WS13" "$OTHER" "$WS14" "$WS15" "$BINP" "$WS16" "$WS17" "$WS18" "$WS19"' EXIT
arm "$WS19"
cat > "$WS19/docs/looptesting/STATE.md" <<'EOF'
# STATE
status: RUNNING

```
round: 4
status: CONVERGED
max_rounds: 12
```
EOF
run_stop "$WS19" false; assert_rc $? 2 "stray 'status:' above a terminal machine field -> block (H-03)"
assert_exists "$WS19/$ACT" "sentinel armed when the terminal value is the ambiguous one (H-03)"

# U. Repeats that AGREE are not ambiguous: the gate must still parse them, or
#    H-03's fix becomes a new false-block surface of its own.
WS20=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$BINDIR" "$WS11" "$WS12" "$WS13" "$OTHER" "$WS14" "$WS15" "$BINP" "$WS16" "$WS17" "$WS18" "$WS19" "$WS20"' EXIT
arm "$WS20"
cat > "$WS20/docs/looptesting/STATE.md" <<'EOF'
# STATE
status: CONVERGED

```
round: 5
status: CONVERGED
max_rounds: 12
```
EOF
run_stop "$WS20" false; assert_rc $? 0 "duplicate but identical status: values -> allow (not ambiguous)"
assert_absent "$WS20/$ACT" "identical duplicates still disarm on a terminal status"

# V. An ambiguous `round:` is reported unknown (-1), never guessed: -1 withholds
#    the progress-based counter reset, which errs toward blocking.
WS21=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$BINDIR" "$WS11" "$WS12" "$WS13" "$OTHER" "$WS14" "$WS15" "$BINP" "$WS16" "$WS17" "$WS18" "$WS19" "$WS20" "$WS21"' EXIT
arm "$WS21"
cat > "$WS21/docs/looptesting/STATE.md" <<'EOF'
# STATE
round: 1

```
round: 9
status: RUNNING
max_rounds: 12
```
EOF
run_stop "$WS21" false; assert_rc $? 2 "RUNNING with an ambiguous round: -> block"
read -r _ pr21 < "$WS21/$CF"
assert_eq "1|9" "$pr21" "an ambiguous round records the whole SET, not one guessed value"

# W. The H-03 parse must stay builtins-only: on the bare PATH of case K (no sort,
#    no uniq, no wc) a TERMINAL status must still disarm. A parse that needs a
#    helper which is not there reads as "unparseable" and blocks every stop in
#    the project until the deadlock valve fires — fail-closed, but wrong.
WS22=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$BINDIR" "$WS11" "$WS12" "$WS13" "$OTHER" "$WS14" "$WS15" "$BINP" "$WS16" "$WS17" "$WS18" "$WS19" "$WS20" "$WS21" "$WS22"' EXIT
arm "$WS22"; write_state "$WS22" CONVERGED 6 2
( cd "$WS22" && printf '{"stop_hook_active": false}' | env -u CLAUDE_PROJECT_DIR PATH="$BINDIR" bash "$STOP" ) >/dev/null 2>&1
assert_rc $? 0 "terminal status parses on a bare PATH (no sort/uniq/wc) -> allow"
assert_absent "$WS22/$ACT" "terminal status disarms on a bare PATH (H-03 parse is builtins-only)"

# X. The parse must be BOUNDED. It runs after the grep's own GATE_BUDGET, and the
#    platform treats a Stop hook killed by its 15s manifest timeout as exit 0 =
#    ALLOW — so a parse that scales with STATE.md is a fail-OPEN path. The dedupe
#    introduced with H-03 was O(n²): 18 000 distinct machine-field lines took
#    14.7s, inside the manifest timeout, against 0.21s for the parse it replaced.
#    `timeout 5` is the assertion: rc 2 means it blocked, rc 124 means it would
#    have been killed by the platform and the stop would have been ALLOWED.
WS23=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$BINDIR" "$WS11" "$WS12" "$WS13" "$OTHER" "$WS14" "$WS15" "$BINP" "$WS16" "$WS17" "$WS18" "$WS19" "$WS20" "$WS21" "$WS22" "$WS23"' EXIT
arm "$WS23"
{ echo '# STATE'; i=0; while [ "$i" -lt 20000 ]; do echo "round: $i"; i=$((i+1)); done; echo 'status: RUNNING'; } \
  > "$WS23/docs/looptesting/STATE.md"
( cd "$WS23" && printf '{"stop_hook_active": false}' | env -u CLAUDE_PROJECT_DIR timeout 5 bash "$STOP" ) >/dev/null 2>&1
RC23=$?
assert_rc "$RC23" 2 "20k distinct machine-field lines still BLOCK, and inside 5s (not killed -> allowed)"
assert_exists "$WS23/$ACT" "an oversized STATE.md leaves the sentinel armed"
ERR23=$( ( cd "$WS23" && printf '{"stop_hook_active": false}' | env -u CLAUDE_PROJECT_DIR timeout 5 bash "$STOP" ) 2>&1 1>/dev/null )
case "$ERR23" in
  *"machine-field"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: the refusal must name the line cap — got [$ERR23]" >&2 ;;
esac

# Y. The cap must not fire on an honest file: a STATE.md with a handful of
#    machine-field lines still parses normally, or the bound is a new false block.
WS24=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$BINDIR" "$WS11" "$WS12" "$WS13" "$OTHER" "$WS14" "$WS15" "$BINP" "$WS16" "$WS17" "$WS18" "$WS19" "$WS20" "$WS21" "$WS22" "$WS23" "$WS24"' EXIT
arm "$WS24"; write_state "$WS24" CONVERGED 7 2
run_stop "$WS24" false; assert_rc $? 0 "an ordinary STATE.md is nowhere near the line cap -> allow"
assert_absent "$WS24/$ACT" "ordinary terminal STATE.md still disarms under the bounded parse"

# Z. HIGH-4: the deadlock valve must not fire on a loop that is ADVANCING. The
#    counter's progress arm used to key on one normalized integer, so a single
#    stray `round:` line anywhere in STATE.md (a `## history` note is enough)
#    made every round parse as "unknown", disabled the reset for the entire
#    hook-induced chain, and force-allowed the stop on the 4th attempt — on an
#    unconverged loop that was making progress every single round.
WS25=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$BINDIR" "$WS11" "$WS12" "$WS13" "$OTHER" "$WS14" "$WS15" "$BINP" "$WS16" "$WS17" "$WS18" "$WS19" "$WS20" "$WS21" "$WS22" "$WS23" "$WS24" "$WS25"' EXIT
arm "$WS25"
for r in 1 2 3 4 5; do
  printf '# STATE\nround: %s\nstatus: RUNNING\n\n## history\nround: 0 baseline\n' "$r" \
    > "$WS25/docs/looptesting/STATE.md"
  run_stop "$WS25" true
  assert_rc $? 2 "advancing round $r blocks despite a stray round: line (no force-allow)"
done
read -r c25 _ < "$WS25/$CF"
assert_eq "1" "$c25" "a changing round SET resets the counter (the valve never arms)"

# AA. MEDIUM-4: an empty machine-field value is a value. A bare `status:` above a
#     real `status: CONVERGED` made the empty one invisible, left the terminal
#     value standing alone, and DISARMED — where the pre-H-03 code read the empty
#     first line and fail-closed. Both orderings, because this is a value class
#     disappearing, not position-dependence returning.
WS26=$(mk_lt); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4" "$WS5" "$WS6" "$WS7" "$WS8" "$WS9" "$WS10" "$BINDIR" "$WS11" "$WS12" "$WS13" "$OTHER" "$WS14" "$WS15" "$BINP" "$WS16" "$WS17" "$WS18" "$WS19" "$WS20" "$WS21" "$WS22" "$WS23" "$WS24" "$WS25" "$WS26"' EXIT
arm "$WS26"; printf '# STATE\nstatus:\nstatus: CONVERGED\nround: 3\n' > "$WS26/docs/looptesting/STATE.md"
run_stop "$WS26" false; assert_rc $? 2 "empty status: value above a terminal one -> block"
assert_exists "$WS26/$ACT" "an empty status: value leaves the sentinel armed"
printf '# STATE\nstatus: CONVERGED\nstatus:   \nround: 3\n' > "$WS26/docs/looptesting/STATE.md"
run_stop "$WS26" false; assert_rc $? 2 "whitespace-only status: value below a terminal one -> block"
assert_exists "$WS26/$ACT" "a whitespace-only status: value leaves the sentinel armed"

report "stop-gate.test.sh"
