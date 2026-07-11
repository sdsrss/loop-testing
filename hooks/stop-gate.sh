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
#     only works if WE finish and emit exit 2 before the timeout. This gate does
#     ONLY bounded STATE.md parsing — no contract/subprocess execution — so it
#     completes near-instantly and cannot approach the timeout. (This is why,
#     unlike loop_eng, we do not run any external checker inside the Stop hook.)
# ─────────────────────────────────────────────────────────────────────────────
#
# Escape hatch (humans, not models): LOOP_TESTING_DISABLE_STOP_GATE=1.
set -u

STDIN_JSON="$(cat)"   # consume + keep the hook stdin JSON (has stop_hook_active)

if [ "${LOOP_TESTING_DISABLE_STOP_GATE:-0}" = "1" ]; then
  exit 0
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
  v=$(printf '%s' "$STDIN_JSON" | jq -r '.stop_hook_active // empty' 2>/dev/null)
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
# grep of a normal file is instant; the timeout only guards a pathological file.
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
  if [ "$stale_secs" -gt 0 ] && [ -f "$STATE" ]; then
    local mtime now
    mtime="$(stat -c %Y "$STATE" 2>/dev/null || stat -f %m "$STATE" 2>/dev/null)"
    now="$(date +%s 2>/dev/null)"
    case "$mtime" in ''|*[!0-9]*) mtime="" ;; esac
    case "$now" in ''|*[!0-9]*) now="" ;; esac
    if [ -n "$mtime" ] && [ -n "$now" ] && [ "$((now - mtime))" -ge "$stale_secs" ]; then
      rm -f "$ACTIVE" "$COUNT_FILE"
      echo "loop-testing stop-gate: STATE.md is stale ($((now - mtime))s since last update > ${stale_secs}s) with a non-terminal status — treating as an abandoned run: disarming the sentinel and allowing the stop. Re-trigger the skill to resume from STATE.md." >&2
      exit 0
    fi
  fi

  local prev_count=0 prev_round=-1
  if [ -f "$COUNT_FILE" ]; then
    read -r prev_count prev_round < "$COUNT_FILE" 2>/dev/null
  fi
  case "$prev_count" in *[!0-9]*|"") prev_count=0 ;; esac
  case "$prev_round" in ''|*[!0-9-]*) prev_round=-1 ;; esac
  case "$cur_round" in ''|*[!0-9-]*) cur_round=-1 ;; esac

  # Reset the consecutive-block count when this stop is NOT a hook-induced
  # continuation (fresh attempt) OR the loop advanced a round since the last
  # block (progress). This mirrors the platform's "8 consecutive WITHOUT
  # progress" semantics, so a healthy multi-round loop never trips the valve.
  local count
  if [ "$stop_active" = "false" ] || { [ "$cur_round" -ge 0 ] && [ "$cur_round" -gt "$prev_round" ]; }; then
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

  printf '%s %s\n' "$count" "$cur_round" > "$COUNT_FILE"
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

# Extract fields.
status=$(printf '%s\n' "$FIELDS" | sed -n 's/^status:[[:space:]]*//p'          | head -1 | tr -d '[:space:]')
cur_round=$(printf '%s\n' "$FIELDS" | sed -n 's/^round:[[:space:]]*//p'          | head -1 | tr -d '[:space:]')

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
