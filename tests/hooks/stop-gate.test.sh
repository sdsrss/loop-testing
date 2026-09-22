#!/usr/bin/env bash
# stop-gate.sh: allow when disarmed/terminal, block (fail-closed) when RUNNING or
# unparseable, MAX_BLOCKS deadlock valve (T3.5 runaway drill), progress reset.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# Fixtures are registered as they are created and the trap is set once. The
# retyped-list form this replaces had 28 copies of the same list, and the copy at
# the WS10 site referenced $BINDIR two lines before its first assignment — a
# forward reference that, under `set -u`, aborts the whole `rm -rf` during word
# expansion if an exit lands in that window.
#
# Measured, not preventive: injecting `exit 7` into that window on the
# pre-conversion file leaves 10 fixture directories behind — every workspace the
# file had made — exactly like tests/sandbox/purge.test.sh, which leaks 11 and is
# the one audit T-10 names.
#
# An earlier version of this comment said the opposite, on the strength of a
# probe that ran the suite from outside its own directory, where `dirname $0`
# resolves neither lib.sh nor $STOP and the run bears no relation to a real one.
# That probe returned rc=1 for a file with `exit 7` injected at the top — the
# exit code and the injection contradicted each other, which is the point at
# which a measurement is void. It got an explanation instead, and a "0 leaked"
# that nothing supported went into a comment and a commit message. A probe that
# cannot answer is not an answer; that is the whole subject of this branch.
#
# An array, not a delimited string — see the note in tests/sandbox/purge.test.sh.
# A newline-delimited string is safe for spaces and globs and still splits a
# $TMPDIR containing a newline into two arguments, the first of which is an
# absolute path that may exist. bash 3.2 under `set -u`: `${#A[@]}` on an empty
# array is safe, `"${A[@]}"` is not, so the count test must short-circuit first.
WS_ALL=()
track_ws() { WS_ALL+=("$1"); }
cleanup_all() {
  if [ "${#WS_ALL[@]}" -gt 0 ]; then rm -rf -- "${WS_ALL[@]}"; fi
}
trap cleanup_all EXIT

CF="docs/looptesting/.gate-count"
ACT="docs/looptesting/.active"

# A. no sentinel -> allow
WS=$(mk_lt); track_ws "$WS"
write_state "$WS" RUNNING 1
run_stop "$WS" false; assert_rc $? 0 "no .active -> allow stop"

# B. terminal status -> allow + disarm
WS2=$(mk_lt); track_ws "$WS2"
arm "$WS2"; write_state "$WS2" CONVERGED 3 2
run_stop "$WS2" false; assert_rc $? 0 "status CONVERGED -> allow"
assert_absent "$WS2/$ACT" ".active removed on terminal status"
# H. idempotent: second call, no sentinel -> allow
run_stop "$WS2" false; assert_rc $? 0 "post-disarm second call -> allow (idempotent)"

# C. RUNNING -> block (fail-closed) and record counter
WS3=$(mk_lt); track_ws "$WS3"
arm "$WS3"; write_state "$WS3" RUNNING 1
run_stop "$WS3" false; assert_rc $? 2 "status RUNNING -> block"
assert_exists "$WS3/$CF" "gate-count written on block"

# D. missing status field -> fail-closed block
WS4=$(mk_lt); track_ws "$WS4"
arm "$WS4"; printf '# STATE\nround: 1\n' > "$WS4/docs/looptesting/STATE.md"
run_stop "$WS4" false; assert_rc $? 2 "missing status: -> fail-closed block"

# E. STATE.md absent entirely -> fail-closed block
WS5=$(mk_lt); track_ws "$WS5"
arm "$WS5"  # no STATE.md
run_stop "$WS5" false; assert_rc $? 2 "absent STATE.md -> fail-closed block"

# F. T3.5 runaway drill: stuck at same round -> 3 blocks then force-allow on 4th
WS6=$(mk_lt); track_ws "$WS6"
arm "$WS6"; write_state "$WS6" RUNNING 1
run_stop "$WS6" false; assert_rc $? 2 "runaway block 1/3"
run_stop "$WS6" true;  assert_rc $? 2 "runaway block 2/3"
run_stop "$WS6" true;  assert_rc $? 2 "runaway block 3/3"
run_stop "$WS6" true;  assert_rc $? 0 "runaway 4th attempt -> force-allow (no deadlock)"
assert_absent "$WS6/$CF" "counter cleared after force-allow"

