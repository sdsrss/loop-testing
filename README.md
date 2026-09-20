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
  faking a "verified" fix (`LOOP_TESTING_DISABLE_LEDGER_GATE=1` opts out) — best-effort and
  bypassable by design, with the residue covered
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
bash install/install-codex.sh                 # install to ${CODEX_HOME:-~/.codex}/skills/loop-testing
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

**Permission model — read before the first headless run.** Both drivers launch the agent
with every permission prompt disabled: `claude -p … --permission-mode bypassPermissions`
and `codex exec -s danger-full-access`. Nothing asks you before a command, an edit or a
network call — the child session runs with your user's full privileges on that machine,
and the skill's red lines are prompt discipline, not an OS boundary. The only hard limits
are the per-session wall-clock watchdog (`--session-minutes`, `timeout -k`), `--max-turns`
(Claude), and the run limits above. Use the drivers only on a project and a machine where
you would accept an unattended agent with that access (a container or VM is the safe
default), and see "Stopping an unattended run early" under Known limitations before you
need it.

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

## 🧹 Post-run artifacts & full cleanup

A finished run (after `sandbox-clean.sh`) **deliberately keeps** these artifacts:

| Artifact | Where | Why it is kept |
|---|---|---|
| `docs/looptesting/` evidence dir — STATE / ISSUES / PLAN / FEATURE_MATRIX / SUGGESTIONS / `runs/` / `decisions/` / FINAL_REPORT.md, plus `driver.log`, an emptied `.pids`, and `.sandbox/ownership.env` (stamped `CLEANED_AT`) | target project | the run's audit trail and the resume contract |
| the qa worktree, when `clean` could not establish that it owns it (a sandbox created before v0.10.0, or one whose ownership stamp is unreadable) | target repo's sibling dir | removing it is `--force`, which would discard anything uncommitted or untracked in it — so `clean` names it and leaves the call to you |
| `qa/loop-testing` branch | target repo | **holds the fix commits — they exist nowhere else** |
| `qa-baseline` tag | target repo | marks the pre-run baseline for diffing |
| `latest-tag` — in `${CLAUDE_PLUGIN_DATA}` when installed as a plugin (`~/.claude/plugins/data/loop-testing@…/`), else `~/.cache/loop-testing/` | plugin data dir / user cache dir | 24h update-check throttle (Claude Code hook); safe to delete any time. Under the plugin data dir `claude plugin uninstall` removes it for you (`--keep-data` opts out); the `~/.cache` fallback is used by Codex and `--plugin-dir` dev loads and is removed by hand |
| `${CODEX_HOME:-~/.codex}/skills/loop-testing` (+ a `.bak` after reinstalls), `${CODEX_HOME:-~/.codex}/prompts/loop-testing.md`, or the `--target DIR` you installed into | Codex home | the installed skill; removed by `install/install-codex.sh --uninstall` (pass the same `--target`) |

**Harvest first, then purge** — the fix commits live only on the qa branch:

```bash
# 1. Harvest: review and take the fixes (run in the target repo;
#    FINAL_REPORT.md §4 maps each ISSUE to its commit hash)
git log qa-baseline..qa/loop-testing --oneline
git merge qa/loop-testing            # or cherry-pick selected hashes
```

Then purge. `SKILL_DIR` is the **installed skill** directory, not the target project —
list your installs first and name the one you want, because this deletes things:

```bash
# 2. Find your install — prints one line per install found, as an absolute path,
#    so it still means the same thing when you purge later from the target repo.
#    Wrapped in `bash -c` so the globs behave the same in zsh (the macOS login
#    shell, where an unmatched glob would cancel the whole command) as in bash.
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" bash -c 'CDPATH=; for d in \
      "$CODEX_HOME"/skills/loop-testing \
      "$HOME"/.claude/plugins/cache/*/loop-testing/*/skills/loop-testing \
      "$PWD"/skills/loop-testing; do
  if [ -r "$d/scripts/sandbox-clean.sh" ]; then ( cd "$d" && pwd ); fi
done'

# 3. Set it to one of the lines above, then purge.
SKILL_DIR="<paste one of the paths printed above>"
bash "$SKILL_DIR"/scripts/sandbox-clean.sh --purge
```

Several lines can come back: the plugin cache keeps older versions next to the current
one, and a cache segment is not always a version number — it can be a commit SHA such as
`022b3c274938`, so there is nothing to sort. Pick the one you are actually running.
Installed with `install-codex.sh --target DIR`? That `DIR` is your `SKILL_DIR`.

