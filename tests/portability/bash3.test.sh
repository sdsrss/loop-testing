#!/usr/bin/env bash
# Portability gate: shipped runtime scripts must run on bash 3.2.
#
# WHY: stock macOS ships /bin/bash 3.2.57, every shipped script is
# `#!/usr/bin/env bash`, and CI is ubuntu-only on purpose (.github/workflows/ci.yml
# documents macOS as deliberately out of the matrix for TEST-fixture reasons, while
# asserting the PRODUCT scripts stay BSD/bash-3 portable). Nothing mechanical held
# that assertion up: a bash-4-only expansion is a FATAL "bad substitution" for a
# non-interactive shell, so one such construct on a hot path bricks the script on
# every macOS run — and a green ubuntu CI says nothing about it.
#
# Scope: shipped runtime scripts only (skills/, hooks/, install/). tests/ is dev-only
# and may use bash 4 freely — the harness runs where the developer runs.
set -u
cd "$(cd "$(dirname "$0")" && pwd)/../.." || { echo "FAILED: cannot cd to repo root"; exit 1; }

PASS=0
FAIL=0

# Shipped runtime scripts, NUL-delimited so odd paths are safe.
mapfile -d '' -t SHIPPED < <(find skills hooks install -name '*.sh' -type f -print0 2>/dev/null)
if [ "${#SHIPPED[@]}" -eq 0 ]; then
  echo "  GATE FAIL: no shipped *.sh discovered (wrong cwd, or the tree moved)" >&2
  exit 1
fi

# name<TAB>ERE — each is bash 4.0+ only and fatal (or silently wrong) on bash 3.2.
CONSTRUCTS=$(
  printf '%s\n' \
    'case-modification expansion ${v,,} / ${v^^}	\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,?|\^\^?)' \
    'mapfile / readarray	(^|[^[:alnum:]_-])(mapfile|readarray)[[:space:]]' \
    'associative array declare -A	(declare|local|typeset)[[:space:]]+-[A-Za-z]*A[A-Za-z]*[[:space:]]'
)

