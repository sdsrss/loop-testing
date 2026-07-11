# Changelog

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
