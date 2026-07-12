#!/usr/bin/env bash
# install-codex.sh — install the loop-testing skill into a Codex skills directory.
#
# Codex (>= 2025-12) discovers skills as `<skills-dir>/<name>/SKILL.md`, the same
# SKILL.md format Claude Code uses. Verified on this machine: codex-cli 0.144.1,
# ~/.codex/skills/ already holds skills laid out exactly that way. So installation
# is a plain directory copy of skills/loop-testing/ into the Codex skills dir.
#
# hooks/ is deliberately NOT copied: Codex has no Stop-hook mechanism, so the
# enhancement layer does not apply. SKILL.md's "平台差异" section covers the
# prompt-discipline degradation path used on Codex.
#
# Usage:
#   install/install-codex.sh [--target <skills-dir>] [--dry-run]
#   install/install-codex.sh --uninstall [--target <skills-dir>] [--dry-run]
#
# Target skills-dir resolution (first match wins):
#   1. --target <dir>
#   2. $CODEX_HOME/skills   (when CODEX_HOME is set)
#   3. ~/.codex/skills      (default)
# The skill is installed at <skills-dir>/loop-testing.
#
# Safety:
#   - Idempotent: reinstalling backs up the existing install to
#     <dest>.bak before copying fresh.
#   - fail-closed uninstall/overwrite: only a directory carrying THIS installer's
#     marker file is ever removed or replaced. A foreign directory at the target
#     is never touched.
#   - No git, no network, no writes outside the resolved target.

set -euo pipefail

readonly SKILL_NAME="loop-testing"
readonly MARKER=".loop-testing-codex-install"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly SRC="$REPO_ROOT/skills/$SKILL_NAME"

# ---- args ----
MODE="install"
TARGET=""
DRY_RUN=0
STAGING=""   # path of the in-flight staged copy; cleaned by cleanup_staging on interrupt

usage() {
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) MODE="uninstall" ;;
    --dry-run)   DRY_RUN=1 ;;
    --target)    shift; [ $# -gt 0 ] || { echo "error: --target needs a value" >&2; exit 2; }; TARGET="$1" ;;
    --target=*)  TARGET="${1#--target=}" ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ---- resolve target ----
resolve_skills_dir() {
  if [ -n "$TARGET" ]; then
    printf '%s\n' "$TARGET"
  elif [ -n "${CODEX_HOME:-}" ]; then
    printf '%s\n' "$CODEX_HOME/skills"
  else
    printf '%s\n' "$HOME/.codex/skills"
  fi
}

SKILLS_DIR="$(resolve_skills_dir)"
DEST="$SKILLS_DIR/$SKILL_NAME"

log()    { printf '%s\n' "$*"; }
action() { if [ "$DRY_RUN" -eq 1 ]; then printf '[dry-run] %s\n' "$*"; else printf '%s\n' "$*"; fi; }

# Refuse to rm/mv anything that is not our validated install directory.
is_our_install() {
  local dir="$1"
  [ -n "$dir" ] && [ "$(basename "$dir")" = "$SKILL_NAME" ] && [ -f "$dir/$MARKER" ]
}

# Guarded remove: only ever runs against a path that ends in /loop-testing[.bak]
# and carries our marker (or is a marker-carrying .bak of it).
safe_remove() {
  local dir="$1"
  case "$dir" in
    */"$SKILL_NAME"|*/"$SKILL_NAME".bak) : ;;
    *) echo "error: refusing to remove unexpected path: $dir" >&2; exit 1 ;;
  esac
  if [ "$DRY_RUN" -eq 1 ]; then action "rm -rf $dir"; else rm -rf "$dir"; fi
}

# Remove a stranded staging copy if the install is interrupted (INT/TERM) or
# dies between the copy and the final swap — otherwise a killed run leaves a
# `<name>.staging.<pid>` orphan that no later run reaps (each uses a fresh $$).
# Guarded to the exact `.staging.` basename so it can never touch $DEST.
cleanup_staging() {
  local s="$STAGING"
  STAGING=""   # idempotent: a second firing (INT handler -> EXIT) is a no-op
  [ -n "$s" ] || return 0
  case "$s" in
    */"$SKILL_NAME".staging.*) rm -rf "$s" ;;
  esac
}

