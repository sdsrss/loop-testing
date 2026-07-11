#!/usr/bin/env bash
# --uninstall removes only our own install and is fail-closed against foreign dirs.
source "$(dirname "$0")/lib.sh"

sandbox="$(make_sandbox)"
trap 'rm -rf "$sandbox"' EXIT

dest="$sandbox/loop-testing"

# Case 1: uninstall our own install -> removed, exit 0.
bash "$INSTALLER" --target "$sandbox" >/dev/null 2>&1
assert_path "$dest/SKILL.md" "installed before uninstall"
bash "$INSTALLER" --uninstall --target "$sandbox" >/dev/null 2>&1
assert_eq "$?" "0" "uninstall exit 0"
assert_no_path "$dest" "our install removed"

# Case 2: fail-closed — a foreign dir at the target path is NEVER deleted.
mkdir -p "$dest"
echo "someone else's file" > "$dest/important.txt"   # no install marker
out="$(bash "$INSTALLER" --uninstall --target "$sandbox" 2>&1)"; rc=$?
assert_ne "$rc" "0" "uninstall refuses foreign dir (non-zero exit)"
assert_path "$dest/important.txt" "foreign dir left intact"
assert_contains "$out" "marker" "explains the fail-closed reason"

finish
