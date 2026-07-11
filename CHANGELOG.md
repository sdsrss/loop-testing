# Changelog

## 0.1.3 — 2026-07-11

Production-readiness audit follow-up (batch 1 of 3). A five-track parallel audit
(prompt layer / hooks / MoA engine / drivers+sandbox / tests+release) found no P0,
three P1s, and a cluster of P2s. This release lands the seven pre-release fixes;
full suite `ALL GREEN` (MoA 20/20, ledger-gate 13/13, codex-limits 12/12).

- **fix(moa)**: an invalid `provider` in the config file leaked a `fatal:` stack +
  exit 1 (the same clean-error class v0.1.2 fixed for flags/JSON/model-entry, but
  the provider field was uncovered, and in the reference-fan-out path it aborted the
  whole run instead of degrading). `normalizeModelEntry` now validates the provider
  against the registry so it surfaces as a clean `error: unknown provider "x"` +
  exit 1. (+2 MoA tests.)
- **fix(ledger-gate)**: two-sided error. (1) A word-boundary miss made a legitimate
  `FIXED_UNVERIFIED` write match the `VERIFIED` substring and get false-denied;
  matching is now word-boundary so `*_UNVERIFIED` no longer trips it. (2) A minimal
  `Edit` (`FIXED_UNVERIFIED` → `VERIFIED`) introduced `VERIFIED` with no ISSUE-ID on
  the line and slipped through free — the ID is now recovered from the edit's
  `old_string` (its own ID, or the `### ISSUE-NNN` block enclosing it in the ledger).
  (3) The Bash branch matched a bare `ISSUES.md` substring and could false-deny an
  unrelated project using the same convention; it now anchors to the loop path (or a
  bare name only while the loop is armed). (+5 ledger-gate tests.)
- **fix(unattended-codex)**: the Codex driver only detected GNU `timeout`, silently
  losing its wall-clock watchdog where coreutils ships as `gtimeout` (macOS/Homebrew)
  — a single hung `codex exec` could then hang the driver forever. Added the same
  `timeout`/`gtimeout` detection the Claude driver already uses. (+1 driver test.)
- **fix(exit-and-report)**: the documented exit order removed the stop-gate sentinel
  (`.active`, via `sandbox-clean.sh`) BEFORE writing the terminal `status:`, so a hard
  interrupt in that window left `.active` gone with `status: RUNNING` — the session
  could stop unconverged and unprotected, or a driver could burn to `--max-sessions`.
  Order is now: FINAL_REPORT → write terminal `status:` → `sandbox-clean.sh` (stop-gate
  disarms `.active` itself on the terminal status).
- **ci**: manifest validation now asserts version-sync — `plugin.json.version` ==
  both `marketplace.json` version fields, and on a tag push == `${GITHUB_REF_NAME#v}`.
  Guards against the v0.1.1 tag-without-manifest-bump desync that the JSON-only check
  missed.
- **docs**: README now describes the ledger gate honestly as a best-effort cheat-cost
  raiser (not a hard "机制保证"), and corrects the `LOOP_TESTING_MOA_TIMEOUT_MS` default
  (60000 → actual 120000).

## 0.1.2 — 2026-07-11

End-to-end "real user" test pass over every runnable entrypoint (MoA CLI, both
unattended drivers, both hooks, install + sandbox scripts). Three real bugs fixed,
each with a regression test; full suite `ALL GREEN`.

- **fix(moa)**: expected user errors no longer leak Node stack traces. An unknown
  CLI flag, an unreadable/malformed `--config`, or an invalid model entry fell
  through to the top-level catch and printed `fatal: <stack>`; they now print a
  clean `error: <msg>` + exit 1 (matching the already-graceful `--input` path).
  `fatal:<stack>` is reserved for genuinely unexpected crashes. (+4 MoA tests.)
- **fix(sandbox-setup)**: a value-taking flag as the last token (e.g.
  `sandbox-setup.sh --mode`) hung forever — the same `shift 2`-on-a-1-arg-tail bug
  that v0.1.1 fixed in both drivers but missed in this third script. `shift 2` →
  `shift; shift`; trailing flags now fail-closed fast. (+regression guards.)
- **fix(exit-and-report)**: bridged the status vocabulary gap. The machine
  `STATE.md status:` field is `RUNNING|CONVERGED|INCOMPLETE|BLOCKED` (what
  `stop-gate.sh` + both drivers match as terminal), but the exit reference told the
  agent to write the FINAL-REPORT delivery verdict (`PASS` /
  `CONVERGED_WITH_OPEN_ISSUES`) there without a mapping — a converged run could
  write `status: PASS`, which fails the terminal check → spurious stop-gate blocks
  and drivers relaunching to `--max-sessions` misreporting a converged run as
  INCOMPLETE. Both verdicts now explicitly map to machine `status: CONVERGED`.
