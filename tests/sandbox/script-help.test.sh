#!/usr/bin/env bash
# script-help.test.sh — the two hand-run sandbox scripts must answer --help.
#
# The gap this locks: every other entry point in the repo answers --help/-h
# (install-codex.sh, unattended-loop.sh, unattended-codex.sh, moa.mjs), but
# sandbox-setup.sh and sandbox-clean.sh replied "unknown argument: --help" and
# exited 2. These are the two scripts the README tells a USER to run by hand —
# including `sandbox-clean.sh --purge`, which deletes branches and directories —
# so "what are my options?" answering with an error is the worst place for it.
#
# --help must also be INERT: printing usage must never create a sandbox or remove
# anything, so it has to be handled before the scripts touch the filesystem.
set -u

. "$(dirname "$0")/lib.sh"

WS=$(mk_ws)
trap 'rm -rf "$WS"' EXIT
PROJ="$WS/proj"

for flag in --help -h; do
  for pair in "SETUP:$SETUP:sandbox-setup" "CLEAN:$CLEAN:sandbox-clean"; do
    rest="${pair#*:}"; script="${rest%:*}"; label="${rest##*:}"
    out=$( cd "$PROJ" && bash "$script" "$flag" 2>&1 ); rc=$?
    assert_eq 0 "$rc" "$label $flag exits 0"
    printf '%s' "$out" | grep -qF 'Usage:' \
      && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: $label $flag must print a Usage: line" >&2; }
    printf '%s' "$out" | grep -qF 'Exit codes:' \
      && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: $label $flag must print its exit codes" >&2; }
    if printf '%s' "$out" | grep -qF 'unknown argument'; then
      FAIL=$((FAIL+1)); echo "  FAIL: $label $flag must not be treated as an unknown argument" >&2
    else PASS=$((PASS+1)); fi
    # the help text must not still be commented out
    if printf '%s' "$out" | grep -qE '^#'; then
      FAIL=$((FAIL+1)); echo "  FAIL: $label $flag leaks raw '#' comment markers" >&2
    else PASS=$((PASS+1)); fi
  done
done

# each script's own flags have to appear in its help
out=$( cd "$PROJ" && bash "$SETUP" --help 2>&1 )
for f in --mode --worktree-path --branch --baseline-tag --allow-dirty; do
  printf '%s' "$out" | grep -qF -- "$f" \
    && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: sandbox-setup help omits $f" >&2; }
done
out=$( cd "$PROJ" && bash "$CLEAN" --help 2>&1 )
for f in --purge --discard-fixes; do
  printf '%s' "$out" | grep -qF -- "$f" \
    && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: sandbox-clean help omits $f" >&2; }
done

# --help is inert: no sandbox built, nothing removed
assert_absent "$PROJ/docs/looptesting" "--help does not create the evidence dir"
assert_absent "$WS/proj-qa-loop" "--help does not create a worktree"

# a genuinely unknown flag must STILL be a usage error (exit 2), not help
out=$( cd "$PROJ" && bash "$SETUP" --not-a-flag 2>&1 ); rc=$?
assert_eq 2 "$rc" "sandbox-setup still rejects an unknown flag with exit 2"
out=$( cd "$PROJ" && bash "$CLEAN" --not-a-flag 2>&1 ); rc=$?
assert_eq 2 "$rc" "sandbox-clean still rejects an unknown flag with exit 2"

# --help wins even when combined with a destructive flag, and stays inert
( cd "$PROJ" && bash "$SETUP" ) >/dev/null 2>&1
sed -i.bak 's/^status: .*/status: CONVERGED/' "$PROJ/docs/looptesting/STATE.md"; rm -f "$PROJ/docs/looptesting/STATE.md.bak"
out=$( cd "$PROJ" && bash "$CLEAN" --purge --help 2>&1 ); rc=$?
assert_eq 0 "$rc" "sandbox-clean --purge --help exits 0 (help, not a purge)"
assert_exists "$PROJ/docs/looptesting" "--purge --help purged nothing"
git -C "$PROJ" rev-parse -q --verify refs/tags/qa-baseline >/dev/null 2>&1 \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: --purge --help must not delete the baseline tag" >&2; }

