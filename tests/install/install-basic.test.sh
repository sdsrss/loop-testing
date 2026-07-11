#!/usr/bin/env bash
# Install lands the skill at <target>/loop-testing with SKILL.md + resource dirs,
# writes the marker, and does NOT copy hooks/.
source "$(dirname "$0")/lib.sh"

sandbox="$(make_sandbox)"
trap 'rm -rf "$sandbox"' EXIT

out="$(bash "$INSTALLER" --target "$sandbox" 2>&1)"; rc=$?
assert_eq "$rc" "0" "installer exit 0"

dest="$sandbox/loop-testing"
assert_path "$dest/SKILL.md"        "skill entry copied"
assert_path "$dest/references"      "references/ copied"
assert_path "$dest/scripts/moa.mjs" "scripts/moa.mjs copied"
assert_path "$dest/templates"       "templates/ copied"
assert_path "$dest/.loop-testing-codex-install" "install marker written"
assert_no_path "$dest/hooks"        "hooks/ must NOT be copied (Codex has no hook layer)"
assert_contains "$out" "SKILL.md present: yes" "verification hint printed"

finish