# G. progress reset: advancing rounds must NOT accumulate toward the ceiling
WS7=$(mk_lt); track_ws "$WS7"
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
WS8=$(mk_lt); track_ws "$WS8"
arm "$WS8"; write_state "$WS8" RUNNING 2
touch -d "@$(( $(date +%s) - 200000 ))" "$WS8/docs/looptesting/STATE.md"   # ~2.3 days old
run_stop "$WS8" false; assert_rc $? 0 "stale RUNNING remnant -> allow stop"
assert_absent "$WS8/$ACT" "stale remnant disarms the sentinel"

# J. fresh RUNNING (recent STATE mtime) still blocks — staleness must not weaken
#    the live-loop gate.
WS9=$(mk_lt); track_ws "$WS9"
arm "$WS9"; write_state "$WS9" RUNNING 2
run_stop "$WS9" false; assert_rc $? 2 "fresh RUNNING still blocks (staleness does not misfire)"

# K. grep-only fallback (no jq / no python3) must still reset the block counter on
#    a fresh stop, so independent stops don't accumulate toward the ceiling (C5).
WS10=$(mk_lt); track_ws "$WS10"
arm "$WS10"; write_state "$WS10" RUNNING 1
BINDIR=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-nobin.XXXXXX"); track_ws "$BINDIR"
for b in bash grep sed head tr cat rm date stat timeout mktemp printf; do
  p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$BINDIR/$b"
done
( cd "$WS10" && printf '{"stop_hook_active": false}' | env -u CLAUDE_PROJECT_DIR PATH="$BINDIR" bash "$STOP" ) >/dev/null 2>&1
( cd "$WS10" && printf '{"stop_hook_active": false}' | env -u CLAUDE_PROJECT_DIR PATH="$BINDIR" bash "$STOP" ) >/dev/null 2>&1
read -r kc _ < "$WS10/$CF"
assert_eq "1" "$kc" "grep-fallback resets counter on each fresh stop (no jq/python3)"

# L. jq path (jq present, the primary parser on most systems) must reset the block
#    counter on a fresh stop just like the grep fallback. `.stop_hook_active //
#    empty` treated false as empty (jq's // swallows false), so stop_active stayed
#    "unknown" and the reset never fired on the primary path — C5 was only applied
#    to grep (HK-1). Two independent fresh stops must NOT accumulate.
WS11=$(mk_lt); track_ws "$WS11"
arm "$WS11"; write_state "$WS11" RUNNING 1
run_stop "$WS11" false; run_stop "$WS11" false
read -r lc _ < "$WS11/$CF"
assert_eq "1" "$lc" "jq path resets counter on each fresh stop (HK-1)"

# M. LOOP_TESTING_GATE_STALE_SECONDS=0 disables the stale-remnant escape: an old
#    RUNNING remnant must still BLOCK (the auto-disarm must be opt-out-able — the
#    `0` disable path was previously untested).
WS12=$(mk_lt); track_ws "$WS12"
arm "$WS12"; write_state "$WS12" RUNNING 2
touch -d "@$(( $(date +%s) - 200000 ))" "$WS12/docs/looptesting/STATE.md"   # ~2.3 days old
( cd "$WS12" && printf '{"stop_hook_active": false}' | env -u CLAUDE_PROJECT_DIR LOOP_TESTING_GATE_STALE_SECONDS=0 bash "$STOP" ) >/dev/null 2>&1
assert_rc $? 2 "GATE_STALE_SECONDS=0 disables disarm: old RUNNING remnant still blocks"
assert_exists "$WS12/$ACT" "sentinel NOT disarmed when staleness is disabled"

# N. HK-7: hook run from an UNRELATED cwd with $CLAUDE_PROJECT_DIR pointing at the
#    armed workspace must still block a RUNNING stop — cwd-relative resolution
#    used to miss the sentinel entirely and fail open (allow).
WS13=$(mk_lt); OTHER=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-othercwd.XXXXXX"); track_ws "$WS13"; track_ws "$OTHER"
arm "$WS13"; write_state "$WS13" RUNNING 1
( cd "$OTHER" && printf '{"stop_hook_active": false}' | CLAUDE_PROJECT_DIR="$WS13" bash "$STOP" ) >/dev/null 2>&1
assert_rc $? 2 "wrong cwd + CLAUDE_PROJECT_DIR -> still blocks RUNNING (HK-7)"

