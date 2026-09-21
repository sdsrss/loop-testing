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
# The ERE matches only the bare form: the array form is written `${WS_ALL[@]}`,
# where `$` is followed by `{`, so `\$WS_ALL` cannot match it.
# This file is excluded by path, not by pattern: it necessarily contains the
# construct it hunts for — in the grep above, in the self-probe below, and in
# the failure message. A gate in this tree that reads source text and forgets to
# exempt itself fails the fix instead of the bug, which has happened here before
# (the comment-scanning half of the portability suite, audit round 16).
bare_hits=$(grep -rnE -- '\$WS_ALL' tests/ 2>/dev/null \
  | grep -v '^tests/portability/bash3\.test\.sh:' \
  | grep -v '^[^:]*:[0-9]*:[[:space:]]*#')
if [ -z "$bare_hits" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "  FAIL: bare \$WS_ALL in a suite where WS_ALL is an array — expands to element 0 only" >&2
  printf '%s\n' "$bare_hits" | sed 's/^/    /' >&2
fi

# Self-probe for the check above, same reasoning as the one below it: a pattern
# that stopped matching would report green forever. Prove it fires on the exact
# construct it exists to catch, and does NOT fire on the correct array form.
bprobe=$(mktemp "${TMPDIR:-/tmp}/loop-testing-arrprobe.XXXXXX")
printf 'for ws in $WS_ALL; do :; done\n' > "$bprobe"
bp_bad=$(grep -cE -- '\$WS_ALL' "$bprobe")
printf 'rm -rf -- "${WS_ALL[@]}"\n' > "$bprobe"
bp_good=$(grep -cE -- '\$WS_ALL' "$bprobe")
if [ "$bp_bad" = 1 ] && [ "$bp_good" = 0 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "  FAIL: self-probe — the bare-\$WS_ALL pattern must match the bare form ($bp_bad) and not the array form ($bp_good)" >&2
fi
rm -f "$bprobe"

# --- the two driver libs must not drift apart (review T-7) -------------------
# tests/driver/lib.sh and tests/driver/codex-lib.sh are independent copies, not
# a lib and a wrapper, and codex-lib.sh's note says the three wait helpers are
# identical to the other's. A comment claiming that is worth nothing — the
# previous one claimed byte-identity of the whole block and diff refuted it over
# 13 lines. Check the part that actually matters instead.
LIB_A="tests/driver/lib.sh"; LIB_B="tests/driver/codex-lib.sh"
fn_drift=""; fn_empty=""
for fn in test_wait_budget wait_lock_pid wait_pid_gone; do
  a=$(sed -n "/^$fn() {/,/^}/p" "$LIB_A"); b=$(sed -n "/^$fn() {/,/^}/p" "$LIB_B")
  # Self-probe, inline: two EMPTY extractions compare equal, which is how this
  # check would pass forever if a function were renamed or reformatted.
  if [ -z "$a" ] || [ -z "$b" ]; then fn_empty="$fn_empty $fn"; continue; fi
  [ "$a" = "$b" ] || fn_drift="$fn_drift $fn"
done
if [ -n "$fn_empty" ]; then
  FAIL=$((FAIL+1)); echo "  FAIL: could not extract from one of the driver libs:$fn_empty — this check was comparing nothing" >&2
elif [ -n "$fn_drift" ]; then
  FAIL=$((FAIL+1)); echo "  FAIL: the two driver libs have drifted:$fn_drift" >&2
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
