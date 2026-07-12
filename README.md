# loop-testing

**English | [简体中文](README.zh-CN.md)**

[![CI](https://github.com/sdsrss/loop-testing/actions/workflows/ci.yml/badge.svg)](https://github.com/sdsrss/loop-testing/actions/workflows/ci.yml)

> **Autonomous QA loop for Claude Code & Codex.** An AI agent uses your finished
> project like a *real user* in a sandbox — finding bugs, fixing the safe ones with
> regression tests, and looping until it converges. One command, hands-off.

`loop-testing` is a dual-platform skill for [Claude Code](https://claude.com/claude-code)
and [OpenAI Codex](https://openai.com/codex/). After your app is built, it drives an AI
agent to exercise every feature from a real user's entry points (CLI, API, Web, library),
surface **bug / logic / flow / edge-case / hidden / security / UX** issues, **fix the safe
ones on the spot** (reproduce → fix root cause → add a regression test → replay-verify →
atomic commit), route judgment calls to a **multi-model committee**, and stop only when
**two consecutive rounds turn up nothing but trivia**. It runs fully autonomously, pausing
only for keys / payment / network permission, a suspected security vuln, or a hard blocker.

---

## ✨ Highlights

- **Uses your product, not just reads the code.** Acts from real entry points with
  realistic data, fat-fingers, cancels mid-flow, and goes off the happy path — instead of
  statically scanning code or re-running existing tests.
- **Finds a bug → fixes it.** Low-risk issues are fixed immediately: reproduce → fix root
  cause → add a regression assertion → replay-verify → single atomic commit
  (`fix(qa): [ISSUE-xxx]`).
- **Multi-model decisions (MoA).** Product judgment calls aren't decided unilaterally:
  several reference models analyze in parallel, an aggregator synthesizes a recommendation,
  and it's archived as a decision record for you to approve.
- **Anti-gaming convergence.** Stops only after two consecutive clean rounds, and the
  second must use *different* scenarios to cross-check. Coverage may not shrink, unverified
  fixes may not be marked passed, and a run that hits the round cap honestly reports
  `INCOMPLETE` — it never fakes a `PASS`.
- **Resume-safe.** All progress lives in files. After an interruption or context
  compaction, re-triggering the skill continues from the checkpoint — rounds and ledger
  are never reset.
- **Mechanism-layer enforcement (Claude Code).** A Stop-hook blocks ending the session
  before convergence — fail-closed, with a bounded deadlock valve (force-allow after 3
  no-progress blocks, 24h stale-run auto-disarm, `LOOP_TESTING_DISABLE_STOP_GATE=1`
  opt-out). A companion hook raises the cost of
  faking a "verified" fix — best-effort and bypassable by design, with the residue covered
  by red-line discipline and human diff review; it is not a hard gate.
- **One skill, two platforms.** Claude Code and Codex share the same `SKILL.md` — one repo,
  two installs.
- **Safe by construction.** Sandbox isolation, fail-closed cleanup, env-only keys with log
  redaction, and never push / deploy / touch production.

---

## 🧩 Features

| Capability | What it does |
|---|---|
| **Dual persona** | Uses the product as a real user (two alternating profiles: a *novice* who ignores the docs, and an *impatient power user*); switches to a *rigorous engineer* to fix (smallest diff, reproduce-first, verify-after, no drive-by refactors). |
| **Round 0 inventory** | Detects the product shape and entry points, cross-maps every reachable feature, designs normal / edge / misuse / cancel-recovery scenarios, runs a baseline check, and emits `PLAN.md` + `FEATURE_MATRIX.md`. |
| **Per-round loop** | Pick a scenario → use it like a real user → file / reproduce / grade (P0–P3) on discovery → triage-fix with regression guard → replay-verify → settle the round. |
| **Issue ledger** | Every issue (incidental ones included) is filed before it's touched; a fully auditable state machine (`OPEN / FIXING / FIXED_UNVERIFIED / VERIFIED / NEEDS_CONFIRMATION / BLOCKED / WONT_FIX / CANNOT_REPRODUCE`). |
| **MoA decision engine** | Zero-dependency Node script; OpenAI + OpenRouter wire formats, proxy-first, graceful degradation; emits a structured decision record. |
| **Unattended drivers** | `unattended-loop.sh` (Claude) / `unattended-codex.sh` (Codex) relaunch from the checkpoint until convergence, with a wall-clock watchdog, circuit breakers, and a concurrency lock. |
| **Sandbox setup / clean** | `git worktree` isolation + ownership markers; cleanup is fail-closed (deletes nothing without a marker), preserves evidence, and never touches your data. |

All state lives in `docs/looptesting/` inside the target project (kept but not committed,
and your `.gitignore` is left untouched):

| File | Purpose |
|---|---|
| `STATE.md` | Authoritative progress: round, convergence streak, status, next action, blockers. |
| `PLAN.md` | Round 0: product shape, entry points, features, scenario design. |
| `FEATURE_MATRIX.md` | Feature × entry × scenario × coverage × evidence. |
| `ISSUES.md` | The issue ledger (filed on discovery, with the state machine). |
| `SUGGESTIONS.md` | New directions / feature ideas + MoA decision links. |
| `runs/round-N.md` | Per-round scenarios, commands, results, evidence, replay verification. |
| `decisions/DEC-NNN.md` | MoA multi-model decision records. |
| `FINAL_REPORT.md` | Final status + coverage summary + fix list (issue ↔ commit) + open items + blind spots. |

---

## 🆚 How it compares

| | Unit tests / CI | One-shot AI code review | **loop-testing** |
|---|---|---|---|
| How it finds issues | Checks **known** assertions | Reads code statically | **Actually uses** the product to find **unknown** issues |
| Coverage angle | Developer-written cases | A single snapshot | Real user + misuse + edge cases + recovery |
| Handling issues | Reports red | Suggests | **Fixes safe ones on the spot** + regression + commit |
| Decision-type issues | N/A | Single-model opinion | **MoA multi-model committee** |
| When it stops | When the run ends | After one pass | **When it converges** (anti-gaming, honest reporting) |
| After interruption | Re-run | Start over | **File-based resume** |

In one line: unit tests guard against regressions, AI review reads the code —
**loop-testing uses the product like a real user until it breaks, then fixes it.**

---

## 📦 Installation

### Claude Code (plugin)

```bash
/plugin marketplace add sdsrss/loop-testing
/plugin install loop-testing@loop-testing
```

Local / unreleased — load the plugin directory directly:

```bash
claude --plugin-dir .
```

The mechanism layer (Stop-hook resume enforcement + the best-effort anti-fake hook) ships
in `hooks/` and loads automatically. Stop-hook auto-loading is verified for both
`/plugin install` and `--plugin-dir`; on very old Claude Code versions that don't
auto-load, register the hooks manually per `hooks/`.

**Updating:** `claude plugin update loop-testing`. The plugin also prints a one-line
**"update available"** notice at session start when your installed version trails the
latest GitHub tag — notify-only (never auto-downloads), checked at most once per 24h,
silent when offline or in local dev mode. Disable it with `LOOP_TESTING_DISABLE_UPDATE_CHECK=1`.

### Codex (skills directory)

Codex uses the same `SKILL.md` format; install with the bundled script:

```bash
bash install/install-codex.sh                 # install to ~/.codex/skills/loop-testing
bash install/install-codex.sh --target <dir>  # custom skills dir
bash install/install-codex.sh --dry-run       # print actions only
bash install/install-codex.sh --check-update  # compare installed version vs latest tag
bash install/install-codex.sh --uninstall     # uninstall (fail-closed: refuses foreign dirs)
```

The script is idempotent (backs up to `<dest>.bak` on reinstall) and only removes what it
installed (via the `.loop-testing-codex-install` marker). **Re-run it after updating the
skill** — Codex has no auto-update, so a stale copy would run silently. `--check-update`
tells you when a newer tag exists.

---

## 🚀 Usage

### Start

Two ways, both work from inside your target project:

- **Slash command (deterministic, no trigger phrase needed):**
  - `/loop-testing` — start or resume the loop
  - `/loop-testing status` — report progress from `STATE.md`
  - `/loop-testing report` — print `FINAL_REPORT.md`
  - `/loop-testing <focus / round cap>` — optionally scope a run, e.g. `focus on the CLI` or `at most 3 rounds` (`最多 3 轮`); the round cap only lowers `max_rounds`, convergence still stops earlier. Omit for a full loop.
- **Trigger phrase** — say any of these to the agent:
  > `自测` · `验收` · `QA 循环` · `自动测试并修复` · `self-test loop` · `autonomous QA` · `acceptance testing`

On Codex the same `/loop-testing` prompt is installed (to `~/.codex/prompts/` under the
default / `CODEX_HOME` layout) by `install-codex.sh`.

### Headless / long runs

`claude -p` and `codex exec` are single-shot, so a long loop may end before it converges.
For headless runs use the outer resume-driver, which relaunches from `STATE.md` until a
terminal status:

```bash
# Claude Code
bash skills/loop-testing/scripts/unattended-loop.sh --project <target> \
  --max-sessions 15 --max-minutes 240 --plugin-dir <plugin dir>

# Codex
bash skills/loop-testing/scripts/unattended-codex.sh --project <target> \
  --max-minutes 90 --session-minutes 40
```

Exit codes: `0` skill reached a terminal status · `2` argument error · `3` hit
`--max-sessions` · `4` hit `--max-minutes` · `5` two sessions with no progress. Per-session
progress is appended to `docs/looptesting/driver.log`.

### MoA decision configuration

Decision-type issues call `scripts/moa.mjs` (Node ≥ 20, no third-party deps).
**API keys are read from the environment only and always redacted in logs.**

| Env var | Purpose |
|---|---|
| `OPENROUTER_API_KEY` | OpenRouter key (default official base URL) |
| `OPENAI_API_KEY` / `OPENAI_BASE_URL` | OpenAI-compatible endpoint key + base |
| `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` | Route LLM calls through a proxy when set |
| `LOOP_TESTING_MOA_MODELS` | Comma-separated reference-model override |
| `LOOP_TESTING_MOA_AGGREGATOR` | Aggregator-model override |
| `LOOP_TESTING_MOA_TIMEOUT_MS` | Per-call timeout in ms (default 120000) |

Config can also come from `docs/looptesting/moa.config.json` or `--config <path>`.
**Default models are calibrated at release and will age — override as needed.**

```bash
node skills/loop-testing/scripts/moa.mjs --input <ctx.md> --output <DEC.md>
node skills/loop-testing/scripts/moa.mjs --input <ctx.md> --dry-run   # print config, no requests
```

**Degradation chain:** some reference models fail → continue with the rest → all fail →
aggregator-only → aggregator fails / no key → exit 2, and the orchestrator falls back to a
single-model recommendation. The loop is never blocked.

---

## ❓ FAQ

**Q: How is this different from unit tests / CI?**
Unit tests and CI verify assertions you **already wrote**, to prevent regressions.
loop-testing **actually uses** your product like a real user to find bugs, UX, and logic
issues you **didn't anticipate** — and fixes the safe ones. They're complementary.

**Q: Will it change my code or break things?**
It only works on a sandbox branch / worktree, and only makes low-risk, verifiable fixes
that don't change product semantics; each fix is a separate, revertible atomic commit. It
never pushes, deploys, touches production, or disturbs your uncommitted changes. Judgment
calls are recorded, not acted on.

**Q: Does it need network / API keys?**
The QA loop itself runs offline. Only MoA multi-model decisions need an LLM API
(`OPENROUTER_API_KEY` or an OpenAI-compatible endpoint); without a key it degrades to a
single-model recommendation and doesn't block. A proxy in the environment is used
automatically.

**Q: What if a run is interrupted or the context fills up?**
All progress is in `docs/looptesting/`. Re-trigger the skill to resume from `STATE.md` —
rounds and ledger are preserved. For headless long runs, the `unattended-*.sh` drivers
resume automatically until convergence.

**Q: When is it "done"?**
After two consecutive convergent low-risk rounds (no new P0–P2, full-feature regression
with no coverage shrink), it stops and emits `FINAL_REPORT.md`. If it hits the round cap
without converging, it honestly reports `INCOMPLETE` — never a fake `PASS`.

**Q: Is the experience the same on Claude Code and Codex?**
The core skill and artifacts are identical. Difference: Claude Code has the hooks
mechanism layer (mechanically forbids stopping before convergence); Codex has no hooks and
relies on prompt discipline + the unattended driver (see Known limitations).

---

## ⚠️ Known limitations

- **Codex has no mechanism-layer gate.** Codex has no Stop-hook; resume and
  "don't-stop-before-convergence" rest on prompt discipline. Verified once end-to-end in a
  real Codex session, but that is a single-sample result — back it with `unattended-codex.sh`
  multi-session resume.
- **Codex stale install.** After changing the skill you must re-run `install-codex.sh`
  (no auto-update); `--check-update` tells you when a newer tag exists.
- **MoA default models age.** The default model list is release-time calibrated and 404s
  gracefully on provider allowlists — override via env / config as needed.
- **Headless single-shot truncation.** `claude -p` / `codex exec` may end before converging
  — use the unattended driver for headless runs.
- **Node ≥ 20 for MoA only.** The QA loop runs offline; without Node, MoA degrades to a
  single-model recommendation.

### Recovering a stuck sentinel / crash residue

`docs/looptesting/.active` is the Stop-hook resume sentinel. It's removed on normal
exit; if a run is SIGKILL'd with `STATE.md` non-terminal, it can linger and tax every stop.
Recovery (any one):

- **Automatic:** the Stop-hook treats a non-terminal run whose `STATE.md` hasn't been
  updated in 24h (override `LOOP_TESTING_GATE_STALE_SECONDS`, `0` disables) as abandoned —
  it disarms the sentinel and allows the stop.
- **Manual:** `rm docs/looptesting/.active`, or set `LOOP_TESTING_DISABLE_STOP_GATE=1` for
  the session.
- **Resume:** re-trigger the skill to continue from `STATE.md` (rounds are not reset).

**Concurrency lock `docs/looptesting/.driver.lock`:** the unattended drivers take this lock
to keep two drivers from racing the same project's STATE / ledger / worktree. It's released
on normal exit and auto-stolen if the holding PID is dead. It's a best-effort
accidental-double-launch guard, not a hard mutex. If a run was SIGKILL'd and its lock PID is
unreadable, later runs refuse (fail-closed) with a message — after confirming no driver is
live, `rm -rf docs/looptesting/.driver.lock`.

**Stopping an unattended run early:** Ctrl-C (SIGINT to the process group) stops the driver
and its child session immediately. A bare `kill -TERM <driver-pid>` is honored only between
sessions — bash defers the trap while the child session runs, so the worst-case latency is
the remaining session budget (`--session-minutes`, watchdog-bounded). For prompt
programmatic shutdown, signal the process group: `kill -TERM -- -<driver-pgid>`. Also note:
without `timeout`/`gtimeout` on PATH the drivers now refuse to start (the wall-clock
watchdog would be silently absent); pass `--no-watchdog` to explicitly accept unbounded
sessions.

---

## 🔒 Red lines (in sync with `SKILL.md`; violating one stops the run)

- **Never** push / merge / open a PR / release / deploy / force / rebase to a remote.
- **Never** touch production, real accounts, real user data, paid APIs, or real third-party
  writes.
- **Never** "eliminate" an issue by deleting features / loosening assertions / skipping
  tests / swallowing exceptions.
- **Never** overwrite / clean / revert your uncommitted changes; when isolation isn't safe,
  don't commit and record it.
- **Never** downgrade an issue to converge, under-test to fake "zero new", mark `VERIFIED`
  without replay, or report `PASS` at the round cap.
- Suspected secrets: **record only location and risk type; redact the value.** Security
  testing stays local and non-destructive.

---

MIT License. Contributions and issues welcome.