# O. HK-7: same, but anchored via the stdin JSON "cwd" field (no env var) — the
#    hook input's cwd is the fallback anchor when $CLAUDE_PROJECT_DIR is unset.
WS14=$(mk_lt); track_ws "$WS14"
arm "$WS14"; write_state "$WS14" RUNNING 1
( cd "$OTHER" && printf '{"stop_hook_active": false, "cwd": "%s"}' "$WS14" | env -u CLAUDE_PROJECT_DIR bash "$STOP" ) >/dev/null 2>&1
assert_rc $? 2 "wrong cwd + stdin cwd field -> still blocks RUNNING (HK-7)"

# P. python3-only parser path (jq absent, python3 present): fresh stops must
#    reset the counter exactly like the jq (L) and grep (K) paths — the third
#    leg of the three-way parser was previously untested.
WS15=$(mk_lt); BINP=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-py3bin.XXXXXX"); track_ws "$WS15"; track_ws "$BINP"
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
WS16=$(mk_lt); track_ws "$WS16"
arm "$WS16"; write_state "$WS16" RUNNING 1
( cd "$WS16" && printf '{"stop_hook_active": false}' | LOOP_TESTING_DISABLE_STOP_GATE=1 env -u CLAUDE_PROJECT_DIR bash "$STOP" ) >/dev/null 2>&1
assert_rc $? 0 "escape hatch allows the stop on a RUNNING armed loop"
assert_exists "$WS16/$ACT" "escape hatch leaves the sentinel in place (not a disarm)"

# R. R59 (NEW-3): orphan sentinel with NO STATE.md at all — the stale escape must
#    fall back to the sentinel's own mtime, or the orphan taxes every future stop
#    forever (the STATE-mtime escape can never fire when STATE.md never existed).
#    Case E already asserts the fresh-orphan side (recent .active, no STATE ->
#    fail-closed block), so this only adds the aged-orphan release.
WS17=$(mk_lt); track_ws "$WS17"
arm "$WS17"   # deliberately NO STATE.md
touch -d "@$(( $(date +%s) - 200000 ))" "$WS17/$ACT"   # ~2.3 days old
run_stop "$WS17" false; assert_rc $? 0 "stale orphan .active (no STATE.md) -> allow stop (R59)"
assert_absent "$WS17/$ACT" "stale orphan sentinel disarmed (R59)"

# S. H-03: two DIFFERENT `status:` values are ambiguous -> fail-closed block, and
#    the sentinel survives. The old `head -1` resolved the ambiguity by position,
#    so an example line written ABOVE the machine field disarmed the gate and
#    deleted .active — fail-open in the destructive direction.
WS18=$(mk_lt); track_ws "$WS18"
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
WS19=$(mk_lt); track_ws "$WS19"
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
WS20=$(mk_lt); track_ws "$WS20"
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
WS21=$(mk_lt); track_ws "$WS21"
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
assert_eq "2:1|9" "$pr21" "an ambiguous round records count and the whole SET, not one guessed value"

# W. The H-03 parse must stay builtins-only: on the bare PATH of case K (no sort,
#    no uniq, no wc) a TERMINAL status must still disarm. A parse that needs a
#    helper which is not there reads as "unparseable" and blocks every stop in
#    the project until the deadlock valve fires — fail-closed, but wrong.
WS22=$(mk_lt); track_ws "$WS22"
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
WS23=$(mk_lt); track_ws "$WS23"
arm "$WS23"
{ echo '# STATE'; i=0; while [ "$i" -lt 20000 ]; do echo "round: $i"; i=$((i+1)); done; echo 'status: RUNNING'; } \
  > "$WS23/docs/looptesting/STATE.md"
# The bound IS the assertion here, so a host with no binary to provide it has
# nothing to assert — premise-guarded rather than run unbounded, since an
# unbounded parse is the fail-open this case exists to catch. These three sites
# called bare `timeout` until now, which is GNU-only: on stock macOS or a
# gtimeout-only host it returned 127, and all three assertions failed, blaming
# the hook for a binary the harness had not looked for (review T-D's shape,
# six sites its fix did not reach). `env` cannot run a shell function, so this
# takes $TIMEOUT_BIN directly rather than bounded().
if [ -n "$TIMEOUT_BIN" ]; then
  ( cd "$WS23" && printf '{"stop_hook_active": false}' | env -u CLAUDE_PROJECT_DIR "$TIMEOUT_BIN" 5 bash "$STOP" ) >/dev/null 2>&1
  RC23=$?
  assert_rc "$RC23" 2 "20k distinct machine-field lines still BLOCK, and inside 5s (not killed -> allowed)"
  assert_exists "$WS23/$ACT" "an oversized STATE.md leaves the sentinel armed"
  ERR23=$( ( cd "$WS23" && printf '{"stop_hook_active": false}' | env -u CLAUDE_PROJECT_DIR "$TIMEOUT_BIN" 5 bash "$STOP" ) 2>&1 1>/dev/null )
  case "$ERR23" in
    *"machine-field"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1)); echo "  FAIL: the refusal must name the line cap — got [$ERR23]" >&2 ;;
  esac
