#!/usr/bin/env bash
# loop-testing ledger-gate — PreToolUse hook (Write | Edit | MultiEdit | Bash).
#
# Raises the cost of faking a VERIFIED verdict in the issue ledger. Per the
# state protocol (references/issue-rules.md §7), an ISSUE may reach VERIFIED
# ONLY by replaying its reproduction steps, with the replay recorded that round
# in runs/round-N.md. This hook denies a write that stamps `VERIFIED` onto an
# ISSUE in docs/looptesting/ISSUES.md when that ISSUE-ID has NO replay footprint
# in ANY runs/round-*.md log — the high-confidence "verified out of thin air"
# case.
#
# DESIGN POSITION (architecture §2.4): this is a cheat-cost raiser, NOT a
# complete gate. It deliberately checks "any round log mentions the ID" rather
# than "this exact round replayed it", to stay conservative — 宁可放过不可误杀
# (prefer a miss over a false-positive). A model that first writes a fake replay
# line into a round log can still get past it, and so can a Bash write through a
# verb this hook does not bind to the ledger (mv/cp/dd/python onto the path); that
# residual is covered by the red lines in the prompt and human diff review, not
# by this hook. Reads are never denied: a Bash command counts as a ledger write
# only when a redirection, `tee`, or an in-place sed/perl names the ledger.
#
# Fails OPEN on any parse problem or missing tooling — a gate must never brick a
# session. Escape hatch (humans, not models): LOOP_TESTING_DISABLE_LEDGER_GATE=1.
set -u

if [ "${LOOP_TESTING_DISABLE_LEDGER_GATE:-0}" = "1" ]; then
  cat > /dev/null; exit 0
fi

INPUT=$(cat)

# --- anchor to the project root (audit HK-7) ----------------------------------
# Same anchoring as stop-gate.sh: the hook cwd is not guaranteed to be the
# project root, and this gate's armed-check (.active) and replay lookup (runs/)
# are cwd-relative. Precedence: $CLAUDE_PROJECT_DIR -> stdin "cwd" -> stay put.
BASE="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$BASE" ] && command -v jq >/dev/null 2>&1; then
  BASE=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
fi
if [ -z "$BASE" ]; then
  BASE=$(printf '%s' "$INPUT" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi
if [ -n "$BASE" ] && [ -d "$BASE" ]; then
  cd "$BASE" 2>/dev/null || true   # unresolvable -> stay in cwd (legacy)
fi

TOOL=""; FILE=""; NEWSTR=""; CONTENT=""; CMD=""; OLDSTR=""
if command -v jq >/dev/null 2>&1; then
  TOOL=$(printf '%s' "$INPUT"    | jq -r '.tool_name // empty'                 2>/dev/null) || TOOL=""
  FILE=$(printf '%s' "$INPUT"    | jq -r '.tool_input.file_path // empty'      2>/dev/null) || FILE=""
  NEWSTR=$(printf '%s' "$INPUT"  | jq -r '.tool_input.new_string // empty'     2>/dev/null) || NEWSTR=""
  CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty'        2>/dev/null) || CONTENT=""
  # MultiEdit: concatenate every edit's new_string so multi-edit writes are seen.
  MULTI=$(printf '%s' "$INPUT"   | jq -r '(.tool_input.edits // [])[].new_string // empty' 2>/dev/null) || MULTI=""
  NEWSTR="$NEWSTR
$MULTI"
  # old_string(s): used only to resolve the ISSUE-ID a minimal VERIFIED edit flips.
  OLDSTR=$(printf '%s' "$INPUT"  | jq -r '.tool_input.old_string // empty'     2>/dev/null) || OLDSTR=""
  MULTIOLD=$(printf '%s' "$INPUT" | jq -r '(.tool_input.edits // [])[].old_string // empty' 2>/dev/null) || MULTIOLD=""
  OLDSTR="$OLDSTR
$MULTIOLD"
  CMD=$(printf '%s' "$INPUT"     | jq -r '.tool_input.command // empty'        2>/dev/null) || CMD=""
elif command -v python3 >/dev/null 2>&1; then
  PARSED=$(printf '%s' "$INPUT" | python3 -c '
import json,sys,shlex
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
ti=d.get("tool_input") or {}
multi="\n".join((e or {}).get("new_string","") for e in (ti.get("edits") or []))
multiold="\n".join((e or {}).get("old_string","") for e in (ti.get("edits") or []))
print("TOOL=%s"    % shlex.quote(str(d.get("tool_name",""))))
print("FILE=%s"    % shlex.quote(str(ti.get("file_path",""))))
print("NEWSTR=%s"  % shlex.quote(str(ti.get("new_string",""))+"\n"+multi))
print("OLDSTR=%s"  % shlex.quote(str(ti.get("old_string",""))+"\n"+multiold))
print("CONTENT=%s" % shlex.quote(str(ti.get("content",""))))
print("CMD=%s"     % shlex.quote(str(ti.get("command",""))))
' 2>/dev/null) || PARSED=""
  eval "$PARSED"
else
  echo "loop-testing ledger-gate: no jq or python3; gate inactive for this call." >&2
  exit 0
fi

# The text this tool call would introduce, and whether it targets the ledger.
TEXT=""; TARGETS_LEDGER=0; LT_DIR=""; INPLACE=0
is_issues_path() { case "$1" in */docs/looptesting/ISSUES.md|docs/looptesting/ISSUES.md) return 0 ;; *) return 1 ;; esac; }

