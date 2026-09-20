#!/usr/bin/env bash
# loop-testing stop-gate — Stop hook. Mechanism-layer enforcement of the QA loop.
#
# While the sentinel docs/looptesting/.active exists, the session may not stop
# until STATE.md reports a terminal status (CONVERGED / INCOMPLETE / BLOCKED).
# A RUNNING or unparseable state fails closed: the stop is blocked (exit 2) and
# the reason is fed back to the model. A block counter (MAX_BLOCKS) guarantees
# the gate never deadlocks the session.
#
# ─── T3.1 pre-implementation verification (Claude Code 2.1.207) ───────────────
# Verified against official docs (code.claude.com/docs/en/hooks.md and
# .../hooks-guide.md, retrieved 2026-07-11) + reference impl
# /mnt/data_ssd/dev/projects/loop_eng/hooks/stop-gate.sh. Conclusions used here:
#   • Stop-hook exit codes: exit 0 = allow stop; exit 2 = BLOCK stop and feed
#     stderr back to the model as the reason. (JSON {"decision":"block"} is an
#     equivalent path; we use exit 2 + stderr — simpler, proven by loop_eng.)
#   • stop_hook_active (stdin JSON): TRUE when this stop is itself a continuation
#     caused by a PRIOR Stop-hook block. We use it to detect a stuck loop and to
#     reset our block counter on a fresh, non-hook-induced stop attempt.
#   • Platform ceiling: Claude Code force-allows the stop after 8 CONSECUTIVE
#     Stop-hook blocks (hooks-guide.md), tunable via CLAUDE_CODE_STOP_HOOK_BLOCK_CAP.
#     Our MAX_BLOCKS MUST stay < 8 so our own valve fires first. (Architecture
#     §2.3 cited "8" from loop_eng's notes — confirmed still current.)
#   • Hook timeout: command hooks default to 600s, NOT 120s (120s was loop_eng's
#     self-set hooks.json value). CORRECTION vs architecture §2.3, which assumed
#     ~120s. IMPORTANT: a Stop hook KILLED by the platform timeout is treated as
#     exit 0 = ALLOW (a killed Stop hook does NOT block). So fail-closed blocking
#     only works if WE finish and emit exit 2 before the timeout — the manifest
#     sets 15s for this hook. That is not free: this gate runs no external
#     checker (unlike loop_eng), but "no subprocess" is not the same as "fast",
#     and a parse here that scales with the size of STATE.md IS a fail-open path.
#     A pre-ship review caught exactly that: an unbounded dedupe loop took 14.7s
#     on 18 000 machine-field lines. Every parse below is now bounded by a line
#     cap (MAX_FIELD_LINES) that fails CLOSED when exceeded. Keep it that way:
#     anything added here must be O(1) in the file's size, or capped.
# ─────────────────────────────────────────────────────────────────────────────
#
# Escape hatch (humans, not models): LOOP_TESTING_DISABLE_STOP_GATE=1.
set -u

STDIN_JSON="$(cat)"   # consume + keep the hook stdin JSON (has stop_hook_active)

if [ "${LOOP_TESTING_DISABLE_STOP_GATE:-0}" = "1" ]; then
  exit 0
fi

# --- anchor to the project root (audit HK-7) ----------------------------------
# The hook process cwd is NOT guaranteed to be the directory holding
# docs/looptesting/ (e.g. a session launched from a subdirectory). Resolving
# cwd-relative made the whole gate silently fail OPEN in that topology.
# Anchor precedence: $CLAUDE_PROJECT_DIR (set by Claude Code for hooks) ->
# stdin JSON "cwd" field -> current cwd (legacy behavior, still exercised by
# the driver topology which cd's into the project before launching).
BASE="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$BASE" ] && command -v jq >/dev/null 2>&1; then
  BASE=$(printf '%s' "$STDIN_JSON" | jq -r '.cwd // empty' 2>/dev/null)