while IFS=$'\t' read -r label re; do
  [ -n "$label" ] || continue
  hits=$(grep -nEH -- "$re" "${SHIPPED[@]}" 2>/dev/null | grep -v '^[^:]*:[0-9]*:[[:space:]]*#')
  if [ -z "$hits" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "  FAIL: bash-4-only construct in a shipped script — $label" >&2
    printf '%s\n' "$hits" | sed 's/^/    /' >&2
  fi
done <<EOF
$CONSTRUCTS
EOF

# --- bare $WS_ALL anywhere under tests/ (review T-1 / P-03) ------------------
# tests/ is out of scope for the bash-4 scan above, deliberately. It is IN scope
# for this one, which is a different failure: `WS_ALL` was a space-delimited
# string in ten suites and is now an array in all of them, and an array read as
# bare `$WS_ALL` expands to element 0 ALONE — silently, with no error, no matter
# how many fixtures are registered. 2371122 converted the accumulators and left
# one consumer behind at tests/driver/shutdown.test.sh, where the loop that
# kills stray processes before `rm -rf` went from ~30 fixtures to 1.
#
# THREE spellings, one defect, and the first version of this gate saw one of
# them (delta review T-A). `$WS_ALL` and `${WS_ALL}` each expand to element 0
# alone; an UNQUOTED `${WS_ALL[@]}` expands to every element re-split on
# whitespace, which is the leak the array conversion existed to stop. Measured:
# unquoting one cleanup under a $TMPDIR containing a space leaves 8 fixture
# directories behind while the old gate reported 7 passed, 0 failed — the same
# eight the conversion commit cites as the bug it fixed.
#
# So the check is subtractive rather than a list of bad shapes: blank out the
# two forms that ARE correct — `"${WS_ALL[@]}"` and `"${#WS_ALL[@]}"`, quotes
# included — and anything still expanding WS_ALL is a hit. Assignments
# (`WS_ALL=()`, `WS_ALL+=(…)`) never match: no `$` precedes the name.
#
# This file is excluded by path, not by pattern: it necessarily contains the
# constructs it hunts for — in the sed above, in the self-probe below, and in
# the failure message. A gate in this tree that reads source text and forgets to
# exempt itself fails the fix instead of the bug, which has happened here before
# (the comment-scanning half of the portability suite, audit round 16).
ws_scan() {
  sed 's/"\${#\{0,1\}WS_ALL\[[@*]\]}"/<OK>/g' "$1" | grep -cE '\$\{?WS_ALL'
}
bare_hits=$(grep -rn -- 'WS_ALL' tests/ 2>/dev/null \
  | grep -v '^tests/portability/bash3\.test\.sh:' \
  | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
  | sed 's/"\${#\{0,1\}WS_ALL\[[@*]\]}"/<OK>/g' \
  | grep -E '\$\{?WS_ALL')
if [ -z "$bare_hits" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "  FAIL: WS_ALL expanded without the quoted array form — element 0 only, or re-split on whitespace" >&2
  printf '%s\n' "$bare_hits" | sed 's/^/    /' >&2
fi

# Self-probe, widened with the gate (T-A): the previous one asserted only that
# the bare form matched, which is exactly the blind spot it failed to reveal.
# Every defective spelling must be caught and every correct one must be let
# through, or this gate is green for a reason nobody checked.
bprobe=$(mktemp "${TMPDIR:-/tmp}/loop-testing-arrprobe.XXXXXX")
bp_ok=1
for bad in 'for ws in $WS_ALL; do :; done' 'for ws in ${WS_ALL}; do :; done' \
           'rm -rf -- ${WS_ALL[@]}' 'echo ${WS_ALL[*]}'; do
  printf '%s\n' "$bad" > "$bprobe"
  [ "$(ws_scan "$bprobe")" -ge 1 ] || { bp_ok=0; echo "  probe: MISSED [$bad]" >&2; }
done
for good in 'rm -rf -- "${WS_ALL[@]}"' 'if [ "${#WS_ALL[@]}" -gt 0 ]; then :; fi' \
            'WS_ALL=()' 'track_ws() { WS_ALL+=("$1"); }'; do
  printf '%s\n' "$good" > "$bprobe"
  [ "$(ws_scan "$bprobe")" -eq 0 ] || { bp_ok=0; echo "  probe: FALSE HIT on [$good]" >&2; }
done
if [ "$bp_ok" = 1 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); echo "  FAIL: self-probe — the WS_ALL scan no longer separates the defective spellings from the correct ones" >&2
fi
rm -f "$bprobe"

# --- a suite that runs `git init` must neutralise an inherited GIT_DIR (T-B) --
# The T-2 repair put `unset GIT_DIR GIT_WORK_TREE GIT_CEILING_DIRECTORIES` in
# the four shared libs, which covered every suite that sources one — and missed
# the two under tests/commands/, which source none. With GIT_DIR exported,
# `git init -q "$dir"` returns 0 and creates nothing, so such a suite operates
# on, and commits into, whatever repository the variable names. Measured on
# isolation-gate: 21 passed, 0 failed, and two commits in an unrelated repo.
git_init_unguarded=""
for f in $(grep -rl 'git init' tests/ --include='*.test.sh' 2>/dev/null | sort); do
  grep -q 'unset GIT_DIR' "$f" && continue
  grep -qE '^\. "\$\(cd .*lib\.sh"$' "$f" && continue
  git_init_unguarded="$git_init_unguarded $f"
done
if [ -z "$git_init_unguarded" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "  FAIL: suite runs 'git init' with no unset GIT_DIR and no lib that does:$git_init_unguarded" >&2
fi

# --- the two driver libs must not drift apart (review T-7) -------------------
# tests/driver/lib.sh and tests/driver/codex-lib.sh are independent copies, not
# a lib and a wrapper, and codex-lib.sh's note says the three wait helpers are
# identical to the other's. A comment claiming that is worth nothing — the
# previous one claimed byte-identity of the whole block and diff refutes it (at
# 7a7d27c: 49 differing lines whole-file, 24 within the block). That note also
# carried "13 lines", a figure no extraction boundary reproduces; it was struck
# rather than corrected (delta review D-6), because a number a reader cannot
# re-derive is not a claim. Check the part that actually matters instead.
LIB_A="tests/driver/lib.sh"; LIB_B="tests/driver/codex-lib.sh"
# `declare -f` in a subshell, not a sed range over the source text (delta review
# T-C and T-G). Two defects in the text approach, one in each direction:
#   * `sed -n "/^fn() {/,/^}/p"` ends at the FIRST column-0 `}`, which a
#     heredoc body can supply — the extraction then stops early and real drift
#     after that point is invisible while the gate stays green;
#   * it compares comments, so a clarifying note added to one copy alone fails a
#     check that is supposed to be about behaviour.
# bash's own parse settles both: it discards comments and re-prints the body
# canonically, so what is compared is what will run. Sourcing happens in a
# subshell — these libs' top level only sets REPO_ROOT, a couple of paths, the
# counters and the unsets, none of which escape it.
fn_dump() { ( . "$1" >/dev/null 2>&1 && declare -f "$2" ) 2>/dev/null; }
fn_drift=""; fn_empty=""
for fn in test_wait_budget wait_lock_pid wait_pid_gone; do
  a=$(fn_dump "$LIB_A" "$fn"); b=$(fn_dump "$LIB_B" "$fn")
  # Self-probe, inline: two EMPTY dumps compare equal, which is how this check
  # would pass forever if a function were renamed away or the source failed.
  if [ -z "$a" ] || [ -z "$b" ]; then fn_empty="$fn_empty $fn"; continue; fi
  [ "$a" = "$b" ] || fn_drift="$fn_drift $fn"
done
# Both conditions are reported, not just the first (T-H): an un-extractable
# function used to mask the name of a drifted one, which is the diagnostic a
# maintainer actually needs.
if [ -n "$fn_empty" ] || [ -n "$fn_drift" ]; then
  FAIL=$((FAIL+1))
  [ -n "$fn_empty" ] && echo "  FAIL: could not read from one of the driver libs:$fn_empty — this check was comparing nothing" >&2
  [ -n "$fn_drift" ] && echo "  FAIL: the two driver libs have drifted:$fn_drift" >&2
else
  PASS=$((PASS+1))
fi

# The scan is only meaningful if the pattern actually fires; a silently-broken ERE
# would make this suite a green no-op forever (same zero-discovery reasoning as
# tests/run-all.sh). Prove the case-modification pattern matches a known-positive.
probe=$(mktemp "${TMPDIR:-/tmp}/loop-testing-bash3probe.XXXXXX")
printf '#!/usr/bin/env bash\nv=ABC\nflag="${v,,}"\necho "$flag"\n' > "$probe"
if grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,?|\^\^?)' "$probe"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); echo "  FAIL: self-probe — the case-modification pattern no longer matches \${v,,}" >&2
fi
rm -f "$probe"

echo "bash3.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