else
  # These messages name the block that did not run and give no count, on purpose:
  # a number written beside a block goes stale the first time the block gains a
  # line, which is the drift this release exists to remove.
  echo "  skip: no timeout/gtimeout on PATH — the bound IS the assertion here, so none of case X's checks on the 20k-line parse ran"
fi

# Y. The cap must not fire on an honest file: a STATE.md with a handful of
#    machine-field lines still parses normally, or the bound is a new false block.
WS24=$(mk_lt); track_ws "$WS24"
arm "$WS24"; write_state "$WS24" CONVERGED 7 2
run_stop "$WS24" false; assert_rc $? 0 "an ordinary STATE.md is nowhere near the line cap -> allow"
assert_absent "$WS24/$ACT" "ordinary terminal STATE.md still disarms under the bounded parse"

# Z. HIGH-4: the deadlock valve must not fire on a loop that is ADVANCING. The
#    counter's progress arm used to key on one normalized integer, so a single
#    stray `round:` line anywhere in STATE.md (a `## history` note is enough)
#    made every round parse as "unknown", disabled the reset for the entire
#    hook-induced chain, and force-allowed the stop on the 4th attempt — on an
#    unconverged loop that was making progress every single round.
WS25=$(mk_lt); track_ws "$WS25"
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
WS26=$(mk_lt); track_ws "$WS26"
arm "$WS26"; printf '# STATE\nstatus:\nstatus: CONVERGED\nround: 3\n' > "$WS26/docs/looptesting/STATE.md"
run_stop "$WS26" false; assert_rc $? 2 "empty status: value above a terminal one -> block"
assert_exists "$WS26/$ACT" "an empty status: value leaves the sentinel armed"
printf '# STATE\nstatus: CONVERGED\nstatus:   \nround: 3\n' > "$WS26/docs/looptesting/STATE.md"
run_stop "$WS26" false; assert_rc $? 2 "whitespace-only status: value below a terminal one -> block"
assert_exists "$WS26/$ACT" "a whitespace-only status: value leaves the sentinel armed"

# BB. The line cap alone does not bound the COST. 200 lines is legal, and each
#     value is unbounded, so 200 x 100 KB is 20 MB of dedupe scanning: measured
#     at rc=124 — killed by the platform's 15s timeout, which means ALLOW — where
#     the parse this replaced returned rc=2 in 0.8s. Case X used many SHORT
#     lines, which the line cap does catch, so it could not see this.
WS27=$(mk_lt); track_ws "$WS27"
arm "$WS27"
{ echo '# STATE'
  i=0; big=$(printf '%0.sA' $(seq 1 100000))
  while [ "$i" -lt 200 ]; do printf 'round: %s%s\n' "$big" "$i"; i=$((i+1)); done
  echo 'status: RUNNING'
} > "$WS27/docs/looptesting/STATE.md"
if [ -n "$TIMEOUT_BIN" ]; then   # the bound is the assertion — see case X above
  ( cd "$WS27" && printf '{"stop_hook_active": false}' | env -u CLAUDE_PROJECT_DIR "$TIMEOUT_BIN" 5 bash "$STOP" ) >/dev/null 2>&1
  assert_rc $? 2 "200 lines of 100 KB values still BLOCK inside 5s (cost, not just count)"
  assert_exists "$WS27/$ACT" "a 20 MB STATE.md leaves the sentinel armed"
else
  echo "  skip: no timeout/gtimeout on PATH — the bound IS the assertion here, so none of case BB's checks on the 20 MB STATE.md ran"
fi