case "$TOOL" in
  Write|Edit|MultiEdit)
    if is_issues_path "$FILE"; then
      TARGETS_LEDGER=1
      TEXT="$NEWSTR
$CONTENT"
      LT_DIR="$(dirname "$FILE")"
    fi ;;
  Bash)
    # A command is a WRITE only when the verb itself targets the ledger (audit
    # H-01): a redirection whose target is the ledger path, `tee` naming it, or an
    # in-place `sed -i` / `perl -i` naming it. Merely mentioning the path, an ID and
    # VERIFIED in a read (`grep … ISSUES.md 2>/dev/null`, `sed -n`) used to be
    # denied with the red-line accusation. Anchor to the loop path (or a bare
    # ISSUES.md only while the loop is armed in cwd = project root) so an unrelated
    # project using the same convention on its own ISSUES.md is never denied.
    # `\b` is avoided on purpose: BSD grep does not honor it (H-07).
    if [ -f docs/looptesting/.active ]; then LP='(docs/looptesting/)?ISSUES\.md'; else LP='docs/looptesting/ISSUES\.md'; fi
    WB='(^|[^[:alnum:]_])'
    # In-place editors reach EXISTING rows, so they are also the H-04 shape (a
    # substitution that introduces VERIFIED without naming an ID). The span is
    # not stopped at `|` — sed scripts on this ledger contain the column pipes.
    if printf '%s' "$CMD" | grep -qaE "${WB}(sed|perl)[[:space:]]+([^;&]*[[:space:]]+)?(-[[:alpha:]]*i([^[:alnum:]]|$)|--in-place)[^;&]*${LP}"; then
      TARGETS_LEDGER=1; INPLACE=1
    elif printf '%s' "$CMD" | grep -qaE ">>?[[:space:]]*[\"']?[^[:space:]|;&>]*${LP}|${WB}tee[[:space:]][^|;&]*[[:space:]][\"']?[^[:space:]|;&]*${LP}"; then
      TARGETS_LEDGER=1
    fi
    if [ "$TARGETS_LEDGER" -eq 1 ]; then
      TEXT="$CMD"
      LT_DIR="docs/looptesting"
    fi ;;
esac

[ "$TARGETS_LEDGER" -eq 1 ] || exit 0

# Does the introduced text set a genuine VERIFIED status token? Match case-
# sensitively — the status token is always uppercase, and `-i` false-DENIED prose
# like "not yet verified" / "could not be VERIFIED" in an OPEN issue's title (HK-2).
# For a file write the ledger row is `### ISSUE-NNN | Pn | STATUS | title`, so the
# status token is anchored to the STATUS column (after a `|`, or the whole minimal
# `FIXED_UNVERIFIED`->`VERIFIED` edit) — a bare "VERIFIED" in the free-text title
# column must NOT trip it, and *_UNVERIFIED (preceded by `_`, not `|`) is excluded.
# For a Bash command VERIFIED can appear in sed/perl substitution syntax
# (s/OPEN/VERIFIED/) rather than a column, so keep a word-boundary match there.
if [ "$TOOL" = "Bash" ]; then
  VLINES=$(printf '%s\n' "$TEXT" | grep -awE 'VERIFIED') || exit 0
