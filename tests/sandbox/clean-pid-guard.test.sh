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
make_wrapper() { # dir
  cat > "$1/run-clean.sh" <<'EOS'
#!/usr/bin/env bash
repo="$1"; clean="$2"; out="$3"
sleep 20 & echo "$!" > "$out/sentinel.pid"
cd "$repo" || exit 9
bash "$clean" > "$out/clean.out" 2>&1
echo "rc=$?" > "$out/rc.txt"
EOS
  chmod +x "$1/run-clean.sh"
}

run_clean_isolated() { # repo out_dir pids_content
  local repo="$1" out="$2" pids="$3" wrapper
  rm -f "$out/rc.txt" "$out/clean.out" "$out/sentinel.pid"
  printf '%s\n' "$pids" > "$repo/docs/looptesting/.pids"
  make_wrapper "$out"
  set -m
  "$out/run-clean.sh" "$repo" "$CLEAN" "$out" >/dev/null 2>&1 &
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

report "clean-pid-guard.test.sh"