# CC. The round signature must not collide on a shared prefix. Truncating it to a
#     prefix alone made two different sets read as "no progress" — the force-allow
#     of case Z again, reached through the truncation instead of through -1.
WS28=$(mk_lt); track_ws "$WS28"
arm "$WS28"
for n in 1 2 3 4 5; do
  { echo '# STATE'
    i=0; while [ "$i" -lt 40 ]; do printf 'round: AAAAAAAA%s\n' "$i"; i=$((i+1)); done
    printf 'round: TAIL%s\n' "$n"
    echo 'status: RUNNING'
  } > "$WS28/docs/looptesting/STATE.md"
  run_stop "$WS28" true
  assert_rc $? 2 "long round set, advancing tail, stop $n still blocks (no force-allow)"
done
read -r c28 _ < "$WS28/$CF"
assert_eq "1" "$c28" "a set that differs past the prefix still counts as progress"

# DD. K-14: the monorepo topology. sandbox-setup.sh creates docs/looptesting/ at
#     the GIT TOPLEVEL; this hook anchors at $CLAUDE_PROJECT_DIR, which is where
#     the SESSION was started. Those coincide only when the session started at
#     the repo root. Started from a subpackage, the gate found no sentinel beside
#     the package and read that as "no armed loop" — the mechanism layer off for
#     the whole run, and silent, because an allowed stop is also exactly what a
#     project that never ran the loop looks like.
MONO=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-mono.XXXXXX"); track_ws "$MONO"
git init -q "$MONO" >/dev/null 2>&1
mkdir -p "$MONO/pkgs/app" "$MONO/docs/looptesting/runs"
printf '# ISSUES\n' > "$MONO/docs/looptesting/ISSUES.md"
arm "$MONO"; write_state "$MONO" RUNNING 1
# Fixture self-probe, and it asserts IDENTITY, not existence (review T-2). The
# first version asked only that `git rev-parse --show-toplevel` print something
# non-empty. With GIT_DIR exported — git sets it for its own hooks, for
# `rebase --exec`, for `bisect run` — `git init -q "$MONO"` returns 0 having
# created no repository at $MONO at all, and the toplevel that comes back is
# whatever outer repo contains $TMPDIR. A non-empty check passes on that, DD
# then passes without touching the fixture, and the suite writes .gate-count
# into an unrelated repository. A probe that cannot fail is the thing this case
# exists to prevent, and it was the probe.
if [ ! -d "$MONO/pkgs/app/docs/looptesting" ] \
   && [ "$( cd "$MONO/pkgs/app" && git rev-parse --show-toplevel 2>/dev/null )" = "$( cd "$MONO" && pwd -P )" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); echo "  FAIL: fixture: subpackage must be evidence-free and inside the repo THIS case created" >&2
fi
( cd "$MONO/pkgs/app" && printf '{"stop_hook_active": false}' | CLAUDE_PROJECT_DIR="$MONO/pkgs/app" bash "$STOP" ) >/dev/null 2>&1
assert_rc $? 2 "monorepo subpackage: gate reaches the toplevel evidence dir and still blocks (K-14)"

# EE. Control for DD: same topology, toplevel evidence dir present but NOT armed.
#     The walk-up must FIND a gate, never invent one — a repo that is not running
#     the loop has to keep exiting 0 from every subdirectory in it.
#
#     Stated plainly (review T-12): no single-edit mutation of the CURRENT
#     implementation turns this red, because nothing in it treats the evidence
#     directory's existence as arming. It is a contract statement about the
#     boundary, not a discriminating test — kept because "the directory is here,
#     so the loop is on" is a plausible next edit, and this is what would catch
#     it. Do not count it as coverage of the walk-up.
MONO2=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-mono.XXXXXX"); track_ws "$MONO2"
git init -q "$MONO2" >/dev/null 2>&1
mkdir -p "$MONO2/pkgs/app" "$MONO2/docs/looptesting/runs"
write_state "$MONO2" RUNNING 1          # RUNNING but no .active: never armed
( cd "$MONO2/pkgs/app" && printf '{"stop_hook_active": false}' | CLAUDE_PROJECT_DIR="$MONO2/pkgs/app" bash "$STOP" ) >/dev/null 2>&1
assert_rc $? 0 "monorepo subpackage, toplevel not armed -> still allows (no gate invented)"

