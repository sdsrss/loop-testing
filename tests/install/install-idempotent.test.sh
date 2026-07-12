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

finish
