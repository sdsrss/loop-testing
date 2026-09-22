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
#
# find's status and stderr are KEPT, and every file is checked readable before the
# scan runs. This arm had exactly the two blindnesses the bare-timeout scan 200
# lines below was repaired for, and it is the older and more important of the two —
# it guards SHIPPED scripts. Measured on a scratch copy: a `${v,,}` in a shipped
# script reports 11 passed / 1 failed while readable, and `12 passed, 0 failed`
# once that one file is chmod 000; a `${v^^}` inside a subdirectory of skills/
# does the same once the directory cannot be descended. Zero discovery was the only
# case checked, and neither of those is zero discovery.
_sh_list=$(mktemp "${TMPDIR:-/tmp}/loop-testing-shiplist.XXXXXX") || {
  echo "  GATE FAIL: mktemp for the shipped-script list failed" >&2; exit 1; }
_sh_err=$(mktemp "${TMPDIR:-/tmp}/loop-testing-shiperr.XXXXXX") || {
  echo "  GATE FAIL: mktemp for find's stderr failed" >&2; rm -f "$_sh_list"; exit 1; }
find skills hooks install -name '*.sh' -type f -print0 > "$_sh_list" 2>"$_sh_err"
_sh_find_rc=$?
mapfile -d '' -t SHIPPED < "$_sh_list"
if [ "$_sh_find_rc" -ne 0 ] || [ -s "$_sh_err" ]; then
  echo "  GATE FAIL: discovery of shipped scripts failed (find rc $_sh_find_rc) — a subtree it cannot descend contributes no files and reads exactly like a clean tree" >&2
  [ -s "$_sh_err" ] && sed 's/^/    /' "$_sh_err" >&2
  rm -f "$_sh_list" "$_sh_err"; exit 1
fi
rm -f "$_sh_list" "$_sh_err"
if [ "${#SHIPPED[@]}" -eq 0 ]; then
  echo "  GATE FAIL: no shipped *.sh discovered (wrong cwd, or the tree moved)" >&2
  exit 1
fi
_sh_unreadable=""
for f in "${SHIPPED[@]}"; do
  [ -r "$f" ] || _sh_unreadable="$_sh_unreadable $f"
done
if [ -n "$_sh_unreadable" ]; then
  echo "  GATE FAIL: shipped script(s) this gate cannot read:$_sh_unreadable — grep reports rc 2 and no output for them, which is indistinguishable from a file with nothing to find" >&2
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
# The path is the parameter: this helper exists to dump the same function out of
# two DIFFERENT libs and diff them, so there is no constant for shellcheck to
# follow and nothing it could check by following one.
# shellcheck disable=SC1090
fn_dump() { ( . "$1" >/dev/null 2>&1 && declare -f "$2" ) 2>/dev/null; }
fn_drift=""; fn_empty=""
for fn in test_wait_budget wait_lock_pid wait_pid_gone bounded require_watchdog_binary; do
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

