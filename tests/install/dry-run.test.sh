#!/usr/bin/env bash
# --dry-run makes ZERO filesystem writes for both install and uninstall.
source "$(dirname "$0")/lib.sh"

sandbox="$(make_sandbox)"
trap 'rm -rf "$sandbox"' EXIT

dest="$sandbox/loop-testing"

# Dry-run install: no dir created, output announces dry-run.
out="$(bash "$INSTALLER" --target "$sandbox" --dry-run 2>&1)"; rc=$?
assert_eq "$rc" "0" "dry-run install exit 0"
assert_no_path "$dest" "dry-run install wrote nothing"
assert_contains "$out" "dry-run" "output marked as dry-run"

# Dry-run uninstall against a real install: install stays intact.
bash "$INSTALLER" --target "$sandbox" >/dev/null 2>&1
out="$(bash "$INSTALLER" --uninstall --target "$sandbox" --dry-run 2>&1)"; rc=$?
assert_eq "$rc" "0" "dry-run uninstall exit 0"
assert_path "$dest/SKILL.md" "dry-run uninstall removed nothing"

finish