do_install() {
  [ -d "$SRC" ] || { echo "error: source skill not found: $SRC" >&2; exit 1; }
  [ -f "$SRC/SKILL.md" ] || { echo "error: source has no SKILL.md: $SRC/SKILL.md" >&2; exit 1; }

  log "Installing skill '$SKILL_NAME'"
  log "  source: $SRC"
  log "  dest:   $DEST"

  # Refuse a foreign directory BEFORE touching anything.
  if [ -e "$DEST" ] && ! is_our_install "$DEST"; then
    echo "error: $DEST exists but is not a loop-testing install (no $MARKER marker)." >&2
    echo "       refusing to overwrite a foreign directory. Move it aside and retry." >&2
    exit 1
  fi

  action "mkdir -p $SKILLS_DIR"
  action "cp -R $SRC -> $DEST (staged, then atomically swapped in)"
  [ -e "$DEST" ] && action "backing up existing install to $DEST.bak"
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$SKILLS_DIR"
    # Stage the full copy first, so a mid-copy failure NEVER leaves a partial
    # (unmarked) $DEST that a later reinstall would refuse as "foreign" (audit C8).
    local staging="$DEST.staging.$$"
    STAGING="$staging"
    # Reap the staging copy if we're interrupted or die before the final swap.
    trap 'cleanup_staging' EXIT
    trap 'cleanup_staging; exit 130' INT
    trap 'cleanup_staging; exit 143' TERM
    rm -rf "$staging"
    if ! cp -R "$SRC" "$staging"; then
      rm -rf "$staging"
      echo "error: copy failed — $DEST left unchanged." >&2
      exit 1
    fi
    write_marker "$staging"
    # Copy is complete and marked; now swap it in atomically.
    if [ -e "$DEST" ]; then
      [ -e "$DEST.bak" ] && safe_remove "$DEST.bak"
      mv "$DEST" "$DEST.bak"
    fi
    mv "$staging" "$DEST"
    STAGING=""            # swapped in; nothing to reap
    trap - EXIT INT TERM
  fi

  log ""
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] no changes made."
  else
    verify_install
  fi
}

write_marker() {
  local dir="${1:-$DEST}"
  local version
  version="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$REPO_ROOT/.claude-plugin/plugin.json" 2>/dev/null \
    | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
  {
    printf 'skill=%s\n' "$SKILL_NAME"
    printf 'version=%s\n' "${version:-unknown}"
    printf 'installed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'source=%s\n' "$SRC"
    printf 'installer=install/install-codex.sh\n'
  } > "$dir/$MARKER"
}

verify_install() {
  log "Installed. Verify:"
  log "  test -f \"$DEST/SKILL.md\" && echo OK"
  if [ -f "$DEST/SKILL.md" ]; then
    log "  -> SKILL.md present: yes"
  else
    log "  -> SKILL.md present: NO (unexpected)"
  fi
  log "  contents:"
  ( cd "$DEST" && ls -1 ) | sed 's/^/    /'
  log ""
  log "In Codex, the skill now lives at $DEST."
  log "Trigger it in a Codex session with: 自测 / 验收 / QA 循环 / self-test loop."
}

do_uninstall() {
  log "Uninstalling skill '$SKILL_NAME'"
  log "  dest: $DEST"
  if [ ! -e "$DEST" ]; then
    log "  nothing to uninstall (not present)."
    return 0
  fi
  if ! is_our_install "$DEST"; then
    echo "error: $DEST is not a loop-testing install (no $MARKER marker)." >&2
    echo "       refusing to delete a directory this installer did not create." >&2
    exit 1
  fi
  safe_remove "$DEST"
  # Also clear a backup left by a prior reinstall (marker-verified, not basename).
  if [ -e "$DEST.bak" ] && [ -f "$DEST.bak/$MARKER" ]; then safe_remove "$DEST.bak"; fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] no changes made."
  else
    log "  removed."
  fi
}

case "$MODE" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
esac