# --- no suite may invoke a bare `timeout` (T-D, and the six sites its fix missed)
# `timeout` is GNU. Stock macOS ships none and homebrew coreutils installs it as
# `gtimeout`, so a bare call returns 127 there. Review T-D found five such sites
# in the two driver limits SUITES — not in the libs, which are where its fix put
# the resolution — and v0.15.0 fixed them; it left six of the same shape in
# tests/hooks/stop-gate.test.sh and tests/sandbox/setup.test.sh, because the
# answer had no shared home and each suite had to remember separately. Three of
# those six were worse than a failure: `setup.test.sh`'s dangling-flag guards
# assert `rc != 124`, which 127 satisfies, so they PASSED on a host where the
# script never ran. The binary belongs behind TIMEOUT_BIN / bounded() in
# tests/lib-watchdog.sh. Two files are exempt by path; that one currently matches
# zero times, so its exemption is defensive rather than load-bearing.
#
# What this can and cannot see, measured rather than assumed — an earlier draft of
# this paragraph got it wrong in both directions, so the rule below is the one a
# reviewer established by feeding lines to the ERE.
#
# It fires when the last non-whitespace character before `timeout <digit>` is `;`
# `|` `&` or `(`, or at line start, or when a whitespace-delimited `env` appears
# earlier on the line with none of `;` `|` `&` between. That is a position, not a
# parse, so it has no idea whether the line is code:
#   * OVER-matches. `# the old form was ( cd x && timeout 5 bash y )` is caught,
#     at any indent — the claim that a comment is safe was simply false. So are
#     `echo "sleep 1; timeout 5"` and a JSON payload `"cd x; timeout 5 grep foo"`.
#     Two live lines are missed, and NOT for the reason an earlier draft gave:
#     removing the backtick before stop-gate.test.sh:282's call, or the `"` before
#     ledger-gate.test.sh:561,575's, leaves both still unmatched. What saves them
#     is the `#` and the `:` further left — neither is in the prefix class either.
#     Naming the nearest character as the cause was a guess dressed as a reading.
#   * UNDER-matches, because anything between the word and its duration hides it:
#     `timeout --foreground 5`, `timeout -k 1 5`, `timeout "$SECS"`, `TO=timeout;
#     $TO 5`, and any wrapper in front — `command`/`exec`/`nohup`/`sudo`/`time`/
#     `xargs`/`find -exec`/`FOO=1 `/`if`/`while`/`!`/`{ …; }`/backticks.
# A line inside a heredoc body IS caught when it starts with the call, which the
# earlier draft had backwards.
#
# The instrument that cannot be fooled is running the suite on a PATH holding
# neither binary. That is a host arm rather than a gate, which is why the TOTAL
# line names the arm.
# `(^|[[:space:]])env`, not `[[:space:]]env`: a line BEGINNING with the wrapper —
# `env -u FOO timeout 5 bash y` at column 0 — was missed, which the disclosure
# above did not mention either. Still missed and now listed: `then timeout 5`.
BARE_TO='(^|[;|&(]|(^|[[:space:]])env[[:space:]][^;|&]*[[:space:]])[[:space:]]*g?timeout[[:space:]]+[0-9]'
# Discovery and reading are both checked, because "we saw at least one file" is not
# the same claim as "we read the files we meant to". Three ways this scan goes
# blind over a NON-empty file set, all of them measured:
#   * `grep -c` returning 2 — an unreadable file, or an ERE this grep rejects —
#     produces empty output that `${c:-0}` turns into a clean verdict;
#   * `find … 2>/dev/null | sort` discards find's exit status AND its stderr, and
#     the pipeline reports sort's status, so a directory find cannot descend
#     contributes zero files and reads as a clean subtree;
#   * an empty result set, the ordinary zero-discovery case.
# So find's status and stderr are kept, and grep's status is separated from its
# count. A bare non-zero file count sees none of the first two.
bare_to_hits=""
bare_to_seen=0
bare_to_exempt=0
bare_to_grepfail=""
bt_list=$(mktemp "${TMPDIR:-/tmp}/loop-testing-btlist.XXXXXX") || bt_list=""
bt_err=$(mktemp "${TMPDIR:-/tmp}/loop-testing-bterr.XXXXXX") || bt_err=""
bt_find_rc=0
if [ -n "$bt_list" ] && [ -n "$bt_err" ]; then
  find tests -name '*.sh' -type f > "$bt_list" 2>"$bt_err"
  bt_find_rc=$?
  # Two files are exempt by PATH, not by pattern. tests/lib-watchdog.sh is where
  # the binary is legitimately resolved. This file necessarily contains matching
  # forms too — the assembled probe below, and the over-match examples in the
  # comment above, which are matching lines by construction and were duly flagged
  # the first time this ran. That is the same reasoning, and the same remedy, as
  # the WS_ALL gate 100 lines up: a gate in this tree that reads source text and
  # forgets to exempt itself fails the fix instead of the bug.
  while IFS= read -r f; do
    case "$f" in
      tests/lib-watchdog.sh|tests/portability/bash3.test.sh)
        bare_to_exempt=$((bare_to_exempt + 1)); continue ;;
    esac
    bare_to_seen=$((bare_to_seen + 1))
    c=$(grep -cE "$BARE_TO" "$f" 2>/dev/null)
    grc=$?
    if [ "$grc" -ge 2 ]; then
      bare_to_grepfail="$bare_to_grepfail $f(grep rc $grc)"
      continue
    fi
    case "${c:-0}" in ''|0) ;; *) bare_to_hits="$bare_to_hits $f($c)" ;; esac
  done < "$bt_list"
