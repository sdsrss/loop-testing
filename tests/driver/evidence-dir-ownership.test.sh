#!/usr/bin/env bash
# A headless run must leave docs/looptesting purgeable (audit D-03).
#
# The drivers create docs/looptesting themselves — for driver.log and the
# concurrency lock — before the first session runs sandbox-setup.sh. Setup then
# found the directory already present on a fresh start, recorded it as the
# user's (CREATED_LOOPTESTING_DIR=false), and `sandbox-clean.sh --purge` kept
# it forever, telling the user it "holds files that were already yours". After
# every unattended run, the evidence dir the tool made was unremovable by the
# tool's own purge.
#
# Setup already honors a `.sandbox/created-dirs.env` breadcrumb as the highest
# authority on who made the directory and never overwrites one. The driver is
# the process that knows, so it writes the breadcrumb when it is the one that
# created the directory — and only then: a directory that was there before the
# driver started stays the user's.
#
# SAFETY: mktemp git repo (tests/sandbox/lib.sh), stub agent whose "round 0"
# runs the real sandbox-setup.sh inside the fixture, --no-protect on codex.
set -u
. "$(cd "$(dirname "$0")" && pwd)/../sandbox/lib.sh"
DRIVER="$REPO_ROOT/skills/loop-testing/scripts/unattended-loop.sh"
CODEX_DRIVER="$REPO_ROOT/skills/loop-testing/scripts/unattended-codex.sh"

WS_ALL=""
cleanup_all() { [ -n "$WS_ALL" ] && rm -rf $WS_ALL; return 0; }   # word-split on purpose
trap cleanup_all EXIT

# The agent's round 0, then a terminal STATE so the driver exits 0 after one session.
write_setup_stub() { # ws -> path
  local stub="$1/agent-stub.sh"
  cat > "$stub" <<STUB
#!/usr/bin/env bash
set -u
bash "$SETUP" --mode worktree >/dev/null 2>&1 || { echo "stub: sandbox-setup failed: \$?" >&2; exit 1; }
printf '# STATE\nround: 1\nconverged_streak: 2\nstatus: CONVERGED\nmax_rounds: 12\n' > docs/looptesting/STATE.md
STUB
  chmod +x "$stub"; echo "$stub"
}

run_driver() { # kind proj stub
  case "$1" in
    codex) bash "$CODEX_DRIVER" --project "$2" --codex-bin "$3" --no-protect --max-sessions 2 ;;
    *)     bash "$DRIVER"       --project "$2" --claude-bin "$3" --max-sessions 2 ;;
  esac
}

for kind in claude codex; do
  # --- 1. fresh project: the driver makes docs/looptesting -> purge removes it ---
  ws=$(mk_ws); WS_ALL="$WS_ALL $ws"; proj="$ws/proj"
  stub=$(write_setup_stub "$ws")
  assert_absent "$proj/docs/looptesting" "$kind: fixture starts without an evidence dir"
  run_driver "$kind" "$proj" "$stub" >/dev/null 2>&1
  assert_eq 0 "$?" "$kind: headless run converges (exit 0)"
  assert_file_contains "$proj/docs/looptesting/.sandbox/created-dirs.env" "MADE_LOOPTESTING_DIR=1" \
    "$kind: the driver records that it created the evidence dir"
  assert_file_contains "$proj/docs/looptesting/.sandbox/ownership.env" "CREATED_LOOPTESTING_DIR=true" \
    "$kind: setup carries the driver's answer into the ownership marker"
  ( cd "$proj" && bash "$CLEAN" --purge ) > "$ws/purge.out" 2>&1
  assert_eq 0 "$?" "$kind: purge after the headless run exits 0"
  assert_absent "$proj/docs/looptesting" "$kind: purge removes the evidence dir the driver created"
  if grep -qF "already yours" "$ws/purge.out"; then
    FAIL=$((FAIL+1)); echo "  FAIL: $kind: purge told the user the tool's own dir held their files" >&2
  else PASS=$((PASS+1)); fi

  # --- 2. mutation guard: a dir the USER had before the driver stays theirs ------
  ws2=$(mk_ws); WS_ALL="$WS_ALL $ws2"; proj2="$ws2/proj"
  stub2=$(write_setup_stub "$ws2")
  mkdir -p "$proj2/docs/looptesting"
  echo "user ADR" > "$proj2/docs/looptesting/adr-1.md"
  run_driver "$kind" "$proj2" "$stub2" >/dev/null 2>&1
  assert_eq 0 "$?" "$kind: headless run over a user-owned evidence dir converges"
  assert_file_contains "$proj2/docs/looptesting/.sandbox/ownership.env" "CREATED_LOOPTESTING_DIR=false" \
    "$kind: a pre-existing dir is still recorded as the user's"
  ( cd "$proj2" && bash "$CLEAN" --purge ) >/dev/null 2>&1
  assert_eq 0 "$?" "$kind: purge over the user's dir exits 0"
  assert_exists "$proj2/docs/looptesting/adr-1.md" "$kind: the user's file survives purge"

  # --- 3. the driver never overwrites an existing breadcrumb ---------------------
  ws3=$(mk_ws); WS_ALL="$WS_ALL $ws3"; proj3="$ws3/proj"
  stub3=$(write_setup_stub "$ws3")
  mkdir -p "$proj3/docs/looptesting/.sandbox"
  printf 'MADE_LOOPTESTING_DIR=0\n' > "$proj3/docs/looptesting/.sandbox/created-dirs.env"
  run_driver "$kind" "$proj3" "$stub3" >/dev/null 2>&1
  assert_eq 0 "$?" "$kind: headless run over an existing breadcrumb converges"
  assert_file_contains "$proj3/docs/looptesting/.sandbox/created-dirs.env" "MADE_LOOPTESTING_DIR=0" \
    "$kind: an earlier lifecycle's breadcrumb is left as written"
done

report "evidence-dir-ownership.test.sh"
