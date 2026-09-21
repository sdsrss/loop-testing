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

# --- no --target, no CODEX_HOME, no HOME: say what to do, do not crash --------
# The default destination is `$HOME/.codex/skills`, read bare under
# `set -euo pipefail`. Run from cron, a systemd unit without `User=`, or `env -i`
# — the same environments that break the sandbox teardown in audit S-05 — the
# installer ended on `HOME: unbound variable`, a bash diagnostic naming a shell
# variable rather than the two flags that fix it.
out2="$(env -u HOME -u CODEX_HOME bash "$INSTALLER" 2>&1)"; rc2=$?
assert_ne "$rc2" "0" "no target, no CODEX_HOME and no HOME must not succeed"
if printf '%s' "$out2" | grep -q 'unbound variable'; then
  fail "the installer died on an unbound variable instead of explaining — got: $out2"
else pass "the installer does not die on a bash unbound-variable error"; fi
assert_contains "$out2" "--target" "the refusal names the flag that fixes it"
assert_contains "$out2" "CODEX_HOME" "and the variable that also fixes it"
# Control: with HOME set, the default destination still resolves — the fix must
# not be "always refuse when --target is absent".
home2="$(make_sandbox)"
out3="$(env -u CODEX_HOME HOME="$home2" bash "$INSTALLER" 2>&1)"; rc3=$?
assert_eq "$rc3" "0" "with HOME set the default destination still installs"
assert_path "$home2/.codex/skills/loop-testing/SKILL.md" "and it lands under \$HOME/.codex/skills"
rm -rf "$home2"

finish