# FF. Control for DD: the subpackage runs its OWN loop. The nearer evidence dir
#     governs and the walk-up must not reach past it. Discriminating on purpose:
#     the subpackage's own dir is DISARMED while the root's is armed + RUNNING,
#     so an unconditional walk-up would block here and the narrow one allows.
MONO3=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-mono.XXXXXX"); track_ws "$MONO3"
git init -q "$MONO3" >/dev/null 2>&1
mkdir -p "$MONO3/pkgs/app/docs/looptesting/runs" "$MONO3/docs/looptesting/runs"
arm "$MONO3"; write_state "$MONO3" RUNNING 1
write_state "$MONO3/pkgs/app" CONVERGED 4
( cd "$MONO3/pkgs/app" && printf '{"stop_hook_active": false}' | CLAUDE_PROJECT_DIR="$MONO3/pkgs/app" bash "$STOP" ) >/dev/null 2>&1
assert_rc $? 0 "subpackage with its own evidence dir keeps it (no reach past the nearer one)"

# GG. Control for DD: no git on PATH. The walk-up is guarded by `command -v git`,
#     and a hook that errors is a hook that fails open on the platform's timeout.
MONO4=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-mono.XXXXXX"); track_ws "$MONO4"
BING=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-nogit.XXXXXX"); track_ws "$BING"
for b in bash grep sed head tr cat rm date stat timeout mktemp printf jq; do
  p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$BING/$b"
done
git init -q "$MONO4" >/dev/null 2>&1
mkdir -p "$MONO4/pkgs/app" "$MONO4/docs/looptesting/runs"
arm "$MONO4"; write_state "$MONO4" RUNNING 1
gerr=$( cd "$MONO4/pkgs/app" && printf '{"stop_hook_active": false}' | CLAUDE_PROJECT_DIR="$MONO4/pkgs/app" env PATH="$BING" bash "$STOP" 2>&1 >/dev/null ); grc=$?
assert_rc "$grc" 0 "no git on PATH: the walk-up is skipped, not attempted (legacy allow)"
assert_eq "" "$gerr" "no git on PATH produces no error output"

# HH. The anchor states are TWO, not one (delta review D1). "No anchor supplied"
#     and "an anchor was supplied and would not resolve" are different facts, and
#     the first repair of F3 gated the walk-up on a single flag that could not
#     tell them apart — so a session with no $CLAUDE_PROJECT_DIR and no "cwd"
#     key, the documented legacy path, stopped reaching the toplevel evidence
#     dir at all and K-14 was undone for it. Nothing caught that because every
#     case here sets the anchor, and run_stop's own payload carries no cwd but
#     always runs from a workspace root that already holds docs/looptesting.
MONO5=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-mono.XXXXXX"); track_ws "$MONO5"
git init -q "$MONO5" >/dev/null 2>&1
mkdir -p "$MONO5/pkgs/app" "$MONO5/docs/looptesting/runs"
arm "$MONO5"; write_state "$MONO5" RUNNING 1
if [ ! -d "$MONO5/pkgs/app/docs/looptesting" ] \
   && [ "$( cd "$MONO5/pkgs/app" && git rev-parse --show-toplevel 2>/dev/null )" = "$( cd "$MONO5" && pwd -P )" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); echo "  FAIL: fixture: subpackage must be evidence-free and inside the repo THIS case created" >&2
fi
( cd "$MONO5/pkgs/app" && printf '{"stop_hook_active": false}' | env -u CLAUDE_PROJECT_DIR bash "$STOP" ) >/dev/null 2>&1
assert_rc $? 2 "no anchor supplied at all: the walk-up still reaches the toplevel and blocks (D1)"

# II. The other half, and the one F3 was about: an anchor WAS supplied and did
#     not resolve. The fallback is "stay in cwd (legacy)", and the walk-up must
#     not turn that into authority over whatever repo the inherited cwd happens
#     to sit in — this gate removes .active and .gate-count.
MONO6=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-mono.XXXXXX"); track_ws "$MONO6"
git init -q "$MONO6" >/dev/null 2>&1
mkdir -p "$MONO6/pkgs/app" "$MONO6/docs/looptesting/runs"
arm "$MONO6"; write_state "$MONO6" RUNNING 1
( cd "$MONO6/pkgs/app" && printf '{"stop_hook_active": false}' | CLAUDE_PROJECT_DIR="$MONO6/no-such-dir-here" bash "$STOP" ) >/dev/null 2>&1
assert_rc $? 0 "an anchor that was supplied and did not resolve gains no authority (F3)"
assert_exists "$MONO6/docs/looptesting/.active" "…and the sentinel of the repo it was standing in is untouched"

report "stop-gate.test.sh"
