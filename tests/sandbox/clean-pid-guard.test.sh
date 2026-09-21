#!/usr/bin/env bash
# sandbox-clean.sh must never signal PID 0 or PID 1 because a line in .pids said
# so. `kill 0` signals EVERY process in the sender's own process group — the agent
# session, the unattended driver, sibling jobs — so clean would take down the run
# it is cleaning up after, mid-cleanup, and never reach the worktree removal.
# PID 1 is init. Neither can ever be a service this run started.
#
# This is not hypothetical input: .pids is written by the LLM agent from parsed
# `lsof -t -i :PORT` / `ss -ltnp` output (references/round-0.md, loop-round.md),
# which is exactly where a stray "0" comes from.
#
# The guard must compare the PID's VALUE, not its shape: "0" and "00" are both
# numeric and both mean the process group, while "0000123" is a real PID 123 that
# must still be stopped — so a shape-only filter is not enough in either direction.
#
# SAFETY: clean runs inside its OWN process group. `set -m` (monitor mode) puts a
# background job in a fresh process group on bash 3.2 too, so no setsid is needed
# and macOS behaves the same. If the guard ever regresses, the blast radius is the
# throwaway wrapper — not this test runner.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WS_ALL=""
cleanup_all() { [ -n "$WS_ALL" ] && rm -rf $WS_ALL; }   # word-split on purpose
trap cleanup_all EXIT

# Sets NEW_REPO (a fresh repo with a sandbox already set up) rather than echoing
# it: the caller would have to use $( ), and a command substitution runs in a
# subshell, so the WS_ALL registration would be discarded and the EXIT trap would
# clean nothing — every fixture would leak into $TMPDIR.
NEW_REPO=""
new_repo() {
  local ws
  ws=$(mk_ws) || return 1
  WS_ALL="$WS_ALL $ws"
  ( cd "$ws/proj" && bash "$SETUP" --mode worktree ) >/dev/null 2>&1 || return 1
  NEW_REPO="$ws/proj"
}

# The wrapper runs in its own process group, starts a sentinel sibling *in that
# group*, then runs clean. rc.txt is written only if clean RETURNS — a `kill 0`
# from clean kills the wrapper and the sentinel together, so both the missing
# rc.txt and the dead sentinel are direct evidence of the blast radius.
# A 4th argument of `self` makes the wrapper record its OWN pid in .pids — the
# only way to build a .pids entry that is genuinely an ancestor of the clean
# process, which no value computed out here could be.
make_wrapper() { # dir
  cat > "$1/run-clean.sh" <<'EOS'
#!/usr/bin/env bash
repo="$1"; clean="$2"; out="$3"; mode="${4:-}"
sleep 20 & echo "$!" > "$out/sentinel.pid"
cd "$repo" || exit 9
echo "$$" > "$out/wrapper.pid"
case "$mode" in
  self|self2) echo "$$" > "$repo/docs/looptesting/.pids" ;;
esac
if [ "$mode" = self2 ]; then
  # One more shell between the wrapper and clean, so the recorded PID is clean's
  # GRANDparent and only the ancestor walk can find it. The trailing `exit` stops
  # bash from exec-optimizing a lone command away, which would collapse the level
  # and silently turn this into the parent case; mid.pid is what proves it did not.
  bash -c 'echo $$ > "$2/mid.pid"; bash "$1" > "$2/clean.out" 2>&1; exit $?' _ "$clean" "$out"
else
  bash "$clean" > "$out/clean.out" 2>&1
fi
echo "rc=$?" > "$out/rc.txt"
EOS
  chmod +x "$1/run-clean.sh"
}

run_clean_isolated() { # repo out_dir pids_content [self]
  local repo="$1" out="$2" pids="$3" mode="${4:-}" wrapper
  rm -f "$out/rc.txt" "$out/clean.out" "$out/sentinel.pid" "$out/wrapper.pid" "$out/mid.pid"
  printf '%s\n' "$pids" > "$repo/docs/looptesting/.pids"
  make_wrapper "$out"
  set -m
  "$out/run-clean.sh" "$repo" "$CLEAN" "$out" "$mode" >/dev/null 2>&1 &
  wrapper=$!
  wait "$wrapper" 2>/dev/null
  set +m
}

assert_sentinel_alive() { # out_dir label
  local p
  p=$(cat "$1/sentinel.pid" 2>/dev/null)
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    PASS=$((PASS+1)); kill "$p" 2>/dev/null
  else
    FAIL=$((FAIL+1)); echo "  FAIL: $2 — a sibling job in clean's own process group was signalled" >&2
  fi
}

# --- case 1: a bare 0 ---------------------------------------------------------
new_repo; assert_ok $? "setup for the .pids=0 case"; REPO="$NEW_REPO"
OUT=$(dirname "$REPO")
run_clean_isolated "$REPO" "$OUT" "0"
assert_exists "$OUT/rc.txt" "clean returns instead of killing its own process group (.pids=0)"
assert_sentinel_alive "$OUT" ".pids=0"
assert_file_contains "$OUT/clean.out" "refusing to signal PID 0" "clean names the refused PID 0"
assert_absent "$(dirname "$REPO")/proj-qa-loop" "clean still completed its real work (.pids=0)"