fi
if [ -z "$BASE" ]; then
  BASE=$(printf '%s' "$STDIN_JSON" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi
if [ -n "$BASE" ] && [ -d "$BASE" ]; then
  cd "$BASE" 2>/dev/null || true   # unresolvable -> stay in cwd (legacy)
fi

LT="docs/looptesting"
ACTIVE="$LT/.active"
STATE="$LT/STATE.md"
COUNT_FILE="$LT/.gate-count"     # stores: "<count> <last-blocked-round>"
MAX_BLOCKS=3                     # keep < 8 (platform ceiling); see header

# No armed loop -> allow stop.
[ -f "$ACTIVE" ] || exit 0

# --- parse stop_hook_active from stdin (jq -> python3 -> grep fallback) -------
stop_active="unknown"
if command -v jq >/dev/null 2>&1; then
  # NOT `.stop_hook_active // empty`: jq's `//` treats a literal false as empty, so
  # a fresh stop (stop_hook_active=false) yielded no output -> stop_active stayed
  # "unknown" and the counter-reset never fired on the jq path. C5 was only applied
  # to the grep fallback. Map true->true, everything else (false/null/absent)->false
  # so a fresh stop resets exactly like grep/python3 (audit HK-1).
  v=$(printf '%s' "$STDIN_JSON" | jq -r 'if .stop_hook_active == true then "true" else "false" end' 2>/dev/null)
  [ -n "$v" ] && stop_active="$v"
elif command -v python3 >/dev/null 2>&1; then
  v=$(printf '%s' "$STDIN_JSON" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
v=d.get("stop_hook_active")
print("" if v is None else ("true" if v else "false"))' 2>/dev/null)
  [ -n "$v" ] && stop_active="$v"
else
  # Emit an explicit false (not "unknown") when the field is absent/false, so the
  # counter-reset on a fresh stop still fires without jq/python3 (audit C5).
  if printf '%s' "$STDIN_JSON" | grep -qE '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
    stop_active="true"
  else
    stop_active="false"
  fi
fi

# --- read STATE.md machine fields under a small internal budget (fail closed) -
# grep of a normal file is instant; this timeout guards a pathological file. It
# does NOT cover the parse that follows it — that one is bounded by
# MAX_FIELD_LINES instead, because the platform's own 15s kill means ALLOW.
GATE_BUDGET="${LOOP_TESTING_GATE_TIMEOUT:-10}"
case "$GATE_BUDGET" in *[!0-9]*|"") GATE_BUDGET=10 ;; esac
if command -v timeout >/dev/null 2>&1; then
  FIELDS=$(timeout "$GATE_BUDGET" grep -aE '^(status|round):' "$STATE" 2>/dev/null); rc=$?
else
  FIELDS=$(grep -aE '^(status|round):' "$STATE" 2>/dev/null); rc=$?
fi

block() { # increments counter (with reset logic) and blocks, or force-allows at ceiling
  local reason="$1" cur_round="$2"

  # Stale-remnant escape: a crashed/abandoned run leaves .active + a non-terminal
  # STATE forever, taxing EVERY future stop in this project with a full block cycle.
  # STATE.md is rewritten frequently during a live loop, so if it hasn't been
  # touched in STALE_SECONDS (default 24h; 0 disables) treat the run as abandoned:
  # disarm and allow the stop instead of blocking. mtime avoids parsing the ISO
  # last_updated field and works whether or not the agent wrote it.
  local stale_secs="${LOOP_TESTING_GATE_STALE_SECONDS:-86400}"
  case "$stale_secs" in *[!0-9]*|"") stale_secs=86400 ;; esac
  if [ "$stale_secs" -gt 0 ]; then
    # Staleness source: STATE.md mtime when it exists; otherwise fall back to the
    # sentinel's own mtime. Without the fallback an orphan .active whose STATE.md
    # was never written (e.g. an inline bootstrap that armed the sentinel and
    # crashed before seeding STATE) taxes EVERY future stop in the project
    # forever — the STATE-mtime escape below could never fire (audit NEW-3/R59).
    # A FRESH orphan still fail-closes into a block, exactly like case E.
    local mtime="" now src=""
    if [ -f "$STATE" ]; then
      mtime="$(stat -c %Y "$STATE" 2>/dev/null || stat -f %m "$STATE" 2>/dev/null)"
      src="STATE.md"
    elif [ -f "$ACTIVE" ]; then
      mtime="$(stat -c %Y "$ACTIVE" 2>/dev/null || stat -f %m "$ACTIVE" 2>/dev/null)"
      src=".active sentinel (no STATE.md present)"
    fi
    now="$(date +%s 2>/dev/null)"
    case "$mtime" in ''|*[!0-9]*) mtime="" ;; esac
    case "$now" in ''|*[!0-9]*) now="" ;; esac
    if [ -n "$mtime" ] && [ -n "$now" ] && [ "$((now - mtime))" -ge "$stale_secs" ]; then
      rm -f "$ACTIVE" "$COUNT_FILE"
      echo "loop-testing stop-gate: $src is stale ($((now - mtime))s since last update > ${stale_secs}s) with a non-terminal status — treating as an abandoned run: disarming the sentinel and allowing the stop. Re-trigger the skill to resume from STATE.md." >&2
      exit 0
    fi
  fi

  local prev_count=0 prev_sig=""
  if [ -f "$COUNT_FILE" ]; then
    read -r prev_count prev_sig < "$COUNT_FILE" 2>/dev/null
  fi
  case "$prev_count" in *[!0-9]*|"") prev_count=0 ;; esac
  local cur_sig="${ROUND_SIG:--}"

  # Reset the consecutive-block count when this stop is NOT a hook-induced
  # continuation (fresh attempt) OR the round-value set changed since the last
  # block (progress). This mirrors the platform's "8 consecutive WITHOUT
  # progress" semantics, so a healthy multi-round loop never trips the valve —
  # which is only true because the signal is the SET: one stray `round:` line
  # elsewhere in STATE.md used to make every round look identical.
  local count
  if [ "$stop_active" = "false" ] || { [ "$cur_sig" != "-" ] && [ "$cur_sig" != "$prev_sig" ]; }; then
    count=0
  else
    count="$prev_count"
  fi
  count=$((count + 1))

  if [ "$count" -gt "$MAX_BLOCKS" ]; then
    # Deadlock valve: repeatedly stuck at the same round. Force-allow and clear
    # the counter so a resumed session re-arms cleanly. .active is left in place;
    # the orchestrator / next run disarms on a real terminal status.
    rm -f "$COUNT_FILE"
    echo "loop-testing stop-gate: block ceiling ($MAX_BLOCKS) reached without progress; allowing stop. Loop is NOT converged — resume the skill to continue from STATE.md." >&2
    exit 0
  fi

  printf '%s %s\n' "$count" "$cur_sig" > "$COUNT_FILE"
  {
    echo "loop-testing stop-gate BLOCKED this stop ($count/$MAX_BLOCKS): $reason"
    echo "The QA loop is not finished. Do NOT stop yet."
    echo "Next: re-read $STATE, continue the round loop (references/loop-round.md),"
    echo "and only stop when STATE.md status is CONVERGED / INCOMPLETE / BLOCKED"
    echo "per the convergence criteria (references/exit-and-report.md)."
  } >&2
  exit 2
}

