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
# line into a round log can still get past it; that residual is covered by the
# red lines in the prompt and human diff review, not by this hook.
#
# Fails OPEN on any parse problem or missing tooling — a gate must never brick a
# session. Escape hatch (humans, not models): LOOP_TESTING_DISABLE_LEDGER_GATE=1.
set -u

if [ "${LOOP_TESTING_DISABLE_LEDGER_GATE:-0}" = "1" ]; then
  cat > /dev/null; exit 0
fi

INPUT=$(cat)

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
TEXT=""; TARGETS_LEDGER=0; LT_DIR=""
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
    # Best-effort: a command carrying a write verb that targets the LOOP ledger.
    # Anchor to the loop path (or a bare ISSUES.md only while the loop is armed in
    # cwd) so an unrelated project using the same ISSUE-NNN/VERIFIED convention on
    # its own ISSUES.md is never false-denied. We do NOT bind the verb to the path
    # with one regex — our ISSUE lines contain '|' chars, which a "[^|]*" span
    # would stop at. cwd = project root.
    if printf '%s' "$CMD" | grep -qaE '(>>?|\btee\b|\bsed\b|\bprintf\b|\becho\b|\bmv\b|\bcp\b|\bdd\b|\bperl\b|\bpython3?\b)' \
       && { printf '%s' "$CMD" | grep -qaE 'docs/looptesting/ISSUES\.md' \
            || { [ -f docs/looptesting/.active ] && printf '%s' "$CMD" | grep -qaE 'ISSUES\.md'; }; }; then
      TARGETS_LEDGER=1
      TEXT="$CMD"
      LT_DIR="docs/looptesting"
    fi ;;
esac

[ "$TARGETS_LEDGER" -eq 1 ] || exit 0

# Does the introduced text set a genuine VERIFIED status token? Word-boundary
# match so *_UNVERIFIED (the legitimate FIXED_UNVERIFIED pre-replay status) does
# NOT count — matching that substring false-DENIED normal writes.
printf '%s\n' "$TEXT" | grep -awiqE 'VERIFIED' || exit 0

# IDs on the introduced VERIFIED lines — the common full-line ledger write.
IDS=$(printf '%s\n' "$TEXT" | grep -awiE 'VERIFIED' | grep -aoE 'ISSUE-[0-9]+' | sort -u)

# A minimal Edit ("FIXED_UNVERIFIED" -> "VERIFIED") introduces VERIFIED with no
# ID on the line, which used to slip through free. Recover the affected ID from
# the edit's old_string: an ID inside it, else the ISSUE header enclosing the old
# text in the target ledger. Best-effort — ambiguous/absent context falls through
# to allow (the documented residual) — but it removes the zero-cost bypass.
if [ -z "$IDS" ]; then
  IDS=$(printf '%s\n' "$OLDSTR" | grep -aoE 'ISSUE-[0-9]+' | sort -u)
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

[ -n "$IDS" ] || exit 0   # nothing marked VERIFIED, or ID unresolvable -> allow

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
