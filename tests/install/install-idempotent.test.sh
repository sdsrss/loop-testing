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

finish
