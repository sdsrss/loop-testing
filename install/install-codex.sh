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
#   install/install-codex.sh --check-update [--target <skills-dir>]
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
#   - The slash-command prompt (<codex-home>/prompts/loop-testing.md) is claimed by
#     content, not by name: the marker records its checksum at install time, and
#     the file is overwritten or removed only when it still matches that record
#     (or is byte-identical to the prompt this checkout ships). A user's own file
#     at that name, or our prompt after they edited it, is left alone and named.
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
    --uninstall)    MODE="uninstall" ;;
    --check-update) MODE="check-update" ;;
    --dry-run)   DRY_RUN=1 ;;
    --target)    shift; [ $# -gt 0 ] || { echo "error: --target needs a value" >&2; exit 2; }; TARGET="$1" ;;
    --target=*)  TARGET="${1#--target=}" ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ---- resolve target ----
# The default destination is under $HOME, and this script runs with `set -u`, so
# a missing HOME used to end it on `HOME: unbound variable` — a bash diagnostic
# naming a shell variable, from cron, a systemd unit without `User=`, `env -i` or
# a container entrypoint. Refuse here instead, naming both routes that work. This
# is the same environment the sandbox teardown broke in (audit S-05).
if [ -z "$TARGET" ] && [ -z "${CODEX_HOME:-}" ] && [ -z "${HOME:-}" ]; then
  echo "error: no --target given, CODEX_HOME is not set, and HOME is empty — there is nowhere to install. Pass --target <skills dir>, or set CODEX_HOME." >&2
  exit 2
fi
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
# Codex slash-command prompt: with the default / CODEX_HOME layout the prompts dir is a
# known sibling of skills (e.g. ~/.codex/prompts), so installing `prompts/loop-testing.md`
# there makes the loop startable with `/loop-testing`, not just a trigger phrase. With an
# explicit --target <skills dir> the prompts location is unknown (and a bare dir would
# resolve outside it), so we skip the prompt and only install the skill. Best-effort:
# installing/removing the prompt never fails the skill install/uninstall.
if [ -n "$TARGET" ]; then
  PROMPTS_DIR=""
elif [ -n "${CODEX_HOME:-}" ]; then
  PROMPTS_DIR="$CODEX_HOME/prompts"
else
  PROMPTS_DIR="$HOME/.codex/prompts"
fi
PROMPT_SRC="$REPO_ROOT/prompts/$SKILL_NAME.md"
PROMPT_DEST="${PROMPTS_DIR:+$PROMPTS_DIR/$SKILL_NAME.md}"

log()    { printf '%s\n' "$*"; }
action() { if [ "$DRY_RUN" -eq 1 ]; then printf '[dry-run] %s\n' "$*"; else printf '%s\n' "$*"; fi; }

# Refuse to rm/mv anything that is not our validated install directory.
is_our_install() {
  local dir="$1"
  [ -n "$dir" ] && [ "$(basename "$dir")" = "$SKILL_NAME" ] && [ -f "$dir/$MARKER" ]
}

# Content identity for the prompt file: POSIX cksum (CRC + byte count), present on
# both Linux and macOS. Identity, not security — it only has to tell "the bytes we
# wrote" from "bytes someone else wrote or changed".
file_cksum() { cksum < "$1" 2>/dev/null | cut -d' ' -f1,2 | tr ' ' '-'; }

