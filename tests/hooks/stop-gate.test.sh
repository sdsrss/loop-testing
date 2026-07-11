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

report "stop-gate.test.sh"
