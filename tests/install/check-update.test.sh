#!/usr/bin/env bash
# check-update.test.sh: `--check-update` notify-only version check. NO real network —
# the latest version is injected via LOOP_TESTING_UPDATE_SELFTEST_LATEST. Runs
# entirely in a --target sandbox; never touches the real ~/.codex.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SB=$(make_sandbox); trap 'rm -rf "$SB"' EXIT
bash "$INSTALLER" --target "$SB" >/dev/null 2>&1
DEST="$SB/loop-testing"
cur=$(grep -E '^version=' "$DEST/.loop-testing-codex-install" | head -1 | cut -d= -f2-)

# 1. A newer latest version -> "update available: <cur> -> <latest>", exit 0.
out=$(LOOP_TESTING_UPDATE_SELFTEST_LATEST=9.9.9 bash "$INSTALLER" --target "$SB" --check-update 2>&1); rc=$?
assert_eq "$rc" 0 "check-update exits 0 when an update exists"
assert_contains "$out" "update available: $cur -> 9.9.9" "reports current -> latest"
assert_contains "$out" "install-codex.sh" "tells the user how to refresh the Codex copy"

# 2. latest == installed -> "up to date".
out=$(LOOP_TESTING_UPDATE_SELFTEST_LATEST="$cur" bash "$INSTALLER" --target "$SB" --check-update 2>&1)
assert_contains "$out" "up to date" "reports up to date when latest == installed"

# 3. A lower latest than installed -> up to date (never downgrade-nag).
out=$(LOOP_TESTING_UPDATE_SELFTEST_LATEST=0.0.1 bash "$INSTALLER" --target "$SB" --check-update 2>&1)
assert_contains "$out" "up to date" "installed ahead of latest -> up to date"

# 4. No install at the target -> error, nonzero exit.
SB2=$(make_sandbox); trap 'rm -rf "$SB" "$SB2"' EXIT
out=$(LOOP_TESTING_UPDATE_SELFTEST_LATEST=9.9.9 bash "$INSTALLER" --target "$SB2" --check-update 2>&1); rc=$?
assert_ne "$rc" 0 "check-update on a target with no install -> nonzero"
assert_contains "$out" "no loop-testing install" "explains there is nothing installed"

# 5. Offline / unreachable GitHub (real-curl branch, no SELFTEST override) -> graceful
#    degrade: exit 0 with the "could not reach" message, NOT a bare set -e hard-fail.
out=$(LOOP_TESTING_UPDATE_TAGS_URL="https://127.0.0.1:1/nope" LOOP_TESTING_UPDATE_TIMEOUT=2 \
  bash "$INSTALLER" --target "$SB" --check-update 2>&1); rc=$?
assert_eq "$rc" 0 "check-update degrades to exit 0 when GitHub is unreachable"
assert_contains "$out" "could not reach GitHub" "prints the offline/rate-limited notice"
assert_contains "$out" "Installed: $cur" "still reports the installed version when offline"

finish