# Is the prompt at $PROMPT_DEST ours to overwrite/remove (audit H-02)? True when
# its checksum equals the one recorded in the marker given as $1 (written by the
# install that placed it), or when it is byte-identical to the prompt this
# checkout ships (an install whose marker predates the record). A file that is
# neither — the user's own prompt at that name, or ours after they edited it —
# is theirs, and this installer never `cp`s over it or `rm`s it.
prompt_is_ours() {
  local marker="$1" sum rec
  # A symlink is never ours: we only ever write a regular file there. Removing it
  # would be claiming a path we did not create, and `cp` through it writes to
  # wherever it points — outside the resolved target, which this installer
  # promises never to touch. (GNU cp refuses a dangling link; BSD cp, i.e. macOS,
  # follows it and creates the far end.)
  [ -n "$PROMPT_DEST" ] && [ ! -L "$PROMPT_DEST" ] && [ -f "$PROMPT_DEST" ] || return 1
  sum="$(file_cksum "$PROMPT_DEST")"
  [ -n "$sum" ] || return 1
  if [ -n "$marker" ] && [ -f "$marker" ]; then
    rec="$(grep -E '^prompt_cksum=' "$marker" 2>/dev/null | head -1 | cut -d= -f2-)"
    [ -n "$rec" ] && [ "$rec" = "$sum" ] && return 0
  fi
  [ -f "$PROMPT_SRC" ] && [ "$sum" = "$(file_cksum "$PROMPT_SRC")" ] && return 0
  return 1
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
# Returns 0 only when the process is CONFIRMED gone. `kill -0` fails for ESRCH
# (gone) and for EPERM (alive, owned by another account) alike, and the shell
# cannot tell them apart — so on the targets where staging orphans actually
# accumulate (a sudo-installed --target, a shared box, a multi-account CI agent)
# the owner is exactly the PID we have no permission to signal, and EPERM was
# being read as "confirmed dead". A negative answer has to prove the probe could
# have answered; when it cannot, the orphan stays.
pid_is_gone() { # pid
  if kill -0 "$1" 2>/dev/null; then return 1; fi
  local procfs="${LOOP_TESTING_PROCFS:-/proc}"   # test seam; never set in normal use
  if [ -d "$procfs/self" ]; then
    if [ -e "$procfs/$1" ]; then return 1; fi
    # PID 1 always exists. If this procfs cannot show it to us it is hiding other
    # accounts' processes (hidepid), so the owner's absence proves nothing.
    if [ -e "$procfs/1" ]; then return 0; fi
    return 1
  fi
  if command -v ps >/dev/null 2>&1; then
    if ps -p "$1" >/dev/null 2>&1; then return 1; fi
    if ps -p "$$" >/dev/null 2>&1; then return 0; fi   # ps answered about us, so it works
    return 1
  fi
  return 1   # no probe at all
}

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

  # Reap stale staging orphans from PRIOR runs (audit IN-1): a SIGKILL'd install
  # skips traps and leaves `<name>.staging.<pid>`; each run stages under its own
  # $$, so no later run ever removed them. Guards: exact basename shape, numeric
  # pid suffix, and the owner PID confirmed DEAD — never reap a live parallel
  # install's staging (same never-steal-on-ambiguity rule as the driver lock).
  local orphan opid
  for orphan in "$DEST".staging.*; do
    [ -e "$orphan" ] || continue
    opid="${orphan##*.}"
    case "$opid" in ''|*[!0-9]*) continue ;; esac
    # Was `kill -0 "$opid" 2>/dev/null && continue`, which read EPERM as dead.
    # The cost of getting this wrong is not the copy: the victim's own run does
    # `mv "$DEST" "$DEST.bak"` and then `mv "$staging" "$DEST"`, so a reap landing
    # between them makes the second mv fail under `set -euo pipefail` and leaves
    # that install with its skill directory GONE and only the .bak beside it.
    pid_is_gone "$opid" || continue
    case "$orphan" in
      */"$SKILL_NAME".staging.*)
        if [ "$DRY_RUN" -eq 1 ]; then action "rm -rf $orphan (stale staging orphan)"
        else rm -rf "$orphan"; log "  reaped stale staging orphan: $orphan"; fi ;;
    esac
  done

  # Decide the prompt's fate BEFORE the swap rotates the current marker (with its
  # prompt record) into .bak: absent -> install; ours -> refresh; foreign -> keep.
  local prompt_action="skip"
  if [ -n "$PROMPTS_DIR" ] && [ -f "$PROMPT_SRC" ]; then
    # -L before -e: a DANGLING symlink answers false to -e, so the plain
    # existence check would call the path empty and copy straight through it.
    if [ -L "$PROMPT_DEST" ]; then prompt_action="foreign"
    elif [ ! -e "$PROMPT_DEST" ]; then prompt_action="install"
    elif prompt_is_ours "$DEST/$MARKER"; then prompt_action="install"
    else prompt_action="foreign"; fi
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
    # Copy is complete and marked; now swap it in atomically. The rotated-out
    # .bak is removed ONLY when it carries our marker (same gate do_uninstall
    # already has — audit NEW-2/R58): a foreign `loop-testing.bak` (e.g. a
    # user's manual backup) must never be silently deleted to make room.
    if [ -e "$DEST" ]; then
      if [ -e "$DEST.bak" ]; then
        if [ -f "$DEST.bak/$MARKER" ]; then
          safe_remove "$DEST.bak"
        else
          echo "error: $DEST.bak exists but is not a loop-testing backup (no $MARKER marker)." >&2
          echo "       refusing to delete it to rotate the backup. Move it aside and retry." >&2
          exit 1
        fi
      fi
      mv "$DEST" "$DEST.bak"
    fi
    mv "$staging" "$DEST"
    STAGING=""            # swapped in; nothing to reap
    trap - EXIT INT TERM
  fi

  # Best-effort: also install the /loop-testing slash-command prompt (only when the
  # prompts dir is known — default / CODEX_HOME layout). A failure here must NOT fail
  # the (already-completed) skill install. A file at that path that is not ours
  # (audit H-02) is never overwritten: it is named, and the skill install stands.
  case "$prompt_action" in
    install)
      action "install slash-command prompt -> $PROMPT_DEST"
      if [ "$DRY_RUN" -eq 0 ]; then
        if mkdir -p "$PROMPTS_DIR" 2>/dev/null && cp "$PROMPT_SRC" "$PROMPT_DEST" 2>/dev/null; then
          # Record what we placed, so a later run can tell our bytes from the user's.
          printf 'prompt=%s\nprompt_cksum=%s\n' "$PROMPT_DEST" "$(file_cksum "$PROMPT_DEST")" >> "$DEST/$MARKER"
          log "  slash command: /$SKILL_NAME (Codex prompt at $PROMPT_DEST)"
        else
          log "  note: could not install the slash-command prompt at $PROMPT_DEST (skill install is unaffected)."
        fi
      fi ;;
    foreign)
      log "  note: $PROMPT_DEST exists and was not installed by loop-testing (or was edited since);"
      log "        leaving it as is. Move it aside and re-run to get the shipped /$SKILL_NAME prompt." ;;
  esac

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
  # Decide the prompt's fate while the marker (and its prompt record) still exists.
  local prompt_ours=0
  if [ -n "$PROMPT_DEST" ] && [ -L "$PROMPT_DEST" ]; then
    prompt_ours=2
  elif [ -n "$PROMPT_DEST" ] && [ -f "$PROMPT_DEST" ] && [ "$(basename "$PROMPT_DEST")" = "$SKILL_NAME.md" ]; then
    if prompt_is_ours "$DEST/$MARKER"; then prompt_ours=1; else prompt_ours=2; fi
  fi
  safe_remove "$DEST"
  # Also clear a backup left by a prior reinstall (marker-verified, not basename).
  if [ -e "$DEST.bak" ] && [ -f "$DEST.bak/$MARKER" ]; then safe_remove "$DEST.bak"; fi
  # Remove the slash-command prompt we installed — only when it is still the file
  # we wrote (audit H-02); a user's own file at that name, or ours after they
  # edited it, is kept and named. Best-effort.
  case "$prompt_ours" in
    1) if [ "$DRY_RUN" -eq 1 ]; then action "rm $PROMPT_DEST"; else rm -f "$PROMPT_DEST" && log "  removed slash-command prompt $PROMPT_DEST"; fi ;;
    2) log "  note: kept $PROMPT_DEST — not installed by loop-testing (or edited since); remove it yourself if unwanted." ;;
  esac
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] no changes made."
  else
    log "  removed."
  fi
}

