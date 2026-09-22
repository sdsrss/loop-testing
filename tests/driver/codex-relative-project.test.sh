#!/usr/bin/env bash
# unattended-codex.sh must normalize a relative --project (audit D-02).
#
# The driver `cd`s into the project AND hands the same string to
# `codex exec -C <project>`, which Codex resolves against its new cwd. With
# `--project proj` that is `proj/proj`: every session failed before reading
# the prompt and the driver reported it as NO_PROGRESS exit 5 — the loop
# blamed for a path the driver itself had mangled. unattended-loop.sh already
# absolutized its --project; the codex driver never did.
#
# SAFETY: mktemp project, stub codex, --no-protect (the real ~/.codex is never
# touched).
set -u
. "$(cd "$(dirname "$0")" && pwd)/codex-lib.sh"

# Without timeout/gtimeout the driver refuses to start (DR-7), so every case here
# would measure that refusal; skip the file whole via the run-all protocol.
require_watchdog_binary

WS=$(mk_proj); trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/proj/docs/looptesting"
# A stub that honors `-C <dir>` the way `codex exec` does: chdir there, fail
# if it does not exist. Then converge at once so the driver exits 0.
cat > "$WS/stub-codex.sh" <<'STUB'
#!/usr/bin/env bash
set -u
while [ $# -gt 0 ]; do
  case "$1" in
    -C) cd "$2" || { echo "stub-codex: -C target does not exist: $2" >&2; exit 1; }; shift 2 ;;
    *)  shift ;;
  esac
done
printf 'C-target: %s\n' "$(pwd)" > docs/looptesting/stub-cwd.txt
printf '# STATE\nround: 1\nconverged_streak: 2\nstatus: CONVERGED\nmax_rounds: 12\n' > docs/looptesting/STATE.md
STUB
chmod +x "$WS/stub-codex.sh"
printf '# STATE\nround: 0\nconverged_streak: 0\nstatus: RUNNING\nmax_rounds: 12\n' > "$WS/proj/docs/looptesting/STATE.md"

# 1. Relative --project, run from its parent directory.
( cd "$WS" && bash "$CODEX_DRIVER" --project proj --codex-bin "$WS/stub-codex.sh" --no-protect --max-sessions 2 ) >/dev/null 2>&1
assert_rc $? 0 "relative --project: the session reaches the project and the loop converges (exit 0)"
assert_eq "1" "$(sessions_in_log "$WS/proj")" "relative --project: exactly one session was needed"
assert_file_contains "$WS/proj/docs/looptesting/stub-cwd.txt" "C-target: $WS/proj" "codex exec -C received the absolute project path"
assert_file_contains "$WS/proj/docs/looptesting/driver.log" "project=$WS/proj" "driver.log records the absolute project path"

# 2. `.` from inside the project (the other common spelling).
WS2=$(mk_proj); trap 'rm -rf "$WS" "$WS2"' EXIT
cp "$WS/stub-codex.sh" "$WS2/stub-codex.sh"
printf '# STATE\nround: 0\nconverged_streak: 0\nstatus: RUNNING\nmax_rounds: 12\n' > "$WS2/docs/looptesting/STATE.md"
( cd "$WS2" && bash "$CODEX_DRIVER" --project . --codex-bin "$WS2/stub-codex.sh" --no-protect --max-sessions 2 ) >/dev/null 2>&1
assert_rc $? 0 "--project . : the loop converges (exit 0)"
assert_file_contains "$WS2/docs/looptesting/stub-cwd.txt" "C-target: $WS2" "codex exec -C received the absolute path for ."

# 3. Relative --project with CDPATH=. set. `PROJECT="$(cd "$PROJECT" && pwd)"`
#    consults CDPATH for a bare-relative name, and cd ECHOES the directory it
#    found into the substitution: PROJECT became "<abs>\n<abs>", the driver made
#    that directory tree and ran its sessions there, in no project at all.
WS3=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3"' EXIT
mkdir -p "$WS3/proj/docs/looptesting"
cp "$WS/stub-codex.sh" "$WS3/stub-codex.sh"
printf '# STATE\nround: 0\nconverged_streak: 0\nstatus: RUNNING\nmax_rounds: 12\n' > "$WS3/proj/docs/looptesting/STATE.md"
( cd "$WS3" && CDPATH=. bash "$CODEX_DRIVER" --project proj --codex-bin "$WS3/stub-codex.sh" --no-protect --max-sessions 2 ) >/dev/null 2>&1
assert_rc $? 0 "CDPATH=. relative --project: the loop converges (exit 0)"
assert_file_contains "$WS3/proj/docs/looptesting/stub-cwd.txt" "C-target: $WS3/proj" "CDPATH=. relative --project: codex exec -C received the real project"
assert_eq "docs proj stub-codex.sh" "$(cd "$WS3" && ls -A | tr '\n' ' ' | sed 's/ $//')" "CDPATH=. relative --project: no stray directory beside the project"

# 4. Relative --codex-bin with the project elsewhere. The preflight `command -v`
#    ran in the invocation cwd and passed; the session execs it after
#    `cd "$PROJECT"`, where the path names nothing — every session failed and the
#    driver reported NO_PROGRESS (exit 5), blaming the loop for its own path.
WS4=$(mk_proj); trap 'rm -rf "$WS" "$WS2" "$WS3" "$WS4"' EXIT
mkdir -p "$WS4/proj/docs/looptesting" "$WS4/bin"
cp "$WS/stub-codex.sh" "$WS4/bin/codex"
printf '# STATE\nround: 0\nconverged_streak: 0\nstatus: RUNNING\nmax_rounds: 12\n' > "$WS4/proj/docs/looptesting/STATE.md"
( cd "$WS4" && bash "$CODEX_DRIVER" --project proj --codex-bin bin/codex --no-protect --max-sessions 2 ) >/dev/null 2>&1
assert_rc $? 0 "relative --codex-bin: the session finds the binary and the loop converges (exit 0)"
assert_file_contains "$WS4/proj/docs/looptesting/stub-cwd.txt" "C-target: $WS4/proj" "relative --codex-bin: the stub actually ran"

report "codex-relative-project.test.sh"
