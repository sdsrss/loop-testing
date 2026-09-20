#!/usr/bin/env bash
# loop-testing.test.sh — structural + parity guard for the /loop-testing entry point.
#
# These are PROMPT files (Claude skills/loop-testing/SKILL.md + Codex
# prompts/loop-testing.md); behavior can only be fully exercised by running the
# agent. This test locks the pieces that CAN be checked statically and that drift
# silently: the Claude frontmatter, the three-mode dispatch (empty=start/resume ·
# status · report), the two safety guards ("don't start a run" for status/report,
# "don't reset the round" on resume), and Claude<->Codex parity so the two files
# can't diverge unnoticed.
#
# WHY THE DISPATCH LIVES IN SKILL.md: it used to live in commands/loop-testing.md.
# Claude Code registers commands/*.md as flat SKILLS, in the same namespace as
# skills/*/SKILL.md — so `commands/loop-testing.md` (frontmatter name:
# loop-testing) and `skills/loop-testing/` BOTH claimed the name `loop-testing`,
# the commands/ copy won, and SKILL.md became unreachable through the slash
# command AND the trigger phrases. The command's own body said "invoke the
# `loop-testing` skill", which resolved back to itself. The two files are now one.
# `component_names_unique` below is the regression guard for the collision itself.
#
# The two files are deliberately written in DIFFERENT languages (SKILL.md is the
# Chinese product voice, the Codex prompt is English), so parity is asserted over
# the semantic elements each must carry, in its own spelling — not over identical
# English strings.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$REPO_ROOT/skills/loop-testing/SKILL.md"
PROMPT="$REPO_ROOT/prompts/loop-testing.md"