# --- case 2: a zero-padded 0 ("00" is numeric and still means the group) -------
new_repo; assert_ok $? "setup for the .pids=00 case"; REPO="$NEW_REPO"
OUT=$(dirname "$REPO")
run_clean_isolated "$REPO" "$OUT" "00"
assert_exists "$OUT/rc.txt" "clean returns instead of killing its own process group (.pids=00)"
assert_sentinel_alive "$OUT" ".pids=00"
assert_file_contains "$OUT/clean.out" "refusing to signal PID 00" "clean names the refused PID 00"

# --- case 3: PID 1, alongside a zero-padded REAL pid that must still be stopped -
# The second line is the mutation guard: a fix that skipped every leading-zero PID
# would pass cases 1 and 2 and silently stop stopping real services.
new_repo; assert_ok $? "setup for the .pids=1 case"; REPO="$NEW_REPO"
OUT=$(dirname "$REPO")
sleep 20 & real_pid=$!
# Prefix zeros explicitly. `printf %07d` pads to a FIXED width, so on a host whose
# PIDs are already 7 digits (ordinary Linux) it adds nothing and this guard silently
# stops guarding — it must carry leading zeros on every host, whatever the PID size.
padded="000$real_pid"
run_clean_isolated "$REPO" "$OUT" "1
$padded"
assert_exists "$OUT/rc.txt" "clean returns with PID 1 recorded"
assert_file_contains "$OUT/clean.out" "refusing to signal PID 1" "clean names the refused PID 1"
if kill -0 "$real_pid" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "  FAIL: a zero-padded REAL pid ($padded) was skipped by the guard" >&2
  kill -9 "$real_pid" 2>/dev/null
else PASS=$((PASS+1)); fi
# Case 3 does not assert on the wrapper's own sentinel (cases 1-2 reap theirs inside
# assert_sentinel_alive), so reap it here — otherwise every run leaves a `sleep 20`
# orphan behind for 20 s (audit 2026-09-20 T-02).
_wp=$(cat "$OUT/sentinel.pid" 2>/dev/null); [ -n "$_wp" ] && kill "$_wp" 2>/dev/null

# --- case 4: a recorded PID that is clean's OWN ancestor (audit S-06) ---------
# The 0/1 guard above rejects two values. It does not reject the shape the same
# input channel actually produces: `lsof -t -i :PORT` / `ss -ltnp` report whoever
# holds the port, and that can be the agent session — or the unattended driver —
# that is running this very cleanup. A recycled PID arrives at the same place.
#
# The damage is not "one extra SIGTERM". collect_tree expands the recorded PID
# into its whole descendant tree, and clean is one of those descendants, so the
# target set contains clean's own PID: it signals itself and dies at that line,
# which is BEFORE the worktree removal and before `.active` is disarmed. The
# teardown stops halfway, the sandbox stays up, and the stop-gate keeps refusing
# to end the session — the failure that most looks like the tool hanging.
#
# Only the wrapper can produce this fixture: it writes its own $$ into .pids, so
# the recorded PID is genuinely clean's parent. The load-bearing assertion is the
# worktree one — a self-signalled clean never reaches it.
new_repo; assert_ok $? "setup for the .pids=<clean's own parent> case"; REPO="$NEW_REPO"
OUT=$(dirname "$REPO")
run_clean_isolated "$REPO" "$OUT" "" self
assert_absent "$(dirname "$REPO")/proj-qa-loop" "clean completed its real work with its own parent in .pids"
assert_exists "$OUT/rc.txt" "clean's parent survived to write the return code"
assert_file_contains "$OUT/clean.out" "refusing to signal PID" "clean names the refused ancestor PID"
assert_absent "$REPO/docs/looptesting/.active" "the stop-gate sentinel was still disarmed"
_wp=$(cat "$OUT/sentinel.pid" 2>/dev/null); [ -n "$_wp" ] && kill "$_wp" 2>/dev/null

# --- case 5: control — an unrelated recorded PID is still stopped -------------
# Case 4 passes for a "fix" that stops signalling anything at all. This one does
# not: a PID that is no relation to clean must still be terminated.
new_repo; assert_ok $? "setup for the unrelated-PID control"; REPO="$NEW_REPO"
OUT=$(dirname "$REPO")
sleep 20 & unrelated_pid=$!
run_clean_isolated "$REPO" "$OUT" "$unrelated_pid"
if kill -0 "$unrelated_pid" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "  FAIL: an unrelated recorded PID was left running" >&2
  kill -9 "$unrelated_pid" 2>/dev/null
else PASS=$((PASS+1)); fi
_wp=$(cat "$OUT/sentinel.pid" 2>/dev/null); [ -n "$_wp" ] && kill "$_wp" 2>/dev/null

