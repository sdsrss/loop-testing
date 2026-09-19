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