fi
# Every branch above the hit report is a way to LOOK clean without having looked.
# tests/run-all.sh applies the same rule three times (sh_found, tests_found,
# suites-vs-_ra_files); this scan shipped its first draft without any of it.
if [ -z "$bt_list" ] || [ -z "$bt_err" ]; then
  FAIL=$((FAIL+1))
  echo "  FAIL: mktemp for the bare-timeout scan's file list failed — the scan did not run" >&2
elif [ "$bt_find_rc" -ne 0 ] || [ -s "$bt_err" ]; then
  FAIL=$((FAIL+1))
  echo "  FAIL: the bare-timeout scan's discovery failed (find rc $bt_find_rc$( [ -s "$bt_err" ] && printf ', stderr: %s' "$(head -1 "$bt_err")" )) — a subtree it cannot read contributes no files and reads as clean" >&2
elif [ "$bare_to_seen" -eq 0 ]; then
  FAIL=$((FAIL+1))
  echo "  FAIL: the bare-timeout scan read no files at all — a clean tree and a broken discovery print the same thing" >&2
elif [ "$bare_to_exempt" -ne 2 ]; then
  # Two, hard-coded on purpose: here the number IS the policy, not documentation of
  # it, so it is a tripwire and is meant to redden when the exemption list changes.
  # Without it, broadening the `case` above satisfies the equality below — scanned
  # equals discovered-minus-exempt either way — while fifteen files go unscanned,
  # a live bare `timeout` among them.
  FAIL=$((FAIL+1))
  echo "  FAIL: the bare-timeout scan exempted $bare_to_exempt files, not 2 — if the exemption list changed, this number changes with it and the change gets read" >&2
elif [ "$bare_to_seen" -ne "$(( $(wc -l < "$bt_list") - bare_to_exempt ))" ]; then
  # Two counts computed independently, the way tests/run-all.sh compares `suites`
  # with `_ra_files`. A non-zero file count says the loop STARTED; only the
  # equality says it FINISHED. This repo's own incident is the reason: a body that
  # reads stdin eats the rest of the list, and the loop stops early with every
  # other arm of this gate reporting clean — demonstrated by a reviewer at 1 file
  # scanned of 47, all arms PASS. Nothing in the body reads stdin today, which is
  # exactly the standing of run-all.sh's own suites-vs-files check.
  FAIL=$((FAIL+1))
  echo "  FAIL: the bare-timeout scan read $bare_to_seen of $(( $(wc -l < "$bt_list") - bare_to_exempt )) files — the loop ended early, and every other arm of this gate would have called that clean" >&2
elif [ -n "$bare_to_grepfail" ]; then
  FAIL=$((FAIL+1))
  echo "  FAIL: the bare-timeout scan could not read:$bare_to_grepfail — grep rc 2 or more is not 'no match', and an unreadable file or a rejected ERE would otherwise count as clean" >&2
elif [ -n "$bare_to_hits" ]; then
  FAIL=$((FAIL+1))
  echo "  FAIL: bare timeout/gtimeout invocation in a suite — use bounded():$bare_to_hits" >&2
else
  PASS=$((PASS+1))
fi

# There was a further "real-file positive control" here, asserting that this file —
# exempt by path, and carrying the over-match examples from the comment above —
# still matched the ERE at least once. Removed: its stated premise was false (the
# probe's own fixture IS a file on disk, so the probe already demonstrates that),
# and its only real effect was to make two lines of COMMENT PROSE load-bearing, so
# rewording an explanation reddened the suite. A check that fires on documentation
# edits buys noise, not evidence.
rm -f "$bt_list" "$bt_err"

