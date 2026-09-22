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

# --- ...and the paths the USER hands it are resolved where the user is ---------
# Relative --project under CDPATH=.: the driver's own `cd "$PROJECT"` consulted
# CDPATH and echoed into the substitution, so PROJECT held two lines and the
# sessions ran in a directory tree the driver had just invented.
# The project is one level INSIDE the workspace: the stray tree lands beside it,
# where the workspace cleanup reaches it, instead of in $TMPDIR itself.
ws=$(mk_proj); mkdir -p "$ws/sub/docs/looptesting"; write_state "$ws/sub" RUNNING 0; stub=$(write_stub "$ws")
( cd "$ws" && STUB_CONVERGE_AT=1 CDPATH=. bash "$DRIVER" --project sub \
    --claude-bin "$stub" --max-sessions 1 --no-watchdog ) >/dev/null 2>&1
assert_file_contains "$ws/sub/docs/looptesting/driver.log" "project=$(cd -P "$ws/sub" && pwd) " \
  "CDPATH=. relative --project: driver.log names the real project"
assert_file_contains "$ws/sub/docs/looptesting/STATE.md" "status: CONVERGED" \
  "CDPATH=. relative --project: the session ran in the real project"
rm -rf "${ws:?}"

# A relative --plugin-dir was passed through verbatim, and the sessions start
# after `cd "$PROJECT"` — so it named a directory under the PROJECT, not under
# where the user typed it. Nonexistent there, so no plugin and no hooks, under
# bypassPermissions. It must be resolved against the invocation cwd; and one
# that is not a directory is a usage error, not a session without hooks.
# The given dir must NOT be the default one, or a driver that ignored the flag
# would pass: the repo root is what it falls back to.
ws=$(mk_proj); mkdir -p "$ws/sub/docs/looptesting" "$ws/plug/.claude-plugin"
write_state "$ws/sub" RUNNING 0; stub=$(write_stub "$ws")
( cd "$ws" && STUB_CONVERGE_AT=1 bash "$DRIVER" --project sub \
    --plugin-dir plug --claude-bin "$stub" --max-sessions 1 --no-watchdog ) >/dev/null 2>&1
assert_file_contains "$ws/sub/docs/looptesting/driver.log" "plugin_dir=$(cd -P "$ws/plug" && pwd) bin=" \
  "relative --plugin-dir is resolved against the invocation cwd"
rm -rf "${ws:?}"
ws=$(mk_proj); write_state "$ws" RUNNING 0; stub=$(write_stub "$ws")
out=$( cd "$REPO_ROOT" && bash "$DRIVER" --project "$ws" --plugin-dir no-such-plugin-dir \
    --claude-bin "$stub" --max-sessions 1 --no-watchdog 2>&1 ); rc=$?
assert_eq 2 "$rc" "--plugin-dir that is not a directory is a usage error — output: $(printf '%s' "$out" | head -1)"
[ -e "$ws/docs/looptesting/driver.log" ] && { FAIL=$((FAIL+1)); echo "  FAIL: a bad --plugin-dir must be refused before any session starts" >&2; } || PASS=$((PASS+1))
rm -rf "${ws:?}"

# Relative --claude-bin, same mechanism: `command -v` passed in the invocation
# cwd, then every session exec'd it after `cd "$PROJECT"` and got "No such file",
# and the driver exited 5 NO_PROGRESS. A bare NAME stays a PATH lookup.
ws=$(mk_proj); mkdir -p "$ws/sub/docs/looptesting" "$ws/bin"; write_state "$ws/sub" RUNNING 0
stub=$(write_stub "$ws"); mv "$stub" "$ws/bin/claude"
( cd "$ws" && STUB_CONVERGE_AT=1 bash "$DRIVER" --project sub --claude-bin bin/claude \
    --max-sessions 2 --no-watchdog ) >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "relative --claude-bin: the session finds the binary (exit 0)"
assert_file_contains "$ws/sub/docs/looptesting/STATE.md" "status: CONVERGED" \
  "relative --claude-bin: the stub actually ran in the project"
rm -rf "${ws:?}"

# `lnk/../bin/claude`: the kernel and `command -v` resolve `..` through the
# link's TARGET; a logical `cd` resolves it textually. Two different files — a
# preflight that checked one and sessions that ran the other. The decoy sits at
# the textual path and fails loudly.
ws=$(mk_proj); mkdir -p "$ws/sub/docs/looptesting" "$ws/real/x" "$ws/real/bin" "$ws/bin"
write_state "$ws/sub" RUNNING 0; stub=$(write_stub "$ws"); mv "$stub" "$ws/real/bin/claude"
ln -s "$ws/real/x" "$ws/lnk"
printf '#!/usr/bin/env bash\n: > "%s/decoy-ran"; exit 1\n' "$ws" > "$ws/bin/claude"; chmod +x "$ws/bin/claude"
( cd "$ws" && STUB_CONVERGE_AT=1 bash "$DRIVER" --project sub --claude-bin lnk/../bin/claude \
    --max-sessions 2 --no-watchdog ) >/dev/null 2>&1
assert_file_contains "$ws/sub/docs/looptesting/STATE.md" "status: CONVERGED" \
  "--claude-bin lnk/../bin/claude runs the file the kernel resolves"
[ -e "$ws/decoy-ran" ] && { FAIL=$((FAIL+1)); echo "  FAIL: --claude-bin lnk/../bin/claude ran the textual path, not the kernel's" >&2; } || PASS=$((PASS+1))
rm -rf "${ws:?}"

# Same for --plugin-dir: the session's claude resolves `lnk/../plug` through the
# link's target, so the dir recorded (and checked) must be that one. BOTH sides
# must exist: when the textual path is missing, bash's logical `cd` silently
# retries physically and the case cannot tell the two resolutions apart.
ws=$(mk_proj); mkdir -p "$ws/sub/docs/looptesting" "$ws/real/x" "$ws/real/plug/.claude-plugin" "$ws/plug"
write_state "$ws/sub" RUNNING 0; stub=$(write_stub "$ws"); ln -s "$ws/real/x" "$ws/lnk"
( cd "$ws" && STUB_CONVERGE_AT=1 bash "$DRIVER" --project sub --plugin-dir lnk/../plug \
    --claude-bin "$stub" --max-sessions 1 --no-watchdog ) >/dev/null 2>&1
assert_file_contains "$ws/sub/docs/looptesting/driver.log" "plugin_dir=$(cd -P "$ws/real/plug" && pwd) bin=" \
  "--plugin-dir lnk/../plug names the directory the kernel resolves"
rm -rf "${ws:?}"

report "invocation-path.test.sh"