# --- how the script is INVOKED must not decide whether it runs ---------------
# The lib.sh extraction made every entry point resolve a sibling file, so the
# four shipped scripts went from "work however you call them" to "work if
# `dirname "${BASH_SOURCE[0]}"` happens to name the directory lib.sh is in".
# Measured against v0.16.0, where both of these exited 0:
#
#   * a SYMLINK into ~/bin — `dirname` resolves the LINK's directory, not the
#     target's, so the script looks for lib.sh next to the symlink. Nothing the
#     installer does creates one, but putting a script on your PATH by symlink is
#     an ordinary thing to do and the refusal does not say that is the cause.
#   * CDPATH — `cd` ECHOES its target whenever CDPATH is consulted, and that echo
#     lands inside the command substitution. `CDPATH=.`, which people really do
#     put in an rc file, is enough. Only bare-relative invocations consult it.
#
# Both fail CLOSED (refuse, delete nothing), so this is availability, not safety.
# Asserted for all four shipped scripts, not just the two this file is named for:
# the drivers grew the same idiom in the same commit.
SCRIPTS_DIR="$(dirname "$SETUP")"
LINKDIR="$WS/bin"; mkdir -p "$LINKDIR"
for _s in sandbox-setup.sh sandbox-clean.sh unattended-loop.sh unattended-codex.sh; do
  [ -f "$SCRIPTS_DIR/$_s" ] || { FAIL=$((FAIL+1)); echo "  FAIL: $_s missing from the scripts dir" >&2; continue; }
  ln -sf "$SCRIPTS_DIR/$_s" "$LINKDIR/$_s"
  out=$( cd "$PROJ" && bash "$LINKDIR/$_s" --help 2>&1 ); rc=$?
  assert_eq 0 "$rc" "$_s answers --help when invoked through a symlink — output: $(printf '%s' "$out" | head -1)"
  # The premise: a symlink that does NOT resolve to the scripts dir would make
  # this vacuous, so prove the link is what the case claims it is.
  case "$(readlink "$LINKDIR/$_s")" in
    "$SCRIPTS_DIR/$_s") PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1)); echo "  FAIL: fixture: $LINKDIR/$_s does not point at the scripts dir" >&2 ;;
  esac
  # CDPATH, bare-relative invocation — the only shape that consults it.
  out=$( cd "$SCRIPTS_DIR/.." && CDPATH=. bash "scripts/$_s" --help 2>&1 ); rc=$?
  assert_eq 0 "$rc" "$_s answers --help with CDPATH=. set — output: $(printf '%s' "$out" | head -1)"
  # A RELATIVE link, reached through a relative path under CDPATH=.: the only
  # shape that exercises the resolver's relative-target arm and the CDPATH='' on
  # its in-loop `cd`. Review measured both deletable with every case above green.
  mkdir -p "$WS/rel/a b" "$WS/rel/c"
  ln -sf "$SCRIPTS_DIR/$_s" "$WS/rel/a b/$_s"
  ln -sf "../a b/$_s" "$WS/rel/c/$_s"
  out=$( cd "$WS/rel" && CDPATH=. bash "c/$_s" --help 2>&1 ); rc=$?
  assert_eq 0 "$rc" "$_s answers --help through a relative link chain under CDPATH=. — output: $(printf '%s' "$out" | head -1)"
done

# --- ...and past --help, the script must still know where it lives -----------
# The resolver above only locates lib.sh. sandbox-setup.sh derived its templates
# dir from its own `dirname "$0"`, so through a symlink or under CDPATH=. it got
# past the lib.sh gate, exited 0, and seeded none of the templates — silently.
for _how in symlink cdpath; do
  WS2=$(mk_ws) || { FAIL=$((FAIL+1)); echo "  FAIL: mk_ws for the $_how setup case" >&2; continue; }
  # setup works on its cwd, so CDPATH needs a bare-relative path FROM the project:
  # a directory link to the skill, excluded so the tree stays clean.
  case "$_how" in
    symlink) ( cd "$WS2/proj" && bash "$LINKDIR/sandbox-setup.sh" ) >/dev/null 2>&1; rc=$? ;;
    cdpath)  ln -s "$SCRIPTS_DIR/.." "$WS2/proj/lt-skill" && echo lt-skill >> "$WS2/proj/.git/info/exclude"
             ( cd "$WS2/proj" && CDPATH=. bash lt-skill/scripts/sandbox-setup.sh ) >/dev/null 2>&1; rc=$? ;;
  esac
  assert_eq 0 "$rc" "sandbox-setup via $_how exits 0"
  for _t in STATE.md PLAN.md ISSUES.md; do
    assert_exists "$WS2/proj/docs/looptesting/$_t" "sandbox-setup via $_how seeds $_t"
  done
  rm -rf "${WS2:?}"
done

# --worktree-path under CDPATH=.: setup's `cd "$_wt_probe"` consulted CDPATH for
# a bare-relative existing parent and echoed into the substitution, so the
# worktree was created at a path containing a newline and the ownership marker
# recorded the USER's own parent directory as CREATED_WORKTREE. Clean then kept
# (leaked) the worktree and --purge stopped at rc 4. It failed safe — the user's
# directory survived — but the marker must name what setup actually created.
WS2=$(mk_ws) || { FAIL=$((FAIL+1)); echo "  FAIL: mk_ws for the worktree-path case" >&2; }
if [ -n "${WS2:-}" ]; then
  mkdir -p "$WS2/proj/wts"; echo keep > "$WS2/proj/wts/user-file"
  echo wts >> "$WS2/proj/.git/info/exclude"
  ( cd "$WS2/proj" && CDPATH=. bash "$SETUP" --worktree-path wts/qa ) >/dev/null 2>&1; rc=$?
  assert_eq 0 "$rc" "setup --worktree-path wts/qa under CDPATH=. exits 0"
  want="CREATED_WORKTREE=$(cd -P "$WS2/proj/wts" && pwd)/qa"
  got=$(grep -a '^CREATED_WORKTREE=' "$WS2/proj/docs/looptesting/.sandbox/ownership.env" 2>/dev/null | head -1)
  assert_eq "$want" "$got" "under CDPATH=. the marker names the worktree setup created, not its parent"
  assert_exists "$WS2/proj/wts/qa/.git" "under CDPATH=. the worktree is where --worktree-path says"
  git -C "$WS2/proj" worktree remove --force "$WS2/proj/wts/qa" >/dev/null 2>&1
  rm -rf "${WS2:?}"
fi

report "script-help.test.sh"
