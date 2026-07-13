#!/usr/bin/env bash
# Reinstalling is idempotent: the second run backs up the prior install to
# <dest>.bak and leaves a valid fresh install in place.
source "$(dirname "$0")/lib.sh"

sandbox="$(make_sandbox)"
trap 'rm -rf "$sandbox"' EXIT

dest="$sandbox/loop-testing"

bash "$INSTALLER" --target "$sandbox" >/dev/null 2>&1
assert_eq "$?" "0" "first install exit 0"
# Drop a sentinel to prove the backup captures the *previous* tree.
echo "prev" > "$dest/.prev-marker"

out="$(bash "$INSTALLER" --target "$sandbox" 2>&1)"; rc=$?
assert_eq "$rc" "0" "second install exit 0"
assert_path "$dest/SKILL.md"                    "fresh install present after reinstall"
assert_path "$dest.bak"                         "previous install backed up to .bak"
assert_path "$dest.bak/.prev-marker"            ".bak holds the previous tree"
assert_no_path "$dest/.prev-marker"             "fresh tree does not carry old sentinel"
assert_contains "$out" "backing up" "reinstall reports backup"

# --- atomicity: a failed (staged) copy leaves the existing install intact (C8) ---
sb2="$(make_sandbox)"
trap 'chmod u+w "$sb2" 2>/dev/null; rm -rf "$sandbox" "$sb2"' EXIT
d2="$sb2/loop-testing"
bash "$INSTALLER" --target "$sb2" >/dev/null 2>&1
assert_eq "$?" "0" "atomicity: baseline install ok"
chmod a-w "$sb2"                                   # staging copy under sb2 will now fail
bash "$INSTALLER" --target "$sb2" >/dev/null 2>&1; rc2=$?
chmod u+w "$sb2"
assert_ne "$rc2" "0" "atomicity: a failed copy exits non-zero"
assert_path "$d2/SKILL.md" "atomicity: existing install left intact after a failed reinstall"
assert_path "$d2/.loop-testing-codex-install" "atomicity: marker still present (DEST not left partial/unmarked)"
assert_no_path "$d2.bak" "atomicity: failed reinstall did not consume the install into .bak"
if [ -z "$(ls -d "$sb2"/loop-testing.staging.* 2>/dev/null)" ]; then
  pass "atomicity: no .staging residue left behind"
else fail "atomicity: staging dir residue remains"; fi

# --- signal safety: an interrupt mid-copy reaps the staging dir, DEST intact (#4) ---
sb3="$(make_sandbox)"; shim="$(make_sandbox)"
trap 'chmod u+w "$sb2" 2>/dev/null; rm -rf "$sandbox" "$sb2" "$sb3" "$shim"' EXIT
d3="$sb3/loop-testing"
bash "$INSTALLER" --target "$sb3" >/dev/null 2>&1
assert_eq "$?" "0" "signal: baseline install ok"

# Shim `cp` so the staged copy completes and THEN lingers, opening a window to
# signal the installer after the staging dir exists but before the final swap.
# Only `cp` is shimmed; every other coreutil resolves from the real PATH.
real_cp="$(command -v cp)"
cat > "$shim/cp" <<EOF
#!/usr/bin/env bash
"$real_cp" "\$@"
sleep 2
EOF
chmod +x "$shim/cp"

PATH="$shim:$PATH" bash "$INSTALLER" --target "$sb3" >/dev/null 2>&1 &
inst_pid=$!
sleep 0.5
kill -TERM "$inst_pid" 2>/dev/null   # single PID, not the group: the sleeping cp lives on
wait "$inst_pid" 2>/dev/null

assert_path "$d3/SKILL.md" "signal: existing install left intact after an interrupted reinstall"
assert_no_path "$d3.bak"   "signal: interrupt before swap did not create a .bak"
if [ -z "$(ls -d "$sb3"/loop-testing.staging.* 2>/dev/null)" ]; then
  pass "signal: no .staging residue after interrupt"
else fail "signal: staging dir residue remains after interrupt"; fi

# --- stale-orphan reap: a SIGKILL'd prior run's staging dir is reaped (IN-1) ---
# SIGKILL skips traps, leaving `loop-testing.staging.<pid>`; each run stages
# under its own $$, so before this fix no later run ever removed the orphan.
# The reap must be liveness-gated: a staging dir whose pid suffix is a LIVE
# process (a parallel install mid-flight) must not be touched.
sb4="$(make_sandbox)"
trap 'chmod u+w "$sb2" 2>/dev/null; rm -rf "$sandbox" "$sb2" "$sb3" "$shim" "$sb4"' EXIT
d4="$sb4/loop-testing"
dead_pid="$(bash -c 'echo $$')"                       # guaranteed-dead pid, no background job
mkdir -p "$sb4/loop-testing.staging.$dead_pid"
echo stale > "$sb4/loop-testing.staging.$dead_pid/SKILL.md"
mkdir -p "$sb4/loop-testing.staging.$$"               # live "owner" = this test process
bash "$INSTALLER" --target "$sb4" >/dev/null 2>&1
assert_eq "$?" "0" "reap: install over stale orphans exits 0"
assert_no_path "$sb4/loop-testing.staging.$dead_pid" "reap: dead-owner staging orphan reaped"
assert_path    "$sb4/loop-testing.staging.$$"        "reap: live-owner staging dir NOT touched"
assert_path    "$d4/SKILL.md"                        "reap: install itself completed normally"
rm -rf "$sb4/loop-testing.staging.$$"

# --- R58 (NEW-2): reinstall must NOT delete a foreign (marker-less) .bak ---
# do_uninstall already marker-gates the .bak removal; the reinstall path only
# checked the basename shape, so a user's own `loop-testing.bak` directory was
# silently deleted to make room for the rotation (same sibling-guard-miss class
# as CX-1). A foreign .bak must refuse the reinstall and be left untouched.
sb5="$(make_sandbox)"
trap 'chmod u+w "$sb2" 2>/dev/null; rm -rf "$sandbox" "$sb2" "$sb3" "$shim" "$sb4" "$sb5"' EXIT
d5="$sb5/loop-testing"
bash "$INSTALLER" --target "$sb5" >/dev/null 2>&1
assert_eq "$?" "0" "bak-guard: baseline install ok"
mkdir -p "$d5.bak"
echo "user data" > "$d5.bak/precious.txt"   # foreign dir: no installer marker
bash "$INSTALLER" --target "$sb5" >/dev/null 2>&1; rc5=$?
assert_ne "$rc5" "0" "bak-guard: reinstall over a foreign .bak exits non-zero (R58)"
assert_path "$d5.bak/precious.txt" "bak-guard: foreign .bak left untouched (R58)"
assert_path "$d5/SKILL.md" "bak-guard: existing install left intact (R58)"
assert_path "$d5/.loop-testing-codex-install" "bak-guard: existing install still marked (R58)"
if [ -z "$(ls -d "$sb5"/loop-testing.staging.* 2>/dev/null)" ]; then
  pass "bak-guard: no staging residue after the refusal"
else fail "bak-guard: staging dir residue remains"; fi

finish