A branch with commits beyond the baseline is always **kept** — deleting commits stays
your call. When the tip is also reachable from another ref (you *merged* it somewhere),
purge says so instead of asking you to harvest again; a backup push of the branch itself
does **not** count, and a cherry-pick harvest rewrites the commits, so neither is
detected. Once you have taken what you want, waive explicitly — in the same shell, so
`SKILL_DIR` is still set:

```bash
bash "$SKILL_DIR"/scripts/sandbox-clean.sh --purge --discard-fixes
```

`--purge` is a **user** action, never run by the agent. It refuses (exit 3) unless the
ownership marker exists *and is readable* and `STATE.md` is terminal
(`CONVERGED / INCOMPLETE / BLOCKED`), and it never deletes a checked-out branch. A
marker that is present but truncated or corrupted is treated as *less* knowable than a
missing one: purge names the file and deletes nothing rather than concluding it owned
nothing. A purge that ran but had to leave a worktree standing exits `4`
(`purge incomplete`) — resolve that worktree, then purge again. It also never deletes a ref it only *adopted*
— after a `clean` → re-`setup` cycle the qa branch and baseline tag are re-used rather
than created, so the marker records them as adopted, purge names them instead of removing
them, and `--discard-fixes` does not apply. The same rule covers the evidence dir, which
purge keeps and names — rather than deleting — in five cases:

1. `docs/looptesting/` already existed when the first run started, because you keep your
   own notes or ADRs there;
2. its ownership marker was written before v0.10.0, which recorded that fact
   unconditionally, so the value there says nothing;
3. the marker records the question as unanswered — a sandbox upgraded from before
   v0.10.0 lands here, because nothing ever measured who created the directory;
4. a worktree it could not claim is still registered, and the marker is the only record
   left that can identify it — resolve that worktree, then purge again;
5. it holds files this sandbox did not write. Inside the evidence dir purge deletes only
   its own files, by name, so anything else keeps the directory alive and is named in the
   output. The ownership marker and `STATE.md` are kept alongside it, so a later `--purge`
   can still identify what is the sandbox's instead of refusing with exit `3`. `runs/`,
   `decisions/` and `.sandbox/` are deleted whole — nothing you want kept may live in
   those three.

In all five, removing the directory is your call. Use the manual equivalent:

```bash
git branch -D qa/loop-testing && git tag -d qa-baseline
# Only if docs/looptesting/ is entirely the sandbox's. Purge keeps that directory
# precisely when it may not be — check it before running this line; an untracked
# file of yours in there is not recoverable.
rm -rf docs/looptesting
rm -rf ~/.cache/loop-testing     # optional: update-check throttle, Codex / --plugin-dir only
                                 # (a plugin install keeps it in ${CLAUDE_PLUGIN_DATA},
                                 #  which `claude plugin uninstall` already removes)
```

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

**Stopping an unattended run early:** Ctrl-C, `kill -TERM <driver-pid>`, a `SIGQUIT`, or a
hang-up (closed terminal / dropped SSH session) stops the driver **and the session it is
running**; the driver exits 130 / 143 / 131 / 129 respectively. The session runs in its own
process group (`timeout` creates one), so the driver signals that group and then **waits for
the session to be gone before releasing `.driver.lock`**. Signalling alone is not enough: the
watchdog forwards the `SIGTERM` and only escalates fifteen seconds later, so a driver that
signalled and exited would leave the lock free while a full-permission session was still
shutting down — and a second driver could start right there. The wait is bounded at 20
seconds, which is that fifteen-second guarantee plus margin; at the bound the driver sends one
`SIGKILL` to the session's group. **While it waits it prints the session's pid and the bound on
stderr, and a second signal escalates to `SIGKILL` immediately** instead of cancelling the wait
— so pressing Ctrl-C twice means "stop it now", and never releases the lock out from under a
live session. If the session is then gone the lock is released, and a straggling grandchild
still in the session's process group (a dev server the agent left behind) is named in
`driver.log` rather than holding the project up; a grandchild that called `setsid` has left
that group and is neither stopped nor named. In the pathological case where the session itself outlives
`SIGKILL`, the driver **keeps** the lock and rewrites it to name that process: a stale lock is
visible and refuses the next run, while a released one would silently permit a second
full-permission session on the same `STATE.md`. `SIGKILL` to the driver skips all of this —
the session keeps running and the lock is left naming a dead holder, which the next driver
steals — so use one of the signals above instead.
Also note: without `timeout`/`gtimeout` on PATH the drivers refuse to start (the wall-clock
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
