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

WS_ALL=()
track_ws() { WS_ALL+=("$1"); }
cleanup_all() { if [ "${#WS_ALL[@]}" -gt 0 ]; then rm -rf -- "${WS_ALL[@]}"; fi; return 0; }
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
  ws=$(mk_ws); track_ws "$ws"; proj="$ws/proj"
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
  ws2=$(mk_ws); track_ws "$ws2"; proj2="$ws2/proj"
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

  # --- 3b. a file the user put in the dir the DRIVER created survives purge -----
  # Owning the DIRECTORY is not owning everything later put inside it. Making a
  # headless run's evidence dir purgeable at all (case 1) turns this branch into
  # `rm -rf` over exactly that case, and an untracked file is gone for good.
  ws3b=$(mk_ws); track_ws "$ws3b"; proj3b="$ws3b/proj"
  stub3b=$(write_setup_stub "$ws3b")
  run_driver "$kind" "$proj3b" "$stub3b" >/dev/null 2>&1
  assert_eq 0 "$?" "$kind: headless run converges before the user adds a file"
  echo "notes I archived here after the run" > "$proj3b/docs/looptesting/my-notes.md"
  ( cd "$proj3b" && bash "$CLEAN" --purge ) > "$ws3b/purge.out" 2>&1
  assert_eq 0 "$?" "$kind: purge over a dir holding a stranger exits 0"
  assert_exists "$proj3b/docs/looptesting/my-notes.md" "$kind: a file the sandbox never wrote survives purge"
  assert_absent "$proj3b/docs/looptesting/ISSUES.md" "$kind: the sandbox's own files are still removed"
  assert_absent "$proj3b/docs/looptesting/runs" "$kind: the sandbox's own directories are still removed"
  assert_file_contains "$ws3b/purge.out" "my-notes.md" "$kind: purge names the file it kept"
  # Cross-branch interaction: keeping the directory must keep the two files this
  # script needs to run again — the ownership marker (the only record that can
  # identify the sandbox's worktree and refs) and STATE.md (the terminal-status
  # precondition). Deleting either here would send the NEXT --purge into the
  # fail-closed exit 3 with residue still on disk and no tool route to finish.
  assert_exists "$proj3b/docs/looptesting/.sandbox/ownership.env" "$kind: the ownership marker is kept with the strangers"
  assert_exists "$proj3b/docs/looptesting/STATE.md" "$kind: STATE.md is kept with the strangers"
  ( cd "$proj3b" && bash "$CLEAN" --purge ) > "$ws3b/purge2.out" 2>&1
  assert_eq 0 "$?" "$kind: a SECOND purge still has a marker to work from (exit 0, not the fail-closed 3)"
  assert_exists "$proj3b/docs/looptesting/my-notes.md" "$kind: the second purge still keeps the user's file"

  # --- 3c. a DANGLING SYMLINK is a leftover too ---------------------------------
  # `[ -e ]` is false for a link whose target is gone, so a scan built on it reads
  # the directory as empty, deletes the marker and STATE.md, and only then fails
  # to rmdir — stranding the next purge on the no-marker exit 3 with residue still
  # there. An agent that linked into a worktree `clean` later removed leaves
  # exactly this.
  ws3c=$(mk_ws); track_ws "$ws3c"; proj3c="$ws3c/proj"
  stub3c=$(write_setup_stub "$ws3c")
  run_driver "$kind" "$proj3c" "$stub3c" >/dev/null 2>&1
  assert_eq 0 "$?" "$kind: headless run converges before the dangling link appears"
  ln -s "$ws3c/gone-with-the-worktree" "$proj3c/docs/looptesting/into-the-worktree"
  [ -L "$proj3c/docs/looptesting/into-the-worktree" ] && [ ! -e "$proj3c/docs/looptesting/into-the-worktree" ] \
    && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: $kind: fixture link is not dangling" >&2; }
  ( cd "$proj3c" && bash "$CLEAN" --purge ) > "$ws3c/purge.out" 2>&1
  assert_eq 0 "$?" "$kind: purge over a dangling link exits 0"
  assert_exists "$proj3c/docs/looptesting/.sandbox/ownership.env" "$kind: a dangling link keeps the marker too"
  assert_exists "$proj3c/docs/looptesting/STATE.md" "$kind: a dangling link keeps STATE.md too"
  assert_file_contains "$ws3c/purge.out" "into-the-worktree" "$kind: purge names the dangling link it kept"
  ( cd "$proj3c" && bash "$CLEAN" --purge ) > "$ws3c/purge2.out" 2>&1
  assert_eq 0 "$?" "$kind: a second purge after a dangling link still works (exit 0, not 3)"

  # --- 3. the driver never overwrites an existing breadcrumb ---------------------
  ws3=$(mk_ws); track_ws "$ws3"; proj3="$ws3/proj"
  stub3=$(write_setup_stub "$ws3")
  mkdir -p "$proj3/docs/looptesting/.sandbox"
  printf 'MADE_LOOPTESTING_DIR=0\n' > "$proj3/docs/looptesting/.sandbox/created-dirs.env"
  run_driver "$kind" "$proj3" "$stub3" >/dev/null 2>&1
  assert_eq 0 "$?" "$kind: headless run over an existing breadcrumb converges"
  assert_file_contains "$proj3/docs/looptesting/.sandbox/created-dirs.env" "MADE_LOOPTESTING_DIR=0" \
    "$kind: an earlier lifecycle's breadcrumb is left as written"
done

# --- the full sequence a file was lost in -------------------------------------
# A run aborts before it ever reaches sandbox-setup.sh (the driver has already
# created docs/looptesting and written its breadcrumb), the user drops a file in
# that directory, a later run completes normally, and the user purges. The
# breadcrumb correctly says the DIRECTORY is the tool's; the file in it is not.
ws5=$(mk_ws); track_ws "$ws5"; proj5="$ws5/proj"
printf '#!/usr/bin/env bash\nexit 1\n' > "$ws5/dead-stub.sh"   # dies before setup
chmod +x "$ws5/dead-stub.sh"
bash "$DRIVER" --project "$proj5" --claude-bin "$ws5/dead-stub.sh" --max-sessions 2 >/dev/null 2>&1
assert_file_contains "$proj5/docs/looptesting/.sandbox/created-dirs.env" "MADE_LOOPTESTING_DIR=1" \
  "the aborted run still recorded that the driver created the dir"
echo "a file the user added between runs" > "$proj5/docs/looptesting/my-notes.md"
stub5=$(write_setup_stub "$ws5")
bash "$DRIVER" --project "$proj5" --claude-bin "$stub5" --max-sessions 2 >/dev/null 2>&1
assert_eq 0 "$?" "the completing run converges"
( cd "$proj5" && bash "$CLEAN" --purge ) > "$ws5/purge.out" 2>&1
assert_eq 0 "$?" "purge after the abort-then-complete sequence exits 0"
assert_exists "$proj5/docs/looptesting/my-notes.md" "the file added between the two runs survives the purge"
assert_absent "$proj5/docs/looptesting/driver.log" "the driver's own log is still removed"

report "evidence-dir-ownership.test.sh"