# Parse timeout -> fail closed (block).
if [ "$rc" -eq 124 ]; then
  block "reading STATE.md exceeded the internal budget (${GATE_BUDGET}s); failing closed." "-1"
fi

# --- extract fields (ambiguity fails closed) ---------------------------------
# A machine field that appears more than once with DIFFERENT values is ambiguous,
# and `head -1` resolved that ambiguity by position: an example or quoted
# `status: CONVERGED` written ABOVE the real line disarmed the gate and deleted
# the sentinel — fail-open, and destructive with it (audit H-03). Position is not
# evidence of which line is the machine field, so disagreement blocks instead.
# Identical repeats are not ambiguous and still parse.
#
# Builtins only below (no sort/wc/uniq): this gate already runs on a PATH holding
# almost nothing (the grep-only and python3-only legs), and a helper that is not
# there must never turn a TERMINAL status into an unparseable one — that would
# block every stop in the project until the deadlock valve fires.
#
# BOUNDED, and the bound is load-bearing. This loop runs AFTER the grep's own
# GATE_BUDGET, and its dedupe scans an accumulator that grows with every distinct
# value — O(n²). The platform treats a Stop hook killed by its 15s manifest
# timeout as exit 0 = ALLOW, so an unbounded parse here is a fail-OPEN path, the
# very thing this gate exists to close. Measured: 18 000 distinct machine-field
# lines (223 KB) took 14.7s against 0.21s for the position-based parse it
# replaced. 200 is far past any honest STATE.md, which carries two such lines.
MAX_FIELD_LINES=200
status_vals=""; status_n=0     # "VAL|VAL|" accumulators, used only for dedupe
round_vals="";  round_n=0
seen_lines=0; overflow=0
while IFS= read -r ln; do
  seen_lines=$((seen_lines + 1))
  if [ "$seen_lines" -gt "$MAX_FIELD_LINES" ]; then overflow=1; break; fi
  case "$ln" in
    status:*) k=status; v=${ln#status:} ;;
    round:*)  k=round;  v=${ln#round:}  ;;
    *)        continue ;;
  esac
  # Pattern substitution (bash 3.0+), deliberately not case-modification, which
  # is bash 4 and dies on macOS's bash 3.2 — see tests/portability/bash3.test.sh.
  v=${v// /}; v=${v//$'\t'/}; v=${v//$'\r'/}
  # An EMPTY value is a value, not a line to skip. `continue` here made a bare
  # `status:` invisible, so `status:` above a real `status: CONVERGED` left the
  # terminal one standing alone and the gate disarmed — where the pre-H-03 code
  # read the empty first line and fail-closed. It counts, under a sentinel.
  [ -n "$v" ] || v='<empty>'
  if [ "$k" = status ]; then
    case "|$status_vals" in *"|$v|"*) continue ;; esac
    status_vals="$status_vals$v|"; status_n=$((status_n + 1))
  else
    case "|$round_vals" in *"|$v|"*) continue ;; esac
    round_vals="$round_vals$v|"; round_n=$((round_n + 1))
  fi