# --- the harness must resolve the watchdog binary the way the DRIVER does ------
# tests/lib-watchdog.sh's own comment calls this invariant load-bearing, and
# nothing checked it. The drift check below compares the two driver libs, which
# now source the same file and are identical by construction; the comparison that
# can actually catch something is lib against the two shipped drivers. If they
# diverge, the harness bounds its guards on one host while the product picks its
# watchdog on another, and every no-hang guard in the tree is measuring the wrong
# thing.
res_of() {
  grep -E '^[[:space:]]*(TIMEOUT_BIN=""|if command -v timeout|elif command -v gtimeout)' "$1" \
    | sed -e 's/^[[:space:]]*//' | tr -s ' '
}
res_lib=$(res_of tests/lib-watchdog.sh)
res_drv=$(res_of skills/loop-testing/scripts/unattended-loop.sh)
res_cdx=$(res_of skills/loop-testing/scripts/unattended-codex.sh)
# Self-probe first: three empty extractions compare equal, which is how this would
# pass forever if a rename or a reformat took the lines out of reach.
if [ "$(printf '%s\n' "$res_lib" | grep -c .)" -ne 3 ]; then
  FAIL=$((FAIL+1))
  echo "  FAIL: could not read the watchdog resolution out of tests/lib-watchdog.sh — this check was comparing nothing" >&2