- **docs**: README restructured (highlights / comparison / FAQ) with SEO/GEO polish.

## 0.1.1 — 2026-07-11

- **CI**: GitHub Actions (`.github/workflows/ci.yml`) runs the full test suite
  (manifest JSON validation + `tests/run-all.sh`) on push to main, tags, PRs, and
  manual dispatch. Verified green on GitHub.
- **Codex unattended driver** (`scripts/unattended-codex.sh`): outer resume-driver
  for `codex exec`, the Codex-side counterpart to `unattended-loop.sh`. `codex exec`
  is single-shot (no `--max-turns`), so a long loop can end a session before
  convergence; the driver relaunches `codex exec` to resume from `STATE.md` until a
  terminal status, with a per-session wall-clock watchdog, the same no-progress /
  max-sessions / max-minutes circuit breakers and exit codes as the Claude driver,
  and read-only protection of the installed skill dir during full-access sessions.
  16 stub-driven sandbox tests (no real `codex` invoked).

## 0.1.0 — 2026-07-11

Initial release. Full-loop acceptance passed on two project shapes (CLI + REST
API), each converging naturally in 4 rounds with 4/4 seeded-bug discovery plus
14 real bugs found beyond the seeded set.

- **Core QA loop skill** (`skills/loop-testing/`): autonomous self-test / self-fix /
  self-iterate loop with dual personas (novice / impatient power user ↔ rigorous
  engineer), round-0 project analysis, 5-step round cycle, P0-P3 issue ledger with
  replay-verified fixes, K=2 convergence exit with coverage-shrink guard,
  MAX_ROUNDS=12 safety stop, file-based state protocol (resume-safe) under the
  target project's `docs/looptesting/`.
- **MoA decision engine** (`scripts/moa.mjs`): zero-dependency Node >= 20; OpenAI +
  OpenRouter wire formats; env-only keys with redaction; explicit proxy support
  (raw HTTP absolute-form / HTTPS CONNECT tunnel — undici is not importable
  zero-dep on Node 22); parallel reference fan-out + aggregator; bounded
  degradation chain (partial references → aggregator-only → exit 2). Defaults
  calibrated at release against a live model listing + real per-model probes
  (references `openai/gpt-5.6-sol` + `google/gemini-3.1-pro-preview`, aggregator
  `anthropic/claude-fable-5`); token guards: concise-output prompts, max_tokens
  stop-losses (3000/4000), 16k-char input cap with explicit truncation marker.
- **Mechanism-layer enforcement** (Claude Code, `hooks/`): stop-gate Stop hook
  (sentinel + STATE.md machine fields, MAX_BLOCKS=3 under the platform's
  8-consecutive-block force-allow, progress-aware counter reset, fail-closed on
  unparseable state) and ledger-gate PreToolUse hook (blocks unverified VERIFIED
  transitions incl. common Bash write paths; documented as cost-raiser, not a
  complete gate). Escape hatches: `LOOP_TESTING_DISABLE_STOP_GATE=1`,
  `LOOP_TESTING_DISABLE_LEDGER_GATE=1`. Hook auto-loading verified in an
  isolated-config sandbox for BOTH `/plugin install` and `--plugin-dir` modes
  (probe sessions showed the full block → feedback → ceiling-release chain).
- **Dual-platform distribution**: Claude Code plugin (`.claude-plugin/`,
  `claude plugin validate` passing) and Codex installer
  (`install/install-codex.sh`, marker-based fail-closed uninstall). Verified in a
  real codex-cli 0.144.1 session: installed skill is discovered and enters
  round-0 correctly.
- **Unattended headless driver** (`scripts/unattended-loop.sh`): outer resume-driver
  for `claude -p` runs — repeatedly resumes the loop from `STATE.md` until a terminal
  status, with `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`, a per-session wall-clock
  watchdog, and fail-closed limits (max-sessions / max-minutes / no-progress → exit
  3 / 4 / 5); per-session progress appended to `docs/looptesting/driver.log`. Also
  sanitizes coordinator-mode env vars so child sessions get the full tool set when
  launched from inside an agent-teams session (F6).
- **Tests**: sandboxed shell suites (sandbox scripts 27 assertions, stop-gate
  19, ledger-gate 8, driver 17, installer 4 suites) + MoA `node --test` suite (14
  tests); single entry `tests/run-all.sh` (ALL GREEN at release).

Known limitations (see README): Codex side has no mechanism-layer gate (prompt
discipline only); default MoA model list requires release-time calibration and
degrades gracefully on provider-allowlist 404s; under headless `claude -p`, a loop
the model delegates to a sub-agent is killed by the print-mode background-wait
ceiling (~600s) — run unattended sessions via `scripts/unattended-loop.sh`, which
disables that ceiling and drives resume-until-terminal (F4).