else
  STATUS_RE='(^|\|)[[:space:]]*VERIFIED[[:space:]]*($|\|)'
  VLINES=$(printf '%s\n' "$TEXT" | grep -aE "$STATUS_RE") || exit 0
fi

# Which ISSUE is being marked? The ID is the ledger row's LEADING column
# (`### ISSUE-NNN | …`), never an ID cited in the free-text title — a legitimate
# "dup of ISSUE-002" title used to be checked against ISSUE-002's footprint and
# false-denied (audit H-05). Resolution order, first non-empty wins:
#   1. header-form IDs on the VERIFIED lines being introduced;
#   2. header-form IDs in the edit's old_string;
#   3. the ISSUE header enclosing old_string's first line in the target ledger
#      (the minimal "FIXED_UNVERIFIED" -> "VERIFIED" edit carries no ID at all);
#   4. any ID on the VERIFIED lines, then any ID in old_string — for shapes with
#      no row header, e.g. `perl -i -pe 's/OPEN/VERIFIED/ if /ISSUE-014/'`.
# Best-effort — an unresolvable ID falls through to allow (documented residual),
# except for the in-place shape below.
HDR_RE='###[[:space:]]*ISSUE-[0-9]+'
IDS=$(printf '%s\n' "$VLINES" | grep -aoE "$HDR_RE" | grep -aoE 'ISSUE-[0-9]+' | sort -u)
if [ -z "$IDS" ]; then
  IDS=$(printf '%s\n' "$OLDSTR" | grep -aoE "$HDR_RE" | grep -aoE 'ISSUE-[0-9]+' | sort -u)
fi
if [ -z "$IDS" ] && [ "$TOOL" != "Bash" ] && [ -f "$FILE" ]; then
  anchor=$(printf '%s\n' "$OLDSTR" | grep -m1 -a . || true)
  if [ -n "$anchor" ]; then
    ln=$(grep -naF -- "$anchor" "$FILE" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -n "$ln" ]; then
      IDS=$(head -n "$ln" "$FILE" | grep -aoE '^### ISSUE-[0-9]+' | grep -aoE 'ISSUE-[0-9]+' | tail -1)
    fi
  fi
fi
if [ -z "$IDS" ]; then
  IDS=$(printf '%s\n' "$VLINES" | grep -aoE 'ISSUE-[0-9]+' | sort -u)
fi
if [ -z "$IDS" ]; then
  IDS=$(printf '%s\n' "$OLDSTR" | grep -aoE 'ISSUE-[0-9]+' | sort -u)
fi

RUNS_DIR="$LT_DIR/runs"
deny() {
  {
    echo "loop-testing ledger-gate DENIED: $1"
    echo "An ISSUE may become VERIFIED only by REPLAYING its reproduction steps,"
    echo "with the replay (command + output) recorded this round in"
    echo "$RUNS_DIR/round-N.md (references/issue-rules.md §7). No such replay"
    echo "record exists for the ID(s) above. Reproduce, record the replay in the"
    echo "round log, THEN set VERIFIED. Weakening/faking verification is a red line."
    echo "(Human escape hatch: LOOP_TESTING_DISABLE_LEDGER_GATE=1.)"
  } >&2
  exit 2
}

# An in-place substitution on the ledger that introduces VERIFIED and names NO
# ISSUE-ID (`sed -i 's/FIXED_UNVERIFIED/VERIFIED/' …ISSUES.md`) can flip every
# pending row at once and used to pass at zero cost because the ID was simply
# unresolvable (audit H-04). It must say which ISSUE it verifies.
if [ "$INPLACE" -eq 1 ] && [ -z "$IDS" ]; then
  deny "an in-place edit (sed -i / perl -i) introducing VERIFIED on ISSUES.md must name the ISSUE-ID it verifies (e.g. '/ISSUE-NNN/s/FIXED_UNVERIFIED/VERIFIED/')."
fi

[ -n "$IDS" ] || exit 0   # nothing marked VERIFIED, or ID unresolvable -> allow

# Deny if a to-be-VERIFIED ID has zero footprint across all round logs.
missing=""
for id in $IDS; do
  if ! grep -rqaF "$id" "$RUNS_DIR" 2>/dev/null; then
    missing="$missing $id"
  fi
done

if [ -n "$missing" ]; then
  deny "marking$missing VERIFIED in ISSUES.md with no replay record in any $RUNS_DIR/round-*.md."
fi

exit 0