elif [ "$res_lib" = "$res_drv" ] && [ "$res_lib" = "$res_cdx" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "  FAIL: the harness resolves the watchdog binary differently from the driver it tests" >&2
  [ "$res_lib" = "$res_drv" ] || echo "    unattended-loop.sh differs" >&2
  [ "$res_lib" = "$res_cdx" ] || echo "    unattended-codex.sh differs" >&2
fi

# Self-probe in BOTH directions, because this scan has two ways to be worthless: a
# broken ERE makes it a green no-op, and an over-broad one fails every fixture
# that merely names the binary (three such forms live in this tree — the `rm -f
# "$BINF/timeout"` farms, the `command -v gtimeout` detection, and a comment that
# quotes `timeout 5` as prose). Both counts are asserted, not just the positive.
#
# One positive per match route, not one per route-that-happens-to-be-covered. The
# prefix set is a single bracket class, so a probe that only exercises `&` would
# stay green if an edit dropped `;` from it; and `g?` — the whole reason this also
# catches `gtimeout`, the binary macOS actually has — was asserted by nothing.
bt_probe=$(mktemp "${TMPDIR:-/tmp}/loop-testing-btprobe.XXXXXX") || bt_probe=""
if [ -z "$bt_probe" ]; then
  # A probe that could not be created leaves the scan UNVERIFIED, which is a
  # failure — not the absence of a check. Written the other way (an echo with no
  # FAIL and no else) this assertion simply left the tally: the file printed a
  # FAIL line and still reported "9 passed, 0 failed" and exit 0, so the run
  # reached ALL GREEN. The other two probes in this file were already counted;
  # this was the one that was not.
  FAIL=$((FAIL+1))
  echo "  FAIL: mktemp for the bare-timeout self-probe failed — the scan ran unverified this run" >&2
else
  # The positives are ASSEMBLED, not written literally: spelled out they are
  # matching forms sitting in a file this very scan reads, and the gate's first run
  # duly flagged its own probe. That was its positive control on a real file,
  # arrived at without constructing one; %s keeps the coverage while leaving
  # nothing here for the pattern to find.
  #
  # Eight routes, one line each: line start, then each of `;` `|` `&` `(`
  # separately, then the `env …` prefix both mid-line and at column 0, then `g?`
  # via gtimeout.
  printf '%s 3 bash foo.sh\ncd x; %s 5 bash y\nprintf x | %s 5 bash y\ncd x && %s 5 bash y\n( %s 5 bash y )\nprintf x | env -u FOO %s 5 bash y\nenv -u FOO %s 5 bash y\ncd x; g%s 5 bash y\n' \
    timeout timeout timeout timeout timeout timeout timeout timeout > "$bt_probe"
  bt_pos=$(grep -cE "$BARE_TO" "$bt_probe")
  # Negatives are the forms this tree really contains, including the two live
  # lines the scan misses — a comment quoting the call, and a JSON payload holding
  # it (stop-gate.test.sh:282 and ledger-gate.test.sh:561,575). Measured: they stay
  # missed with the nearest quoting character removed, so what keeps them out is
  # the `#` and the `:`, not the backtick and the `"` an earlier note blamed.
  printf '%s\n' \
    'bounded 10 bash "$DRIVER" --project' \
    '  "$TIMEOUT_BIN" "$secs" "$@"' \
    '#    `timeout 5` is the assertion: rc 2 means it blocked' \
    'rm -f "$BINF/timeout" "$BINF/gtimeout"' \
    'elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN=gtimeout; fi' \
    'json='"'"'{"command":"timeout 5 grep foo"}'"'"'' > "$bt_probe"
  bt_neg=$(grep -cE "$BARE_TO" "$bt_probe")
  rm -f "$bt_probe"
  if [ "${bt_pos:-0}" -eq 8 ] && [ "${bt_neg:-1}" -eq 0 ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "  FAIL: self-probe — the bare-timeout scan matched ${bt_pos:-?}/8 positives and ${bt_neg:-?}/0 negatives" >&2
  fi
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

# --- macOS matrix: two GNU-only spellings that fail QUIETLY on BSD ------------
# Neither is caught by the bash-3.2 scans above (both are valid bash), nor at the
# linter's warning level. (Said that way on purpose: a comment line STARTING with
# the linter's name is read as a directive, and this one was — two parse errors,
# caught by the very gate this batch raised.) Both were live here, both measured:
#
#   * `touch -d @<epoch>` — BSD/macOS touch has no `-d @`. The usage error goes
#     to a discarded stderr and the file keeps its CURRENT mtime. Of the three
#     sites, two would have failed loudly and one would have PASSED: the case
#     asserting that an old remnant still blocks when staleness is switched off
#     gets the same block from a file that was never aged. Replaced by
#     set_mtime_epoch, which tries the BSD form second and then verifies the
#     timestamp actually moved.
#   * `sed -i <script> <file>` — BSD sed reads the argument after -i as the
#     BACKUP SUFFIX, so the script becomes the suffix and sed is left with none.
#     The portable spelling attaches it: `-i.bak`, then remove the backup.
#
# What this sees, fed to the ERE rather than reasoned about. The first version of
# this paragraph inherited its wording from the bare-timeout scan above without
# inheriting the check, and was wrong in the PERMISSIVE direction, which is the
# worse one — it promised less coverage than the pattern has, so a reader would
# not look.
#   * A wrapper in front does NOT hide the call: the prefix class is
#     `[^[:alnum:]_.]` and a space satisfies it, so `env`, `xargs`, `find -exec`,
#     `nohup`, `command` and an absolute `/usr/bin/touch` are all caught —
#     measured. `mytouch -d ` is not, which is the class doing its job.
#   * UNDER-matches: anything between the command word and the flag (`sed -E -i`,
#     `sed -n -i`, `touch -a -d`), a variable holding the command (`SED=sed;
#     $SED -i`), a line continuation between the two. The GNU long options USED to
#     be here and are now covered — they are the documented spellings, so they
#     were the likeliest way the fixed defect comes back.
#   * OVER-matches: this reads text, not code, and the filter below strips only
#     whole-line comments. A trailing `# … sed -i …`, an `echo`, an assertion
#     LABEL or a JSON payload on a non-exempt file reddens the gate. That is the
#     mechanism behind the ledger-gate.test.sh exemption, and it is live today:
#     tests/sandbox/purge.test.sh:41 explains the `-i.bak` form and contains the
#     literal spelling — it passes only because its `#` starts the line.
# DISCOVERY is filesystem + extension over four roots (skills tests hooks
# install), not `git ls-files`. Every tracked shell file is inside them today
# (no count here: the last one written was wrong the day it landed) — but a
# tracked `.sh` added at the repo root would fall
# outside silently, so the roots are the claim, not "everything tracked".
# Like the bare-timeout scan above, this is a tripwire for the forms this tree
# actually writes, not a parser.
GNU_TOUCH_D='(^|[^[:alnum:]_.])touch[[:space:]]+(-[[:alnum:]]*d[[:space:]@]|--date[=[:space:]])'
BSD_SED_I='(^|[^[:alnum:]_.])sed[[:space:]]+(-[[:alnum:]]*i[[:space:]]|--in-place([[:space:]]|$))'
mm_hits=""; mm_seen=0; mm_grepfail=""; mm_exempt=0; mm_checked=0
mm_list=$(mktemp "${TMPDIR:-/tmp}/loop-testing-mmlist.XXXXXX") || mm_list=""
mm_err=$(mktemp "${TMPDIR:-/tmp}/loop-testing-mmerr.XXXXXX") || mm_err=""
mm_find_rc=0
if [ -n "$mm_list" ] && [ -n "$mm_err" ]; then
  find skills tests hooks install -name '*.sh' -type f > "$mm_list" 2>"$mm_err"
  mm_find_rc=$?
  while IFS= read -r f; do
    mm_seen=$((mm_seen+1))
    for mm_pat in touch sed; do
      # Exemptions by path, each with its reason — the same remedy the WS_ALL and
      # bare-timeout gates use, for the same reason: a gate that reads source text
      # and forgets to exempt itself fails the fix instead of the bug.
      #   bash3.test.sh      — holds both patterns and both probes by construction
      #   tests/hooks/lib.sh — DEFINES the portable replacement, so the GNU form
      #                        lives there inside the fallback that wraps it
      #   ledger-gate.test.sh— its fixtures are shell COMMAND STRINGS handed to the
      #                        gate as input; `sed -i` there is data, never run.
      #                        The cost is measured and stated: the exemption is by
      #                        FILE, so an executed `sed -i` added to that file
      #                        would be missed too (injected one — the scan stayed
      #                        13/0). Not narrowed to a line-level exemption because
      #                        the spelling occurs there three ways — inside JSON
      #                        payloads, inside assertion LABELS, and in prose — so
      #                        the filter would grow into the parser this tripwire
      #                        is explicitly not. Counted, not tried: the three
      #                        shapes are what `grep -n 'sed -i'` on that file
      #                        returns, and no line-level filter was written.
      case "$mm_pat:$f" in
        *:tests/portability/bash3.test.sh)  mm_exempt=$((mm_exempt+1)); continue ;;
        touch:tests/hooks/lib.sh)           mm_exempt=$((mm_exempt+1)); continue ;;
        sed:tests/hooks/ledger-gate.test.sh) mm_exempt=$((mm_exempt+1)); continue ;;
      esac
      mm_checked=$((mm_checked+1))
      case "$mm_pat" in
        touch) mm_re="$GNU_TOUCH_D" ;;
        sed)   mm_re="$BSD_SED_I" ;;
      esac
      # grep's STATUS separated from its output: rc 2 (unreadable file, rejected
      # ERE) prints nothing and would otherwise read as a clean file.
      mm_out=$(grep -nE "$mm_re" "$f" 2>/dev/null); mm_rc=$?
      case "$mm_rc" in
        0) mm_out=$(printf '%s\n' "$mm_out" | grep -v '^[0-9]*:[[:space:]]*#')
           [ -n "$mm_out" ] && mm_hits="$mm_hits$(printf '%s\n' "$mm_out" | sed "s|^|  $f:|")
