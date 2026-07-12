#!/usr/bin/env bash
# loop-testing test entry point.
#   1. bash -n syntax check on every tracked *.sh
#   2. shellcheck (errors only) when available
#   3. every tests/**/*.test.sh shell test
#   4. node --test tests/moa/*.test.mjs when that dir exists (glob form: bare-dir positional is not discovered on node v22)
set -u
cd "$(dirname "$0")/.." || { echo "FAILED: cannot cd to repo root"; exit 1; }

overall=0

echo "== bash -n =="
sh_found=0
while IFS= read -r -d '' f; do
  sh_found=1
  if bash -n "$f"; then echo "  ok: $f"; else echo "  SYNTAX FAIL: $f"; overall=1; fi
done < <(find skills tests hooks install -name '*.sh' -type f -print0 2>/dev/null)
# Zero discovery is a gate failure, not a pass: an empty find (wrong cwd, moved
# tree) must never yield a green run that checked nothing (audit TS-1).
[ "$sh_found" -eq 1 ] || { echo "  GATE FAIL: no *.sh files discovered"; overall=1; }

if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck (errors only) =="
  mapfile -t sh_files < <(find skills tests hooks install -name '*.sh' -type f 2>/dev/null)
  if [ "${#sh_files[@]}" -gt 0 ] && shellcheck -S error -e SC1091 "${sh_files[@]}"; then
    echo "  ok: no errors"
  else overall=1; fi
else
  echo "== shellcheck not installed, skipping (bash -n only) =="
fi

echo "== shell tests =="
tests_found=0
while IFS= read -r -d '' t; do
  tests_found=1
  if bash "$t"; then echo "  ok: $t"; else echo "  TEST FAIL: $t"; overall=1; fi
done < <(find tests -name '*.test.sh' -type f -print0 2>/dev/null | sort -z)
[ "$tests_found" -eq 1 ] || { echo "  GATE FAIL: no *.test.sh found (zero discovery must not pass)"; overall=1; }

if [ -d tests/moa ]; then
  echo "== node --test tests/moa/ =="
  if command -v node >/dev/null 2>&1; then
    if node --test tests/moa/*.test.mjs; then echo "  ok: moa tests"; else echo "  MOA TEST FAIL"; overall=1; fi
  else
    echo "  node not installed, skipping moa tests"
  fi
else
  echo "  GATE FAIL: tests/moa missing (zero discovery must not pass)"; overall=1
fi

[ "$overall" -eq 0 ] && echo "ALL GREEN" || echo "FAILED"
exit "$overall"