_fails=0
_pass=0
_failn=0
_name="${0##*/}"
pass() { printf '  ok: %s\n' "$1"; _pass=$((_pass + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; _fails=1; _failn=$((_failn + 1)); }
# whitespace-flattened substring match: markdown wraps phrases across lines, so
# collapse all runs of whitespace to a single space before matching.
has()  { if tr '[:space:]' ' ' < "$1" | tr -s ' ' | grep -qF -- "$2"; then pass "$3"; else fail "$3 (missing '$2' in ${1##*/})"; fi; }

# ── both files exist ───────────────────────────────────────────────────────────
[ -f "$SKILL" ]  && pass "claude skill file exists"  || fail "skills/loop-testing/SKILL.md missing"
[ -f "$PROMPT" ] && pass "codex prompt file exists"  || fail "prompts/loop-testing.md missing"

# ── the collision must not come back ──────────────────────────────────────────
# Every component Claude Code registers as a skill: skills/*/SKILL.md (name from
# the directory) and commands/*.md (name from the file). Two sharing a name means
# one silently shadows the other — the exact defect this file documents above.
component_names_unique() {
  local names="" n dup
  for d in "$REPO_ROOT"/skills/*/; do
    [ -f "$d/SKILL.md" ] || continue
    n="$(basename "$d")"; names="$names$n\n"
  done
  for f in "$REPO_ROOT"/commands/*.md; do
    [ -f "$f" ] || continue
    n="$(basename "$f" .md)"; names="$names$n\n"
  done
  dup="$(printf "$names" | sort | uniq -d)"
  if [ -n "$dup" ]; then
    fail "two plugin components register the same skill name: $dup — one will shadow the other"
  else
    pass "no two plugin components share a skill name"
  fi
}
component_names_unique

# the file that lost the collision must stay gone
if [ -e "$REPO_ROOT/commands/loop-testing.md" ]; then
  fail "commands/loop-testing.md is back — it re-collides with skills/loop-testing/"
else
  pass "commands/loop-testing.md stays removed (its dispatch lives in SKILL.md)"
fi

# ── Claude skill: YAML frontmatter (name must match the dir for discovery) ─────
if [ "$(head -1 "$SKILL")" = "---" ]; then pass "claude skill opens with YAML frontmatter"
else fail "claude skill must open with '---' frontmatter (line 1)"; fi
fm="$(awk 'NR>1 && /^---[[:space:]]*$/{exit} NR>1{print}' "$SKILL")"
printf '%s' "$fm" | grep -qE '^name:[[:space:]]*loop-testing[[:space:]]*$' \
  && pass "frontmatter name: loop-testing" || fail "frontmatter must set name: loop-testing"
printf '%s' "$fm" | grep -qE '^description:[[:space:]]*.+' \
  && pass "frontmatter has a description" || fail "frontmatter must have a description"

# ── three-mode dispatch present in BOTH files ─────────────────────────────────
for f in "$SKILL" "$PROMPT"; do
  n="${f##*/}"
  has "$f" '$ARGUMENTS' "$n dispatches on \$ARGUMENTS"
  has "$f" 'status'     "$n documents the status mode"
  has "$f" 'report'     "$n documents the report mode"
done
# resume / no-run / no-reset guards, each in the file's own language
has "$PROMPT" 'resume'                "prompt documents empty -> start/resume"
has "$PROMPT" 'do NOT start a run'    "prompt: status/report must not start a run"
has "$PROMPT" 'do NOT reset the round' "prompt: resume must not reset the round count"
has "$PROMPT" 'loop-testing` skill'   "prompt routes through the loop-testing skill"
has "$SKILL"  '续跑'                   "SKILL documents empty -> start/resume"
has "$SKILL"  '禁止开跑'                "SKILL: status/report must not start a run"
has "$SKILL"  '禁止重置轮数'             "SKILL: resume must not reset the round count"

# ── guards anchored to their OWN mode block, not just present anywhere (R50) ────
# A reordering edit that keeps every token but moves the no-run guard out of the
# status/report blocks (so `status` could start a run) used to pass the global
# greps above. Extract each top-level bullet block and assert the guard lives
# INSIDE the right block.
block() { # file start-regex -> the bullet block from the matching '- ' line to the next '- '
  awk -v s="$2" '
    !inb && $0 ~ s { inb=1; print; next }
    inb && /^- /   { exit }
    inb            { print }
  ' "$1"
}
block_has() { # file start-regex needle label
  if block "$1" "$2" | tr '[:space:]' ' ' | tr -s ' ' | grep -qF "$3"; then pass "$4"
  else fail "$4 (block '$2' in ${1##*/} lacks '$3')"; fi
}
block_has "$PROMPT" '^- \*\*.*status' 'do NOT start a run' "prompt: no-run guard sits INSIDE the status block"
block_has "$PROMPT" '^- \*\*.*report' 'do NOT start a run' "prompt: no-run guard sits INSIDE the report block"
block_has "$PROMPT" '^- \*\*.*(empty|start)' 'do NOT reset the round' "prompt: no-reset guard sits INSIDE the start/resume block"
block_has "$PROMPT" '^- \*\*.*(empty|start)' 'skill' "prompt: skill routing sits INSIDE the start/resume block"
block_has "$PROMPT" '^- \*\*.*(empty|start)' 'start from round 0' "prompt: default (empty arg) still starts a full loop from round 0"
block_has "$SKILL" '^- \*\*.*`status`' '禁止开跑' "SKILL: no-run guard sits INSIDE the status block"
block_has "$SKILL" '^- \*\*.*`report`' '禁止开跑' "SKILL: no-run guard sits INSIDE the report block"
block_has "$SKILL" '^- \*\*.*空参数' '禁止重置轮数' "SKILL: no-reset guard sits INSIDE the start/resume block"
block_has "$SKILL" '^- \*\*.*空参数' '第 0 轮开始' "SKILL: default (empty arg) still starts a full loop from round 0"

# ── optional scope hints: focus + round cap (additive; must not change default) ──
for f in "$SKILL" "$PROMPT"; do
  n="${f##*/}"
  has "$f" 'focus'         "$n documents the optional focus/scope hint"
  has "$f" '最多 3 轮'      "$n gives the round-cap usage example"
  has "$f" 'max_rounds: N' "$n round-cap hint writes max_rounds into STATE.md"
done

# ── README / template / skill text contradictions (audit 2026-09-20 K-01/K-02/K-05/D-04) ──
README_EN="$REPO_ROOT/README.md"
README_ZH="$REPO_ROOT/README.zh-CN.md"
TEMPLATE="$REPO_ROOT/skills/loop-testing/templates/FINAL_REPORT.md"

for f in "$README_EN" "$README_ZH"; do
  n="${f##*/}"
  # D-04: the permission mode the drivers actually use must be disclosed where the
  # drivers are documented — the exact flags, so a reader can grep the driver for them.
  has "$f" '--permission-mode bypassPermissions' "$n discloses the Claude driver's bypassPermissions mode (D-04)"
  has "$f" '-s danger-full-access' "$n discloses the Codex driver's danger-full-access sandbox (D-04)"
done

# ── K-05: the purge block has to WORK when pasted, not merely mention SKILL_DIR ─
# The guard that used to live here asserted only "a SKILL_DIR= line appears before
# the first use of $SKILL_DIR". That passes on lines that DO NOT PARSE, which is
# why it stayed green while both READMEs were broken: in
#   SKILL_DIR=~/.claude/plugins/cache/…/<version>/skills/loop-testing
# bash reads `<version>` as a redirection, so the value is truncated at `<` (the
# English file kept `…/loop-testing/`, and the purge silently hit a path that does
# not exist) or left empty (the Chinese file, which then ran `/scripts/sandbox-clean.sh`).
# So: run the documented block in a real bash, against fixture installs, and assert
# on where it actually lands. Every fixture $HOME contains a space on purpose.
extract_purge_block() { # readme -> the ```bash fence that assigns SKILL_DIR
  awk '
    /^```bash$/    { inb=1; buf=""; next }
    inb && /^```$/ { if (buf ~ /SKILL_DIR=/) { printf "%s", buf; found=1; exit } inb=0; next }
    inb            { buf = buf $0 "\n" }
    END            { if (!found) exit 1 }
  ' "$1"
}

# The glob's own segments must come from the manifests, not from agreement.
# `cache` is Claude Code's layout; the marketplace segment and the version segment
# are varied by fixtures below. The remaining two — the PLUGIN name and the SKILL
# directory name — were pinned identically in the documented glob and in the
# fixture, derived from nothing, so renaming the plugin in .claude-plugin/plugin.json
# left every assertion green while the documented path went stale. Derive both.
plugin_name=$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$REPO_ROOT/.claude-plugin/plugin.json" \
              | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')
skill_name=""; skill_count=0
for d in "$REPO_ROOT"/skills/*/; do
  [ -f "$d/SKILL.md" ] || continue
  skill_name="$(basename "$d")"; skill_count=$((skill_count+1))
done
[ -n "$plugin_name" ] && pass "read the plugin name from .claude-plugin/plugin.json ($plugin_name)" \
                      || fail "could not read a plugin name from .claude-plugin/plugin.json"
[ "$skill_count" -eq 1 ] && pass "exactly one skills/*/SKILL.md defines the skill dir name ($skill_name)" \
                         || fail "expected exactly one skills/*/SKILL.md, found $skill_count"
expected_glob="\"\$HOME\"/.claude/plugins/cache/*/$plugin_name/*/skills/$skill_name"

K5=$(mktemp -d "${TMPDIR:-/tmp}/loop-testing-k05.XXXXXX")
trap 'rm -rf "$K5"' EXIT
mkdir -p "$K5/neutral"
mk_install() { mkdir -p "$1/scripts"; printf '#!/usr/bin/env bash\necho "STUB-CLEAN $*"\n' > "$1/scripts/sandbox-clean.sh"; }

# Run the block verbatim. stdout collects the candidate listing (and any stub that
# ran); stderr goes to $K5/err, where a careless paste must name the placeholder.
run_block() { # blockfile home codexhome cwd
  if [ -n "$3" ]; then ( cd "$4" && HOME="$2" CODEX_HOME="$3" bash "$1" ) 2>"$K5/err"
  else                 ( cd "$4" && HOME="$2" env -u CODEX_HOME bash "$1" ) 2>"$K5/err"; fi
}

# CODEX_HOME set as a PLAIN SHELL VARIABLE, never exported. `bash -c` inherits
# only exported variables, so a listing that reads $CODEX_HOME inside the quoted
# `bash -c` string would silently fall back to ~/.codex here — the same class of
# bug as the hardcoded path, and invisible to every other case in this file. The
# block must therefore re-export it on the command itself.
run_block_unexported() { # blockfile home codexhome cwd
  ( cd "$4" && HOME="$2" env -u CODEX_HOME \
      bash -c 'CODEX_HOME="$1"; . "$2"' _ "$3" "$1" ) 2>"$K5/err"
}

# the reader pastes into a script with `set -euo pipefail`, or into zsh, whose
# default `nomatch` cancels a command carrying an unmatched glob (emulated here
# with bash's failglob, the closest bash equivalent).
run_block_opts() { # blockfile home cwd shellopts
  ( cd "$3" && HOME="$2" env -u CODEX_HOME bash -c "$4"' ; . "$1"' _ "$1" ) 2>"$K5/err"
}

# every path the block prints must be a real, readable install
assert_all_candidates_readable() { # listing label
  local line bad=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ -r "$line/scripts/sandbox-clean.sh" ] || { bad=1; echo "  (unreadable candidate: $line)" >&2; }
  done <<EOF
$1
EOF
  if [ "$bad" -eq 0 ]; then pass "$2: every printed candidate has a readable scripts/sandbox-clean.sh"
  else fail "$2: the block printed a path with no readable scripts/sandbox-clean.sh"; fi
}

for f in "$README_EN" "$README_ZH"; do
  n="${f##*/}"
  blk="$K5/block-$n.sh"
  if extract_purge_block "$f" > "$blk" && [ -s "$blk" ]; then
    pass "$n: the purge section has a bash block that assigns SKILL_DIR"
  else
    fail "$n: no fenced bash block assigns SKILL_DIR — the K-05 harness cannot run"
    continue
  fi

  # THE regression: the placeholder must be QUOTED. Unquoted, `<...>` is a
  # redirection and the assignment never carries the text the reader was told to
  # replace; quoted, a careless paste fails naming the placeholder instead.
  if grep -qE '^SKILL_DIR="' "$blk"; then pass "$n: SKILL_DIR is assigned a quoted value"
  else fail "$n: SKILL_DIR must be assigned a QUOTED value — unquoted <placeholder> parses as a redirection (K-05)"; fi

  # the documented glob must name what the manifests actually say
  cacheline=$(grep -F '.claude/plugins/cache/' "$blk" | head -1 \
              | sed 's/^[[:space:]]*//; s/[[:space:]]*\\$//; s/[[:space:]]*$//')
  if [ "$cacheline" = "$expected_glob" ]; then
    pass "$n: the cache glob matches the plugin + skill names the manifests declare"
  else
    fail "$n: the documented glob does not match the manifests — expected [$expected_glob], README has [$cacheline]"
  fi

  # fixture 1 — Codex default layout, no CODEX_HOME
  H="$K5/case-codex/a home dir"; mk_install "$H/.codex/skills/loop-testing"
  outA=$(run_block "$blk" "$H" "" "$K5/neutral")
  cands=$(printf '%s\n' "$outA" | grep -F "$K5/case-codex" || true)
  printf '%s\n' "$cands" | grep -qxF "$H/.codex/skills/loop-testing" \
    && pass "$n: lists the default Codex install (space in \$HOME survives)" \
    || fail "$n: default Codex install not listed (got: $cands)"

  # fixture 2 — CODEX_HOME pointed somewhere else, in all three export states
  H2="$K5/case-codexhome/a home dir"; CH="$K5/case-codexhome/a codex home"
  mkdir -p "$H2"; mk_install "$CH/skills/loop-testing"
  outB=$(run_block "$blk" "$H2" "$CH" "$K5/neutral")
  printf '%s\n' "$outB" | grep -qxF "$CH/skills/loop-testing" \
    && pass "$n: honours an exported CODEX_HOME instead of ~/.codex" \
    || fail "$n: exported CODEX_HOME install not listed (got: $outB)"
  outB2=$(run_block_unexported "$blk" "$H2" "$CH" "$K5/neutral")
  printf '%s\n' "$outB2" | grep -qxF "$CH/skills/loop-testing" \
    && pass "$n: honours a CODEX_HOME that is set but NOT exported" \
    || fail "$n: CODEX_HOME set but not exported fell back to the default (got: $outB2)"
  # unset is fixture 1's path; assert here that it really is the default, not ""
  H2D="$K5/case-codexunset/a home dir"; mk_install "$H2D/.codex/skills/loop-testing"
  outB3=$(run_block "$blk" "$H2D" "" "$K5/neutral")
  printf '%s\n' "$outB3" | grep -qxF "$H2D/.codex/skills/loop-testing" \
    && pass "$n: with CODEX_HOME unset, falls back to \$HOME/.codex" \
    || fail "$n: unset CODEX_HOME did not fall back to \$HOME/.codex (got: $outB3)"

  # fixture 3 — plugin cache holding several versions, one of them a commit SHA.
  # The block must PRINT them all and pick none: 0.9.0 sorts after 0.10.0
  # lexically and a SHA has no order at all, so there is nothing safe to sort by.
  H3="$K5/case-cache/a home dir"; C3="$H3/.claude/plugins/cache/loop-testing/loop-testing"
  mk_install "$C3/0.10.0/skills/loop-testing"
  mk_install "$C3/0.9.0/skills/loop-testing"
  mk_install "$C3/022b3c274938/skills/loop-testing"
  outC=$(run_block "$blk" "$H3" "" "$K5/neutral")
  nC=$(printf '%s\n' "$outC" | grep -c "^$C3/" || true)
  if [ "$nC" -eq 3 ]; then pass "$n: prints all three cached versions, choosing none"
  else fail "$n: expected 3 cached candidates, got $nC ($outC)"; fi
  assert_all_candidates_readable "$outC" "$n"

  # fixture 3b — the marketplace segment is a wildcard for a reason. A fixture
  # built under `cache/loop-testing/loop-testing/` cannot tell a correct glob from
  # one that hardcodes this repo's own marketplace name, so use a different name
  # here: the guard must follow the block, not agree with the fixture.
  H3B="$K5/case-othermarket/a home dir"
  mk_install "$H3B/.claude/plugins/cache/some-other-marketplace/loop-testing/1.2.3/skills/loop-testing"
  outC2=$(run_block "$blk" "$H3B" "" "$K5/neutral")
  printf '%s\n' "$outC2" | grep -qxF "$H3B/.claude/plugins/cache/some-other-marketplace/loop-testing/1.2.3/skills/loop-testing" \
    && pass "$n: finds an install under a differently-named marketplace dir" \
    || fail "$n: the marketplace path segment is hardcoded, not globbed (got: $outC2)"

  # fixture 3c — CODEX_HOME given as a RELATIVE path. The listing happens in one
  # directory and the purge runs later from the target repo, so a relative hit
  # would bind somewhere else by then. Every printed line must be absolute.
  H3C="$K5/case-relative/a home dir"; mkdir -p "$H3C"
  mk_install "$K5/case-relative/rel codex/skills/loop-testing"
  outC3=$( cd "$K5/case-relative" && HOME="$H3C" CODEX_HOME="rel codex" bash "$blk" 2>/dev/null )
  printf '%s\n' "$outC3" | grep -qxF "$K5/case-relative/rel codex/skills/loop-testing" \
    && pass "$n: a relative CODEX_HOME is printed as an absolute path" \
    || fail "$n: relative CODEX_HOME printed a path that binds elsewhere at purge time (got: $outC3)"

  # fixture 4 — a clone you are standing in
  H4="$K5/case-clone/a home dir"; CL="$K5/case-clone/a clone dir"
  mkdir -p "$H4"; mk_install "$CL/skills/loop-testing"
  outD=$(run_block "$blk" "$H4" "" "$CL")
  printf '%s\n' "$outD" | grep -qxF "$CL/skills/loop-testing" \
    && pass "$n: lists the clone you are standing in" \
    || fail "$n: clone install not listed (got: $outD)"

  # fixture 5 — nothing installed anywhere
  H5="$K5/case-none/a home dir"; mkdir -p "$H5"
  outE=$(run_block "$blk" "$H5" "" "$K5/neutral")
  nE=$(printf '%s' "$outE" | grep -c . || true)
  if [ "$nE" -eq 0 ]; then pass "$n: with nothing installed the block lists nothing"
  else fail "$n: with nothing installed the block still printed: $outE"; fi

  # the careless paste — block run WITHOUT editing the placeholder. It must not
  # execute anything, and must fail naming the placeholder (this is the property
  # the unquoted version lacked: it bound an empty/truncated path and ran it).
  if printf '%s' "$outA" | grep -qF 'STUB-CLEAN'; then
    fail "$n: an unedited paste RAN sandbox-clean — the placeholder must not resolve (K-05)"
  else pass "$n: an unedited paste runs no sandbox-clean"; fi
  if grep -qF 'paste one of the paths printed above' "$K5/err"; then
    pass "$n: an unedited paste fails naming the placeholder"
  else fail "$n: an unedited paste must fail naming the placeholder, stderr was: $(cat "$K5/err")"; fi

  # pasted into a `set -euo pipefail` script: `ls` returns non-zero for every
  # install the reader does not have, which is the normal case, so without the
  # `|| true` the shell exits and step 3 never happens.
  outG=$(run_block_opts "$blk" "$H" "$K5/neutral" 'set -euo pipefail')
  printf '%s\n' "$outG" | grep -qxF "$H/.codex/skills/loop-testing" \
    && pass "$n: under set -euo pipefail the listing still prints" \
    || fail "$n: set -e aborted the listing (got: $outG)"
  if grep -qF 'paste one of the paths printed above' "$K5/err"; then
    pass "$n: under set -euo pipefail the block still reaches the purge step"
  else fail "$n: set -e stopped the block before step 3 — the listing must not exit non-zero (the old 'ls -d' form did, once per install you lack)"; fi

  # pasted into a shell that cancels commands carrying an unmatched glob (zsh's
  # default nomatch; bash's failglob here). The Codex install exists and must
  # still be printed even though the plugin-cache glob matches nothing.
  outH=$(run_block_opts "$blk" "$H" "$K5/neutral" 'shopt -s failglob')
  printf '%s\n' "$outH" | grep -qxF "$H/.codex/skills/loop-testing" \
    && pass "$n: an unmatched glob does not swallow the whole listing" \
    || fail "$n: failglob/nomatch cancelled the listing, hiding a real install (got: $outH)"

  # and the edited paste — the reader substitutes a printed line and purges.
  chosen=$(printf '%s\n' "$outC" | grep "^$C3/" | sed -n '2p')
  awk -v c="$chosen" '/^SKILL_DIR=/ { print "SKILL_DIR=\"" c "\""; next } { print }' "$blk" > "$K5/edited.sh"
  outF=$(run_block "$K5/edited.sh" "$H3" "" "$K5/neutral")
  printf '%s' "$outF" | grep -qF 'STUB-CLEAN --purge' \
    && pass "$n: substituting a printed path purges with that install" \
    || fail "$n: edited paste did not reach sandbox-clean --purge (got: $outF)"
done
# ...and the disclosure must not be stale: the drivers must still use exactly those flags.
grep -qF -- '--permission-mode bypassPermissions' "$REPO_ROOT/skills/loop-testing/scripts/unattended-loop.sh" \
  && pass "unattended-loop.sh still launches with bypassPermissions (README disclosure is current)" \
  || fail "unattended-loop.sh no longer uses --permission-mode bypassPermissions — update the README permission paragraph"
grep -qF -- '-s danger-full-access' "$REPO_ROOT/skills/loop-testing/scripts/unattended-codex.sh" \
  && pass "unattended-codex.sh still launches with danger-full-access (README disclosure is current)" \
  || fail "unattended-codex.sh no longer uses -s danger-full-access — update the README permission paragraph"

# K-02: the template is what the model instantiates; its header said "run
# sandbox-clean BEFORE the report", the reference (exit-and-report.md §4) says
# report → terminal status → clean, and names clean-first as the unguarded window.
if grep -qF '报告前先执行' "$TEMPLATE"; then fail "FINAL_REPORT template tells the model to clean BEFORE the report (K-02)"
else pass "FINAL_REPORT template no longer orders clean before the report"; fi
has "$TEMPLATE" '最后才执行 `sandbox-clean`' "FINAL_REPORT template puts sandbox-clean LAST, matching exit-and-report.md §4"
has "$TEMPLATE" '写为终态' "FINAL_REPORT template names the terminal-status write between report and clean"

# K-01: the script-not-found fallback told the model to isolate with a manual
# `git worktree`, which round-0.md §7 forbids and whose isolation gate (ownership.env)
# a manual worktree can never pass. The fallback must now stop with BLOCKED, and give
# deterministic locate steps first.
# The section is a single blockquote line headed `> **脚本与模板定位`; anchor on the
# header, not on the phrase (an earlier paragraph cross-references it by name).
fb="$(grep -F '> **脚本与模板定位' "$SKILL")"
[ -n "$fb" ] && pass "SKILL.md has the 脚本与模板定位 blockquote (fallback section present)" \
             || fail "SKILL.md lost the '> **脚本与模板定位' blockquote — the K-01 assertions below would pass vacuously"
if printf '%s' "$fb" | grep -qF '用 `git worktree` 或 `qa/loop-testing` 分支隔离'; then
  fail "SKILL.md fallback still tells the model to build a manual git worktree (K-01)"
else pass "SKILL.md fallback no longer suggests a manual git worktree"; fi
printf '%s' "$fb" | grep -qF 'status: BLOCKED' \
  && pass "SKILL.md fallback stops with BLOCKED when sandbox-setup.sh cannot be located" \
  || fail "SKILL.md fallback must end in status: BLOCKED, not a hand-built sandbox (K-01)"
printf '%s' "$fb" | grep -qF "plugins/cache/*/$plugin_name/*/skills/$skill_name" \
  && pass "SKILL.md fallback's locate step names the manifest plugin + skill names" \
  || fail "SKILL.md fallback's plugin-cache glob does not match the manifests (want cache/*/$plugin_name/*/skills/$skill_name)"
printf '%s' "$fb" | grep -qF 'ownership.env' \
  && pass "SKILL.md fallback explains why a manual worktree fails the isolation gate" \
  || fail "SKILL.md fallback must mention the ownership.env gate"

# K-12: the template is instantiated verbatim, so anything the reference doc
# (exit-and-report.md §5) requires and the template does not carry is a section
# the model will not write. Two were missing outright, the red-line sentence was
# short of two forbidden operations, and the commit list did not ask for the one
# disclosure that matters. Each assertion below anchors a phrase the correct text
# must contain and the previous text did not.
REF="$REPO_ROOT/skills/loop-testing/references/exit-and-report.md"
has "$TEMPLATE" '既有/环境问题' "FINAL_REPORT template carries the pre-existing/environment section (exit-and-report.md §5.7)"
has "$TEMPLATE" '验证清单' "FINAL_REPORT template carries the verification checklist (exit-and-report.md §5.8)"
has "$TEMPLATE" '未执行项与原因' "the checklist asks for what was NOT run, and why"
has "$TEMPLATE" '逐分支列出' "the commit list is per-branch (exit-and-report.md §5.9)"
has "$TEMPLATE" '主分支上的提交必须在此显式披露' "and a commit on the main branch must be disclosed explicitly"
has "$TEMPLATE" 'amend / rebase' "the red-line declaration includes amend and rebase, like SKILL.md"
# The reference doc has no P3-only section; the template had one, which put the
# same issues in two places (§4 is already ordered P0->P3) and invited a split
# where the ordered list ends and the leftovers begin.
if grep -qF '遗留低级问题' "$TEMPLATE"; then
  fail "FINAL_REPORT template still has a P3-only section the reference doc does not define (K-12)"
else pass "FINAL_REPORT template has no section the reference doc does not define"; fi
# Both scripts' red lines must say the same thing: the template is where the
# claim gets written down, SKILL.md is where the rule lives.
has "$SKILL" 'force / amend / rebase' "SKILL.md still carries the red line the template now mirrors"
# If the reference doc ever drops these, the assertions above would pin the
# template to a contract that no longer exists — so anchor the source too.
has "$REF" '既有/环境问题' "exit-and-report.md still requires the pre-existing/environment section"
has "$REF" '验证清单' "exit-and-report.md still requires the verification checklist"

# K-13: the target has to be a git repository — sandbox-setup.sh exits 3 without
# one and round-0's isolation gate then stops the run as BLOCKED. The README never
# said so, in either language, so the first thing a user learned about the
# prerequisite was a refusal.
for _rm in "$REPO_ROOT/README.md" "$REPO_ROOT/README.zh-CN.md"; do
  _rn="${_rm##*/}"
  if tr '[:space:]' ' ' < "$_rm" | tr -s ' ' | grep -qF 'git init'; then
    pass "$_rn states the git prerequisite with the command that satisfies it"
  else fail "$_rn does not tell the user the target must be a git repository (K-13)"; fi
  if tr '[:space:]' ' ' < "$_rm" | tr -s ' ' | grep -qF 'not a git repository'; then
    pass "$_rn quotes the refusal the user would otherwise meet first"
  else fail "$_rn does not quote sandbox-setup.sh's non-git refusal (K-13)"; fi
done
# The quoted refusal has to be the one the script actually prints.
if grep -qF 'not a git repository — refusing to build a sandbox that cannot be isolated' \
     "$REPO_ROOT/skills/loop-testing/scripts/sandbox-setup.sh"; then
  pass "sandbox-setup.sh still prints the refusal the READMEs quote"
else fail "sandbox-setup.sh's non-git refusal no longer matches the README text (K-13)"; fi

finish() {
  printf '%s: %d passed, %d failed\n' "$_name" "$_pass" "$_failn"
  [ "$_fails" -eq 0 ]
}
finish
