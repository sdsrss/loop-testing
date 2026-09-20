#!/usr/bin/env bash
# clean-marker-integrity.test.sh — an ownership marker that cannot be parsed must
# be treated as "ownership unknown", never as "we owned nothing".
#
# The bug this locks: sandbox-clean.sh only checked that the marker FILE EXISTS.
# Every field is read with `mval` (grep '^KEY=' | cut -d= -f2-), so a truncated or
# corrupted marker yields an empty value for EVERY key. Empty CREATED_BRANCH /
# CREATED_TAG / CREATED_WORKTREE reads as "this run created nothing", and an empty
# SANDBOX_VERSION lands in the same branch as a genuine v1 marker. The result was a
# --purge that printed "purge done." and exited 0 while the qa branch, the baseline
# tag, the worktree AND the evidence dir were all still on disk — a caller that
# checks $? is told the project is clean when nothing was removed.
#
# Fail-closed is the existing contract for a MISSING marker (exit 3 under --purge).
# An unreadable marker is strictly less knowable than a missing one, so it must
# refuse at least as loudly.
#
# The last case is the backward-compatibility guard: markers back to v0.1.2 carry
# SANDBOX_VERSION + MODE + TOP, so a genuine v1 marker must keep working. A
# validity check that rejected v1 would strand every sandbox created before v0.10.0.
set -u

. "$(dirname "$0")/lib.sh"

WS=$(mk_ws)
trap 'rm -rf "$WS"' EXIT
PROJ="$WS/proj"
MARKER="$PROJ/docs/looptesting/.sandbox/ownership.env"

# Build a real sandbox, then drive STATE.md terminal so --purge is allowed to act.
arm() {
  rm -rf "$PROJ/docs/looptesting" "$WS/proj-qa-loop"
  git -C "$PROJ" worktree prune >/dev/null 2>&1
  git -C "$PROJ" branch -D qa/loop-testing >/dev/null 2>&1
  git -C "$PROJ" tag -d qa-baseline >/dev/null 2>&1
  ( cd "$PROJ" && bash "$SETUP" ) >/dev/null 2>&1
  sed -i.bak 's/^status: .*/status: CONVERGED/' "$PROJ/docs/looptesting/STATE.md"
  rm -f "$PROJ/docs/looptesting/STATE.md.bak"
}

# Everything sandbox-setup created, still present?
leftovers_intact() {
  git -C "$PROJ" rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 \
    && git -C "$PROJ" rev-parse -q --verify refs/tags/qa-baseline >/dev/null 2>&1 \
    && [ -d "$PROJ/docs/looptesting" ]
}

# ── 1. wholly corrupted marker (binary junk) ──────────────────────────────────
arm
printf '\x00\x01\x02 not a marker $(rm -rf /) \xff\n' > "$MARKER"
out=$( cd "$PROJ" && bash "$CLEAN" --purge 2>&1 ); rc=$?
assert_eq 3 "$rc" "corrupted marker + --purge exits 3 (refusal), not 0"
if printf '%s' "$out" | grep -qF 'purge done'; then
  FAIL=$((FAIL+1)); echo "  FAIL: corrupted marker must not report 'purge done'" >&2
else PASS=$((PASS+1)); fi
if leftovers_intact; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: refusal must leave branch/tag/evidence intact" >&2; fi
# the message has to name the file, or the user cannot act on it
printf '%s' "$out" | grep -qF "$MARKER" \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: refusal must name the marker path" >&2; }

# ── 2. truncated marker: real KEY=value lines, mandatory keys missing ──────────
arm
printf 'CREATED_TAG=qa-baseline\nSETUP_AT=2026-01-01T00:00:00Z\n' > "$MARKER"
out=$( cd "$PROJ" && bash "$CLEAN" --purge 2>&1 ); rc=$?
assert_eq 3 "$rc" "truncated marker (no SANDBOX_VERSION/MODE/TOP) + --purge exits 3"
if leftovers_intact; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: truncated-marker refusal must delete nothing" >&2; fi