done <<EOF
$FIELDS
EOF

if [ "$overflow" = 1 ]; then
  block "STATE.md carries more than $MAX_FIELD_LINES machine-field ('status:'/'round:') lines; refusing to parse it (fail-closed). An honest STATE.md has two." "-1"
fi

status=""; [ "$status_n" -eq 1 ] && status="${status_vals%|}"
# The counter's progress reset keys on the round-value SET, not on one
# normalized integer. Reporting an ambiguous round as -1 failed the `-ge 0`
# guard below, which did not merely withhold one reset — it disabled the
# progress arm for the ENTIRE hook-induced continuation chain, so a loop that
# was genuinely advancing climbed 1->2->3 and was FORCE-ALLOWED on the fourth
# attempt by the deadlock valve. A set that changes between stops is progress
# whether or not exactly one round line is parseable.
ROUND_SIG="${round_vals%|}"
[ "${#ROUND_SIG}" -gt 200 ] && ROUND_SIG="$(printf '%.200s' "$ROUND_SIG")"
[ -n "$ROUND_SIG" ] || ROUND_SIG="-"
cur_round=-1; [ "$round_n" -eq 1 ] && cur_round="${round_vals%|}"

if [ "$status_n" -gt 1 ]; then
  conflict_show="${status_vals%|}"
  [ "${#conflict_show}" -gt 80 ] && conflict_show="$(printf '%.80s' "$conflict_show")…"
  block "STATE.md carries $status_n conflicting 'status:' values ($conflict_show); the machine field must appear exactly once (fail-closed: treated as not converged)." "$cur_round"
fi

case "$status" in
  CONVERGED|INCOMPLETE|BLOCKED)
    # Terminal: disarm the gate and clear the counter, then allow the stop.
    rm -f "$ACTIVE" "$COUNT_FILE"
    echo "loop-testing stop-gate: STATE status=$status (terminal); disarming gate and allowing stop." >&2
    exit 0 ;;
  RUNNING)
    block "STATE status=RUNNING (loop still in progress)." "$cur_round" ;;
  *)
    # Missing / unrecognized status field: fail closed.
    block "STATE.md has no parseable 'status:' field (fail-closed: treated as not converged)." "$cur_round" ;;
esac