# --- case 6: a GRANDparent, which only the ancestor walk can catch ------------
# Case 4 is satisfied by `$PPID` alone, so on its own it leaves the walk above it
# untested — and the real shape has depth: the unattended driver starts a session
# which runs the skill which runs clean, and it is the DRIVER's pid that `ss`
# reports for a port it opened. This case puts one extra shell in between and
# asserts the fixture really has two levels before asserting anything about the
# guard, so a collapsed intermediate cannot pass as coverage of the walk.
new_repo; assert_ok $? "setup for the .pids=<clean's grandparent> case"; REPO="$NEW_REPO"
OUT=$(dirname "$REPO")
run_clean_isolated "$REPO" "$OUT" "" self2
_w6=$(cat "$OUT/wrapper.pid" 2>/dev/null); _m6=$(cat "$OUT/mid.pid" 2>/dev/null)
if [ -n "$_w6" ] && [ -n "$_m6" ] && [ "$_w6" != "$_m6" ]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: fixture — the intermediate shell collapsed, so this case never reached the ancestor walk" >&2; fi
assert_absent "$(dirname "$REPO")/proj-qa-loop" "clean completed its real work with its own grandparent in .pids"
assert_file_contains "$OUT/clean.out" "refusing to signal PID" "clean names the refused grandparent PID"
_wp=$(cat "$OUT/sentinel.pid" 2>/dev/null); [ -n "$_wp" ] && kill "$_wp" 2>/dev/null

# --- case 7: a chain this run could not finish walking is fail-closed --------
# Cases 4 and 6 cover a walk that WORKS. This covers the one that cannot: the
# loop's exit condition — `case "$_spp" in ''|*[!0-9]*) break` — could not tell
# "reached the top of the process tree" from "ps could not answer", and on the
# second reading the chain silently truncated. Every ancestor above the
# truncation then became a legal signal target, while pgrep still expanded a
# recorded PID into a tree containing this cleanup.
#
# A healthy walk never takes that arm (`ps -o ppid= -p 1` prints 0, so it exits
# through the `-gt 1` test), which is why nothing noticed.
new_repo; assert_ok $? "setup for the truncated-ancestry case"; REPO="$NEW_REPO"
OUT=$(dirname "$REPO")
# The two probes the walk has, both made unable to answer: a ps that fails only
# `-o ppid=` (and still delegates everything else, so this is a shim and not a
# brick), and a procfs pointed somewhere that does not exist.
mkdir -p "$OUT/shim7"
REAL_PS7="$(command -v ps)"
printf '#!/usr/bin/env bash\ncase " $* " in *" -o ppid= "*) exit 1 ;; esac\nexec %s "$@"\n' \
  "$REAL_PS7" > "$OUT/shim7/ps"
chmod +x "$OUT/shim7/ps"
PATH="$OUT/shim7:$PATH" ps >/dev/null 2>&1
assert_ok $? "fixture: the ps shim delegates everything except -o ppid="
PATH="$OUT/shim7:$PATH" ps -o ppid= -p "$$" >/dev/null 2>&1
ps7rc=$?
if [ "$ps7rc" -ne 0 ]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1))
  echo "  FAIL: fixture: the ps shim did not fail -o ppid=, so case 7 would test nothing" >&2
fi
sleep 20 & victim7=$!
OLD_PATH7="$PATH"
PATH="$OUT/shim7:$PATH"; export PATH
LOOP_TESTING_PROCFS="$OUT/nonexistent-procfs"; export LOOP_TESTING_PROCFS
run_clean_isolated "$REPO" "$OUT" "$victim7"
PATH="$OLD_PATH7"; export PATH; unset LOOP_TESTING_PROCFS
assert_file_contains "$OUT/clean.out" "could not walk its own ancestry" \
  "clean says why it skipped the .pids stage instead of signalling blind"
# Fail-closed means the recorded PID survives. That is the deliberate cost: this
# run cannot prove it is not one of its own ancestors, and stopping the teardown
# before the worktree is removed is the worse outcome.
if kill -0 "$victim7" 2>/dev/null; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: a recorded PID was signalled through a chain that could not be walked" >&2
fi
# Reaped inside the block: job control announces "Killed" on the shell's stderr
# at reap time, and the runner reads suite stderr.
{ kill -9 "$victim7"; wait "$victim7"; } >/dev/null 2>&1
# The ledger has to survive too, or the record of services nobody stopped is
# thrown away by the run that declined to stop them.
if [ -s "$REPO/docs/looptesting/.pids" ]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: .pids was cleared after a stage that deliberately did nothing" >&2
fi
assert_absent "$(dirname "$REPO")/proj-qa-loop" "and clean still completed its real work"
_wp=$(cat "$OUT/sentinel.pid" 2>/dev/null); [ -n "$_wp" ] && kill "$_wp" 2>/dev/null

report "clean-pid-guard.test.sh"