# Notify-only version check for the Codex install. Codex has no SessionStart hook,
# so unlike the Claude side this is manual (`--check-update`). Reads the installed
# marker's version and compares it to the latest git tag on GitHub (this repo ships
# tags, not Releases; ?per_page=100 — the semver scan sees up to 100 tags, audit
# NEW-5/R60). Never fails hard on network trouble. Honors the same test/
# override env as hooks/update-check.sh (LOOP_TESTING_UPDATE_TAGS_URL / _SELFTEST_LATEST
# / _TIMEOUT).
do_check_update() {
  if [ ! -f "$DEST/$MARKER" ]; then
    echo "error: no loop-testing install at $DEST (run the installer first)." >&2
    exit 1
  fi
  local cur latest newest
  cur="$(grep -E '^version=' "$DEST/$MARKER" 2>/dev/null | head -1 | cut -d= -f2- \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  [ -n "$cur" ] || { echo "installed version is unknown (marker has no version) — reinstall to refresh."; exit 0; }
  if [ -n "${LOOP_TESTING_UPDATE_SELFTEST_LATEST:-}" ]; then
    latest="$LOOP_TESTING_UPDATE_SELFTEST_LATEST"
  elif command -v curl >/dev/null 2>&1; then
    latest="$(curl -fsS --max-time "${LOOP_TESTING_UPDATE_TIMEOUT:-5}" \
      -H 'Accept: application/vnd.github+json' -H 'User-Agent: loop-testing-update-check' \
      "${LOOP_TESTING_UPDATE_TAGS_URL:-https://api.github.com/repos/sdsrss/loop-testing/tags?per_page=100}" 2>/dev/null \
      | grep -oE '"name"[[:space:]]*:[[:space:]]*"v?[0-9]+\.[0-9]+\.[0-9]+"' \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1 || true)"
  else
    echo "cannot check for updates: curl not available. Installed: $cur."; exit 0
  fi
  latest="$(printf '%s' "${latest:-}" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
  if [ -z "$latest" ]; then
    echo "could not reach GitHub to check the latest version (offline or rate-limited). Installed: $cur."
    exit 0
  fi
  newest="$(printf '%s\n%s\n' "$cur" "$latest" | sort -V | tail -1)"
  if [ "$latest" != "$cur" ] && [ "$newest" = "$latest" ]; then
    echo "loop-testing update available: $cur -> $latest."
    echo "Codex has no auto-update — re-run 'bash install/install-codex.sh' from an updated checkout to refresh the skill copy."
  else
    echo "loop-testing is up to date (installed $cur, latest $latest)."
  fi
}

case "$MODE" in
  install)      do_install ;;
  uninstall)    do_uninstall ;;
  check-update) do_check_update ;;
esac