" ;;
        1) ;;
        *) mm_grepfail="$mm_grepfail $f($mm_rc)" ;;
      esac
    done
  done < "$mm_list"
fi
if [ "$mm_find_rc" -ne 0 ] || [ -s "$mm_err" ]; then
  FAIL=$((FAIL+1))
  echo "  FAIL: the macOS-matrix scan's discovery failed (find rc $mm_find_rc$( [ -s "$mm_err" ] && printf ', stderr: %s' "$(head -1 "$mm_err")" )) — a subtree it cannot read contributes no files and reads as clean" >&2
elif [ "$mm_seen" -eq 0 ]; then
  FAIL=$((FAIL+1)); echo "  FAIL: the macOS-matrix scan read no files at all" >&2
elif [ "$mm_seen" -ne "$(wc -l < "$mm_list")" ]; then
  # FIRST, ahead of the exemption tripwire, because this one cannot be satisfied
  # by widening the exemption list: it counts files VISITED against files
  # DISCOVERED and the exemptions happen inside the visit. Ordered the other way
  # the tripwire fires first and blames the exemption list for a loop that ended
  # early — measured with a stdin-eating line in the body: 1 file of 59 visited,
  # reported as "exempted 0, not 4".
  FAIL=$((FAIL+1))
  echo "  FAIL: the macOS-matrix scan visited $mm_seen of $(wc -l < "$mm_list") discovered files — the outer loop ended early, and every other arm would have called that clean" >&2