# ── 3. empty marker file ──────────────────────────────────────────────────────
arm
: > "$MARKER"
out=$( cd "$PROJ" && bash "$CLEAN" --purge 2>&1 ); rc=$?
assert_eq 3 "$rc" "empty marker + --purge exits 3"
if leftovers_intact; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: empty-marker refusal must delete nothing" >&2; fi

# ── 4. plain clean (no --purge) with a corrupted marker ───────────────────────
# Fail-closed too: it must not silently "succeed" having identified nothing. The
# no-marker path already exits 0 after saying so; match that, but say the marker
# is unreadable rather than staying quiet.
arm
printf 'garbage\n' > "$MARKER"
out=$( cd "$PROJ" && bash "$CLEAN" 2>&1 ); rc=$?
assert_eq 0 "$rc" "corrupted marker + plain clean still exits 0 (non-destructive path)"
printf '%s' "$out" | grep -qiE 'marker|unreadable|cannot' \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: plain clean must say the marker is unusable" >&2; }
if leftovers_intact; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: plain clean with a bad marker must delete nothing" >&2; fi

# ── 5. BACKWARD COMPAT: a genuine v1 marker must still purge ──────────────────
# Shape taken from v0.1.2..v0.9.1 sandbox-setup.sh: SANDBOX_VERSION=1, no
# ADOPTED_*/UNCLAIMED_WORKTREE/WORKTREE_STAMP keys at all. The validity check must
# accept it — rejecting v1 would strand every sandbox created before v0.10.0.
#
# The worktree is removed first (a v1 sandbox that already ran `clean`), because a
# STANDING v1 worktree is the separate, documented "cannot establish ownership"
# case covered in 6. Here we are asserting only that v1 still reaches the purge
# stage and removes the refs it recorded.
v1_marker() { # $1 = CREATED_WORKTREE value
  cat > "$MARKER" <<EOF
SANDBOX_VERSION=1
MODE=worktree
SANDBOX_BRANCH=qa/loop-testing
TOP=$PROJ
CREATED_BRANCH=qa/loop-testing
CREATED_TAG=qa-baseline
CREATED_WORKTREE=$1
CREATED_LOOPTESTING_DIR=true
BASELINE_HEAD=$(git -C "$PROJ" rev-parse HEAD)
SETUP_AT=2026-01-01T00:00:00Z
EOF
}
arm
git -C "$PROJ" worktree remove --force "$WS/proj-qa-loop" >/dev/null 2>&1
v1_marker "$WS/proj-qa-loop"
out=$( cd "$PROJ" && bash "$CLEAN" --purge 2>&1 ); rc=$?
assert_eq 0 "$rc" "v1 marker still purges (exit 0) — no regression for pre-v0.10.0 sandboxes"
printf '%s' "$out" | grep -qF 'purge done' \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: v1 marker purge must still report done" >&2; }
git -C "$PROJ" rev-parse -q --verify refs/heads/qa/loop-testing >/dev/null 2>&1 \
  && { FAIL=$((FAIL+1)); echo "  FAIL: v1 marker purge must still delete the branch it created" >&2; } \
  || PASS=$((PASS+1))
# v1 cannot tell whether it created docs/looptesting/, so the dir is KEPT and named
assert_exists "$PROJ/docs/looptesting" "v1 marker purge keeps the evidence dir (unmeasured ownership)"

# ── 6. v1 marker whose worktree is still standing -> documented exit 4 ────────
# README: a worktree `clean` could not establish ownership of is KEPT and named,
# and a purge that left it standing reports "purge incomplete" (exit 4) rather
# than a plain done. This is the contract the integrity check must not disturb.
arm
v1_marker "$WS/proj-qa-loop"
out=$( cd "$PROJ" && bash "$CLEAN" --purge 2>&1 ); rc=$?
assert_eq 4 "$rc" "v1 marker + standing worktree -> purge incomplete (exit 4)"
printf '%s' "$out" | grep -qF 'purge incomplete' \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: exit 4 must be explained as 'purge incomplete'" >&2; }

report "clean-marker-integrity.test.sh"
