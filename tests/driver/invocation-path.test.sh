#!/usr/bin/env bash
# How the driver is INVOKED must not change which plugin its sessions load.
#
# 24b773a's resolver taught every entry point to find lib.sh through a symlink and
# under CDPATH, and left the driver's own SCRIPT_DIR on the old
# `cd "$(dirname "$0")"` idiom. The default --plugin-dir is built from SCRIPT_DIR,
# so the two invocations the resolver was written for got PAST the lib.sh gate and
# then started full-permission sessions with the wrong plugin dir — measured:
#
#   symlink in ~/bin   plugin_dir=/          (the link's dir, ../../.. of it)
#   CDPATH=.           plugin_dir=           (cd echoed into the substitution)
#
# Either way the plugin's hooks (stop-gate, ledger-gate) are never loaded, where
# 0.17.0 refused to start at all. Asserted against driver.log's start line, which
# records the plugin_dir every session is handed.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"   # REPO_ROOT, DRIVER, write_stub, asserts, report

# PHYSICAL root: the driver resolves symlinks (cd -P), so a checkout reached
# through a link would otherwise fail the direct control too.
WANT="plugin_dir=$(cd -P "$REPO_ROOT" && pwd) bin="
LINKS=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-invoke.XXXXXX") || exit 1
trap 'rm -rf "$LINKS"' EXIT

run_case() { # label, then the command words that launch the driver (cwd given in $CWD)
  local label="$1" ws stub log; shift
  ws=$(mk_proj) || { FAIL=$((FAIL+1)); echo "  FAIL: $label — mk_proj" >&2; return; }
  write_state "$ws" RUNNING 0
  stub=$(write_stub "$ws")
  ( cd "$CWD" && STUB_CONVERGE_AT=1 "$@" --project "$ws" --claude-bin "$stub" \
      --max-sessions 1 --no-watchdog ) >/dev/null 2>&1
  log="$ws/docs/looptesting/driver.log"
  # Premise: the driver got as far as its start line. Without it, the plugin_dir
  # assertion below would fail for a reason that is not the one it names.
  assert_file_contains "$log" "driver start:" "$label — driver reached its start line"
  assert_file_contains "$log" "$WANT" "$label — sessions get the plugin root as --plugin-dir"
  rm -rf "${ws:?}"
}

# Positive control: the direct call, which has always worked.
CWD="$REPO_ROOT" run_case "direct" bash "$DRIVER"

# Absolute symlink, the ~/bin shape.
mkdir -p "$LINKS/bin"
ln -s "$DRIVER" "$LINKS/bin/unattended-loop.sh"
CWD="$REPO_ROOT" run_case "absolute symlink" bash "$LINKS/bin/unattended-loop.sh"

# Relative symlink chain through a directory with a space in it, invoked as
# `c/drv.sh` from $LINKS. Both halves are load-bearing: a dirname of `c` (not
# `.`) is what makes the in-loop `cd` consult CDPATH, and a cwd OTHER than the
# link's dir is what makes the relative target `../a b/drv.sh` resolve wrongly
# unless the resolver anchors it to the link's directory.
mkdir -p "$LINKS/a b" "$LINKS/c"
ln -s "$DRIVER" "$LINKS/a b/drv.sh"
ln -s "../a b/drv.sh" "$LINKS/c/drv.sh"
CWD="$LINKS" CDPATH=. run_case "relative chain, CDPATH=." bash c/drv.sh

# CDPATH=. with a bare-relative path — the only invocation that consults it.
CWD="$REPO_ROOT/skills/loop-testing" CDPATH=. run_case "CDPATH=. bare-relative" \
  bash scripts/unattended-loop.sh

report "invocation-path.test.sh"