elif [ "$mm_exempt" -ne 4 ]; then
  # Four (pattern, file) exemption decisions per run: bash3.test.sh for BOTH
  # patterns, hooks/lib.sh for touch, ledger-gate.test.sh for sed. Hard-coded for
  # the same reason the bare-timeout scan's 2 is, and this scan shipped in the
  # same commit as that comment WITHOUT the guard: broadening the `case` above
  # satisfies the equality below either way — scanned equals discovered-minus-
  # exempt whatever the exemption list says — while a live `sed -i` goes unread.
  # Demonstrated by a reviewer: one added `case` line took an injected, executed
  # `sed -i` from 12/1 back to 13/0 with the call still in the tree. The number is
  # counted in (pattern, file) pairs, not files, so it does not move with the file
  # count: it is the policy, not a measurement of the tree.
  FAIL=$((FAIL+1))
  echo "  FAIL: the macOS-matrix scan exempted $mm_exempt (pattern, file) pairs, not 4 — if the exemption list changed, this number changes with it and the change gets read" >&2
elif [ "$mm_checked" -ne "$(( mm_seen * 2 - mm_exempt ))" ]; then
  # The inner half of the same check, and the reason it is separate: mm_seen says
  # the file loop finished, mm_checked says every (pattern, file) pair inside it
  # was actually grepped. A non-zero count says the loop STARTED; only the
  # equality says it FINISHED. This repo's incident is a body that reads stdin
  # eating the rest of the list — measured here at 1 file of 59 with every other
  # arm of this gate reporting clean.
  FAIL=$((FAIL+1))
  echo "  FAIL: the macOS-matrix scan grepped $mm_checked pairs, expected $(( mm_seen * 2 - mm_exempt )) — the inner loop ended early, and every other arm would have called that clean" >&2
elif [ -n "$mm_grepfail" ]; then
  FAIL=$((FAIL+1)); echo "  FAIL: the macOS-matrix scan could not read:$mm_grepfail" >&2
elif [ -n "$mm_hits" ]; then
  FAIL=$((FAIL+1))
  echo "  FAIL: GNU-only spellings that fail silently on BSD/macOS:" >&2
  printf '%s' "$mm_hits" >&2
else
  PASS=$((PASS+1))
fi
rm -f "$mm_list" "$mm_err"

# Positive and negative controls for both patterns. Assembled with %s so this
# file holds no matching line of its own — the same device the bare-timeout probe
# uses, and the reason this file is exempt from its own scan anyway.
mm_probe=$(mktemp "${TMPDIR:-/tmp}/loop-testing-mmprobe.XXXXXX")
printf '%s -d "@123" f\ncd x; %s -d @1 f\n%s -i '"'"'s/a/b/'"'"' f\ncd x && %s -i '"'"'s/a/b/'"'"' f\n' \
  touch touch sed sed > "$mm_probe"
# The long options and the attached forms, added with the widened EREs. These are
# the GNU spellings the manuals document, so they are the likeliest way the fixed
# defect comes back — and the narrow pair missed every one of them.
printf '%s\n' \
  'touch --date=@1 f' \
  'touch -d@1 f' \
  'touch -cd @1 f' \
  'sed --in-place '"'"'s/a/b/'"'"' f' \
  'sed --in-place' >> "$mm_probe"
mm_pos=$(( $(grep -cE "$GNU_TOUCH_D" "$mm_probe") + $(grep -cE "$BSD_SED_I" "$mm_probe") ))
printf '%s\n' \
  'touch -t 202601011200.00 f' \
  'touch -r "$ref" f' \
  'sed -i.bak '"'"'s/a/b/'"'"' f' \
  'set_mtime_epoch "$f" 123' \
  'sed '"'"'s/a/b/'"'"' f > f.tmp && mv f.tmp f' > "$mm_probe"
mm_neg=$(( $(grep -cE "$GNU_TOUCH_D" "$mm_probe") + $(grep -cE "$BSD_SED_I" "$mm_probe") ))
rm -f "$mm_probe"
if [ "${mm_pos:-0}" -eq 9 ] && [ "${mm_neg:-1}" -eq 0 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "  FAIL: self-probe — the macOS-matrix patterns matched ${mm_pos:-?}/9 positives and ${mm_neg:-?}/0 negatives" >&2
fi

echo "bash3.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
