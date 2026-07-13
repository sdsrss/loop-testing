# Changelog

## 0.8.0 — 2026-07-13

Two batches: external prompt-benchmark adoption (roadmap batch 6, R67–R72 —
systematic comparison against an 11-variant external loop-testing prompt
collection; skeleton unchanged, six targeted additions) and v0.7.0 review
follow-ups (batch 5, R64–R66). Full suite `ALL GREEN` (purge suite 24 → 40
asserts). Prompt changes carry the usual no-real-loop-verification caveat and
fold into the next real-loop smoke.

- **feat(skill / R67–R69)**: `loop-round.md` step 2 gains two product-form
  drivers — **plugin/extension** (host lifecycle: install/load, host calls,
  config change, disable/uninstall cleanup, upgrade migration; no real host →
  simulated-host scripts + declared blind spots) and **data/batch** (idempotency,
  resume after interrupt, large files, encoding, corrupted input, reproducible
  output). The CLI driver adds TTY vs non-TTY degradation and signal semantics;
  the misuse checklist adds failure injection (dependency down / timeout / disk
  full / permission denied — only when safely simulatable, otherwise recorded as
  a blind spot, never faked).
- **feat(skill / R70–R72)**: `issue-rules.md` gains an expectation-source ladder
  (spec/requirements > code comments & types > existing tests > stable
  conventions > general reasonableness; underivable = no oracle →
  `NEEDS_CONFIRMATION`), a concrete P1 example (a public doc's main example
  failing to run), and a three-strike addition — roll back the failed attempts'
  working-tree residue before moving on, so half-done diffs never bleed into
  later rounds' evidence.
- **docs(clean / R64)**: `sandbox-clean.sh` header now documents exit 1
  (internal abort: re-anchored to the main tree but cannot cd there — applies to
  both plain clean and `--purge`).
- **docs(README / R65)**: harvest wording fixed — a branch with commits beyond
  the baseline is *always* kept; harvesting cannot be auto-detected (merging
  does not move the qa tip), so waiving requires an explicit `--discard-fixes`.
- **test(sandbox / R66)**: three re-anchor edge cases locked in
  `tests/sandbox/purge.test.sh` — `--purge` from inside the qa worktree
  (cd-out-before-remove), from an unrelated linked worktree (it and its branch
  stay untouched), and with the main repo on a detached HEAD (HEAD not moved).

## 0.7.0 — 2026-07-13

Audit batch 4 (fourth production-readiness audit, roadmap R57–R62): the last
worktree-topology side path closed, plus a user-facing full-cleanup channel.
Full suite `ALL GREEN` (new purge suite 24 asserts; stop-gate 33, sandbox setup
44 / clean 19).

- **fix(sandbox, P2 / R57)**: `sandbox-setup.sh` / `sandbox-clean.sh` resolved the
  repo root via `git rev-parse --show-toplevel`, so when invoked from *inside* the
  qa worktree, clean missed the main tree's ownership marker and returned a FAKE
  success (exit 0, nothing cleaned — processes and worktree left behind), while
  setup tried to nest a second `<wt>-qa-loop` worktree and died exit 6 with
  misleading advice. Both scripts now detect the linked-worktree topology
  (`--git-dir` vs `--git-common-dir`), re-anchor to the main tree, and cd out of
  the directory being deleted. Validation failure keeps the old behavior.
- **feat(sandbox / R62)**: `sandbox-clean.sh --purge [--discard-fixes]` — USER-run
  full cleanup after a terminal run: deletes the evidence dir, the owned baseline
  tag, and the owned qa branch. Refuses (exit 3) without a marker or a terminal
  `STATE.md`; a branch holding unharvested fix commits is kept unless
  `--discard-fixes`; a checked-out branch is never deleted. Default (no-flag)
  behavior is byte-identical. The exit sequence explicitly forbids the agent from
  passing `--purge` (user action only; prompt-contract line carries the usual
  no-real-loop-verification caveat).
- **docs(README / R61)**: new "Post-run artifacts & full cleanup" section (EN/zh)
  — what a finished run deliberately keeps (evidence dir, qa branch, baseline
  tag, update-check cache, Codex install artifacts) and the harvest-then-purge
  runbook.
- **fix(install / R58)**: the reinstall backup rotation deleted an existing
  `loop-testing.bak` on basename alone; it is now marker-gated like uninstall — a
  foreign `.bak` refuses the reinstall (exit 1) and is left untouched.
- **fix(hooks / R59)**: the stop-gate 24h stale escape required `STATE.md` to
  exist, so an orphan `.active` without STATE taxed every future stop forever; it
  now falls back to the sentinel's own mtime (a fresh orphan still fail-closes).
- **fix(update-check / R60)**: both tag checks (SessionStart hook and
  `install-codex.sh --check-update`) now query the GitHub tags API with
  `?per_page=100` — the highest-semver scan previously saw only page 1 (30 tags).

## 0.6.2 — 2026-07-12

Patch: fix both unattended resume-drivers' `--help` output, found by a dogfooding
`/loop-testing` run against this repo itself. Full suite `ALL GREEN`.

- **fix(driver-help)**: `unattended-loop.sh` / `unattended-codex.sh` printed their
  leading comment header as `--help` via a hardcoded `sed -n '2,Np'` line range that
  drifted as the header changed length — `unattended-loop.sh` leaked source lines
  (`set -u`, `PROJECT=""`) past the header, and `unattended-codex.sh` truncated its
  own exit-code-5 explanation mid-sentence. Both now use one identical
  `awk 'NR>1{if(/^#/)print;else exit}'` that prints the contiguous comment block
  regardless of length (also making the two drivers' help logic truly identical).
  New `tests/driver/driver-help.test.sh` asserts no code leak and a complete header
  for both drivers.

## 0.6.1 — 2026-07-12

Patch: sandbox-isolation hardening (product bug found in a real smoke run) plus an
optional interactive scope hint for `/loop-testing`. No user-visible change to the
default (no-argument) loop behavior. Full suite `ALL GREEN` (command 34, driver
prompt-isolation 6).

- **fix(sandbox-isolation)**: a real headless smoke run surfaced that under
  `claude -p` / `codex exec` with `bypassPermissions` the agent could skip
  `sandbox-setup.sh` and switch the user's MAIN worktree to the qa branch in place,
  defeating worktree isolation and blocking the user from working. `round-0.md` §7
  now makes worktree the **enforced default**, forbids any manual branch switch of
  the user's tree, permits `--mode branch` only on explicit user request, and adds a
  pre-edit **isolation-proof gate** (verify `.sandbox/ownership.env` + a registered
  sibling worktree + the main tree still on the user's original branch). Both drivers'
  `RESUME_PROMPT` carry the same worktree-mandatory clause; new
  `tests/driver/prompt-isolation.test.sh` locks the clause in both.
- **feat(command)**: `/loop-testing` accepts optional scope hints — a **focus** area
  (e.g. `focus on the CLI`, recorded in `PLAN.md`) and/or a **round cap**
  (e.g. `最多 3 轮` → writes `max_rounds: N`, only lowers the runaway cap; convergence
  still stops earlier, hitting the cap unconverged writes `INCOMPLETE`). Empty-argument
  default is unchanged. Mirrored in the Codex prompt; README (EN + zh) + tests updated.

## 0.6.0 — 2026-07-12

Minor: audit batch 3 (roadmap R49–R56) — coverage hardening, sandbox/driver
fail-closed fixes, MoA fan-out guard, plus two fixes from an independent
workflow-backed code review. Full suite `ALL GREEN` (stop-gate 31, ledger 20,
update-check 12, driver-limits 31, codex-limits 33, setup 39, moa 34).

**Migration note — new default behavior:** the MoA engine now REFUSES (exit 1)
when a config's `reference_models` list exceeds 8 entries, instead of firing that
many parallel paid calls. A committee wider than 8 is almost always a paste error;
the error names the count and says "trim the list." Duplicates are counted, not
collapsed — re-listing a model is a legitimate self-consistency sample because
`reference_temperature` defaults to 0.6. Configs with ≤8 models see no change.

- **fix(moa)**: `MAX_REFERENCE_MODELS=8` fan-out guard — >8 reference_models is a
  clean error (exit 1), applied after config+env merge; duplicates count toward
  the cap and are NOT deduped (temp>0 makes a repeat a distinct sample). MO-7.
- **fix(sandbox)**: branch-mode resume re-verifies the checked-out branch against
  the marker's recorded `SANDBOX_BRANCH` and refuses (exit 7) a wrong-branch
  resume that would commit onto the user's branch; legacy markers with no recorded
  branch are skipped (not guessed). Branch check uses `symbolic-ref` (portable to
  git < 2.22, empty-on-detached like `--show-current`). DR-9 + code-review fixes.
- **fix(sandbox)**: value-taking flags (`--branch`/`--worktree-path`/`--baseline-tag`)
  fail closed (exit 2) on a missing trailing value instead of silently building a
  sandbox at the computed default. DR-10.
- **fix(install-codex)**: stale staging-dir orphans are reaped only when the owning
  PID is confirmed dead (`kill -0`), never while a parallel install holds it —
  same "don't-steal-on-ambiguity" rule as the driver lock. IN-1.
- **perf(drivers)**: `runs_sig`/`bootstrap_sig` compute byte totals via `wc -c`
  path arithmetic (stat, not full-file read); identical across both drivers. DR-8.
- **test**: coverage batch — stop-gate python3-only parse + `LOOP_TESTING_DISABLE_STOP_GATE`
  escape hatch, ledger no-jq/python3 fail-open confession, update-check no-curl
  branch, watchdog-kill path, CONNECT `Proxy-Authorization` assertion, slash-command
  guard block-anchoring, install idempotency/orphan-reap. R49–R51, R56.

## 0.5.0 — 2026-07-12

Minor: audit batch 7 second wave (roadmap R42–R48) — driver watchdog/shutdown
hardening, prompt-contract cleanups, CI matrix. Full suite `ALL GREEN`
(driver-limits 27, codex-limits 30).

**Migration note — new default behavior:** the unattended drivers now REFUSE to
start (exit 2) when neither `timeout` nor `gtimeout` is on PATH, instead of
silently running every session unbounded (the wall-clock watchdog is the only
bound on a hung session, and it simply didn't exist on such hosts). Install GNU
coreutils, or pass the new `--no-watchdog` flag to explicitly accept unbounded
sessions (a WARNING is recorded in driver.log). Hosts with either binary — the
common case — see no change; the refusal message itself states both remedies.

- **fix(drivers)**: no-watchdog refusal + `--no-watchdog` opt-out, identical across
  both drivers. (+4 tests via a symlink-farm PATH with the watchdog binaries
  removed: default → exit 2 with zero sessions; `--no-watchdog` → runs to
  convergence with the WARNING logged.) DR-7.
- **docs(drivers/readme)**: shutdown semantics documented (EN + zh + both driver
  headers) — Ctrl-C stops driver and child immediately; a bare `kill -TERM
  <driver-pid>` is honored only between sessions (worst-case latency = remaining
  session budget); use `kill -TERM -- -<driver-pgid>` for prompt programmatic
  shutdown. Chosen over killing the child from the trap: backgrounding the session
  changes non-interactive signal inheritance (background jobs ignore SIGINT) — a
  worse failure class than a bounded latency. DR-6.
- **docs(references)**: script invocations now use a resolvable
  `"$SKILL_DIR"/scripts/…` placeholder with locate notes (Claude:
  `${CLAUDE_PLUGIN_ROOT}/skills/loop-testing`; Codex: `~/.codex/skills/loop-testing`)
  — the 0.2.5 note fixed SKILL.md only, while progressive disclosure means the
  reference file is what's in context at invocation time. moa-decision.md adds
  "engine not located ≠ MoA unavailable", so a mislocated script no longer silently
  degrades committee decisions to single-model. PL-10.
- **docs(skill)**: startup seeds the 5 state files; `runs/` + `decisions/` are
  created on demand; `FINAL_REPORT.md` is instantiated at exit ONLY (a mid-run
  "final report" stub misleads resume and `/loop-testing report`). PL-8. The
  "three pause reasons" are now mechanism-accurate: total blockage → terminal
  BLOCKED; a suspected security vuln is filed as P0, surfaced prominently, and
  testing continues; there is no wait-for-user state on Claude Code. PL-9.
- **docs(references)**: resume now reconciles the qa-branch `git log` against the
  ledger (fix commit present but unrecorded → advance the entry to
  FIXED_UNVERIFIED and re-verify, never re-fix); convergence takes precedence over
  the round cap when both fire on the same round. PL-11 / PL-12.
- **ci**: Node 20 + 22 matrix (the claimed Node ≥ 20 floor now actually runs) and a
  separate `plugin-validate` job running the official `claude plugin validate`.
  macOS remains deferred with the reason recorded in ci.yml: the TEST fixtures are
  GNU-only (`touch -d @epoch`, bare `timeout`) even though the product scripts are
  BSD-portable — porting the fixtures is the tracked follow-up. TS-3 (partial).
- NOTE: the prompt-text changes (PL-8/9/10/11/12, plus 0.4.2's PL-7) are
  LLM-visible metadata — schema-validated and suite-green, but live-loop
  behavioral verification is outstanding (one real run covers them all).

## 0.4.2 — 2026-07-12

Patch: third production-readiness audit follow-up (audit batch 7). Closes the four
P2s the audit surfaced — all four the same shape: a guard correct on the main path
but silently fail-open on an unclaimed side path. Each code fix landed RED-first.
Full suite `ALL GREEN` (stop-gate 28, ledger-gate 18, codex-limits 26).

- **fix(unattended-codex)**: a concurrent driver refused by the lock un-write-protected
  the RUNNING driver's skill dir on its way out — `cleanup`'s `chmod -R u+w` was gated
  only on `PROTECT`, and the trap is installed before `acquire_lock`, so the refused
  run "restored" a protection it never applied. The restore is now gated on
  `DID_PROTECT` (set only after this process actually applied the chmod), the same
  ownership gating `release_lock` already had via `LOCK_OWNED`. (+2 codex driver
  tests: a refused concurrent run exits 2 AND leaves the read-only skill dir
  untouched.) CX-1.
- **fix(hooks)**: stop-gate and ledger-gate resolved `docs/looptesting/` relative to
  the hook process cwd, so a session whose hook cwd differs from the state dir (e.g.
  launched from a subdirectory) made the whole mechanism layer silently fail OPEN —
  stop-gate allowed the first stop, ledger-gate no-oped. Both hooks now anchor to
  `$CLAUDE_PROJECT_DIR`, then the stdin JSON `cwd` field (jq with a sed fallback),
  then the legacy cwd. (+4 hook tests: wrong-cwd RUNNING still blocks via both
  anchors; wrong-cwd ledger allows a replay-footprinted VERIFIED and still denies an
  armed bare-path fake.) HK-7.
- **fix(tests)**: `run-all.sh` zero-discovery no longer passes — finding no `*.sh`,
  no `*.test.sh`, or no `tests/moa` now fails the gate loudly, and a failed `cd`
  exits 1. Previously only the shellcheck branch's empty-array check accidentally
  caught an empty set, and only where shellcheck was installed — a moved/renamed
  tests tree could report `ALL GREEN` having run nothing. Sandbox drill: the old
  gate exits 0 on a tree with every test deleted; the new one exits 1. TS-1.
- **docs(skill)**: the inline-fallback path (bundled scripts not locatable) now
  instructs creating the `docs/looptesting/.active` sentinel, and round-0 §7 states
  the sentinel requirement independently of `sandbox-setup.sh` — the sentinel's only
  creator was the script, so the sanctioned inline path ran with the stop-gate
  silently inert. NOTE: LLM-visible metadata; passes `claude plugin validate` and
  the full suite, but the live-loop behavioral effect is NOT yet verified (same
  caveat class as the 0.2.5 script-location note) — verification outstanding. PL-7.
- **docs(readme)**: the stop-gate is no longer sold as "a hard guarantee" (EN + zh) —
  it is fail-closed with a bounded deadlock valve (force-allow after 3 no-progress
  blocks, 24h stale-run auto-disarm, `LOOP_TESTING_DISABLE_STOP_GATE=1` opt-out). DOC-1.

## 0.4.1 — 2026-07-12

Patch: code-review follow-up on the v0.3.0/v0.4.0 work. Fixes an offline hard-fail in the
Codex `--check-update` command and closes the test gap the review exposed. Full suite
`ALL GREEN`.

- **fix(install-codex)**: `--check-update` no longer aborts with a bare `exit 1` (no
  message) when GitHub is unreachable. Under `set -euo pipefail` the `latest=$(curl … |
  sort -V | tail -1)` assignment lacked the `|| true` its two sibling lines had, so an
  offline/rate-limited curl tripped `set -e` before the graceful-degradation branch could
  run — leaving that "could not reach GitHub (offline or rate-limited)" message as dead
  code. Now it degrades cleanly to `exit 0` with the notice. The SessionStart hook
  (`update-check.sh`, `set -u` only) was never affected.
- **test(install)**: regression test for the offline `--check-update` path — exercises the
  real-curl branch against an unreachable URL (no `SELFTEST_LATEST` override), which is how
  the bug slipped through. RED before the fix (3 assertions), green after.
- **test(command)**: new `tests/commands/loop-testing.test.sh` — the `/loop-testing` slash
  command had no behavioral coverage. Static structural + parity guard: Claude frontmatter
  (`name` / `description`), the three-mode dispatch (start/resume · `status` · `report`) in
  both the Claude command and Codex prompt, the two safety guards ("status/report must not
  start a run", "resume must not reset the round count"), skill reference, and
  Claude↔Codex parity so the two prompt files can't silently diverge.

## 0.4.0 — 2026-07-12

Minor: adds a `/loop-testing` slash command so the loop can be started deterministically
without a trigger phrase — on both Claude Code and Codex. Full suite `ALL GREEN` (16
test files). Verified end-to-end: a real unattended run on a throwaway CLI project
converged in 3 rounds (`CONVERGED_WITH_OPEN_ISSUES`, 9 issues found, 4 seeded + 5 extra,
21 regression tests, honest reporting), and the SessionStart / slash-command wiring was
confirmed to fire in a live `claude -p` session.

- **feat(command)**: new `commands/loop-testing.md` — `/loop-testing` starts or resumes
  the loop, `/loop-testing status` reports progress from `STATE.md`, `/loop-testing
  report` prints `FINAL_REPORT.md`. Auto-discovered by Claude Code (invocable as
  `/loop-testing`, fully qualified `/loop-testing:loop-testing`). No more relying only on
  a trigger phrase or the model choosing to invoke the skill.
- **feat(codex)**: `install-codex.sh` now also installs a matching `/loop-testing` prompt
  to the Codex prompts dir (`~/.codex/prompts/` under the default / `CODEX_HOME` layout),
  and removes it on `--uninstall`. With an explicit `--target <skills dir>` the prompts
  location is unknown, so the prompt is skipped (skill still installs) — never resolving a
  prompt path outside the target. (+4 install tests.)
- **chore(hooks)**: aligned the SessionStart update-check matcher to the documented
  `startup|resume|clear|compact` form. (The `0.3.0` `*` matcher also fired in testing —
  this is the explicit, recommended form, not a bug fix.)
- **docs(readme)**: the Start section (EN + zh) now leads with the `/loop-testing` slash
  command alongside the trigger phrases, and notes the Codex prompt.

## 0.3.0 — 2026-07-12

Minor: adds a notify-only update check (a new user-visible default behavior) and
rewrites the README. Full suite `ALL GREEN` (15 test files; update-check 10/10,
codex check-update 7/7).

**Migration note — new default behavior:** once installed, the plugin now runs a
`SessionStart` hook that prints a one-line "update available" notice when your
installed version trails the latest GitHub tag. It is **notify-only** (never
downloads or installs), checks the network **at most once per 24h**, is **silent and
fast** when offline / rate-limited / in local `--plugin-dir` dev mode, and never
blocks session start. **Opt out** with `LOOP_TESTING_DISABLE_UPDATE_CHECK=1`. No
action is required to keep the previous behavior other than setting that env var.

- **feat(update-check)**: new `hooks/update-check.sh` SessionStart hook + `hooks.json`
  registration. Uses the GitHub **tags** API (this repo ships tags, not Releases),
  picks the highest semver, caches to throttle, and emits a SessionStart
  `additionalContext` notice only when a newer version exists. (+10 hook tests: the
  GitHub API is stubbed via `file://` fixtures — no real network.)
- **feat(install-codex)**: new `--check-update` mode — Codex has no SessionStart hook,
  so it compares the installed marker version to the latest tag on demand and, when a
  newer tag exists, tells the user to re-run the installer. (+7 install tests.)
- **docs(readme)**: rewritten and split into English (`README.md`, the GitHub default
  page) + Simplified Chinese (`README.zh-CN.md`) with a language switcher. Aligned to
  current features (update notice, `--check-update`, driver concurrency lock,
  stale-sentinel recovery); ledger-gate kept described as a best-effort cheat-cost
  raiser (not a hard gate); env vars / flags / defaults cross-checked against the code.

## 0.2.6 — 2026-07-12

Code-review follow-up to the v0.2.5 driver concurrency lock (DR-4). A fresh-context
review found the lock stole on ambiguity, which both re-admitted a race and violated
the repo's fail-closed rule. Full suite `ALL GREEN` (driver-limits 23, codex-limits 24).

- **fix(drivers)**: `acquire_lock` stole a present `.driver.lock` whenever the holder
  PID was unreadable/empty — including the window where driver A has created the lock
  dir but not yet written its pid, letting driver B steal A's *live* lock. It now
  steals ONLY when the holder PID is readable AND confirmed dead (a crashed driver);
  an unreadable/empty holder is treated as live and refused (fail-closed — never steal
  on ambiguity). Kept byte-identical across both drivers. (+2 driver tests: an
  ambiguous no-pid lock is refused, not stolen.) The lock remains a best-effort
  accidental-double-launch guard, not a hard mutex (documented in README).
- **docs(readme)**: the crash-recovery section now covers `docs/looptesting/.driver.lock`
  — its purpose, auto-steal of a dead-holder lock, the best-effort caveat, and the
  manual `rm -rf` recovery for a SIGKILL'd run whose lock pid is unreadable.

## 0.2.5 — 2026-07-12

Audit batch 6 (part 2): the two remaining second-audit findings. Full suite
`ALL GREEN` (MoA 30, stop-gate 26, driver-limits 21, codex-limits 22).

**Behavior change to note:** running a second unattended driver on a project while
one is already running is now refused (exit 2) instead of racing STATE.md / the
ledger / the worktree. A crashed driver's leftover lock (holder PID no longer alive)
is auto-stolen, so a normal relaunch after a crash is unaffected. Remove
`docs/looptesting/.driver.lock` by hand only if a run was SIGKILL'd and you are sure
no driver is live.

- **fix(drivers)**: added a concurrency guard — a portable `mkdir`-based atomic lock
  at `docs/looptesting/.driver.lock` (no `flock`; it is absent on macOS) with holder
  PID-liveness: a live holder is refused (exit 2), a stale lock from a crashed driver
  is stolen. Kept identical across both drivers (loop driver traps `release_lock`;
  the codex driver folds it into its existing skill-dir-restore cleanup trap). DR-4.
  (+4 driver tests: live-holder refusal and stale-lock steal, per driver.)
- **docs(skill)**: SKILL.md now states that the bundled scripts and templates live
  in the skill's own install dir (not the target project's cwd), so the
  `skills/loop-testing/…` paths in the references are relative-to-skill hints, not
  commands to copy verbatim under the target cwd. It gives the resolution (Claude:
  `${CLAUDE_PLUGIN_ROOT}/skills/loop-testing/`; Codex: `~/.codex/skills/loop-testing/`)
  and an inline-fallback: the scripts are optional conveniences — do the equivalent
  setup/clean inline if they can't be located. PL-1 / PL-4. NOTE: this is
  LLM-visible metadata; it passes `claude plugin validate` and does not regress the
  suite, but its behavioral effect (does the agent resolve/fall back correctly in a
  live loop) is NOT yet verified by a real-loop run — verification is outstanding.

## 0.2.4 — 2026-07-12

Audit batch 6 (second-audit follow-up, functional/contract hardening). Lands the
remaining actionable P2/P3 findings from the second production-readiness audit,
each RED-first. Full suite `ALL GREEN` (MoA 30, stop-gate 26, driver-limits 17,
codex-limits 18). Two findings are deferred with rationale (see below).

**Behavior change to note:** an `moa.config.json` whose `reference_models` is an
empty array or a non-array value now fails with a clean `error:` (exit 1) instead
of silently running aggregator-only / falling back to the DEFAULT models. If you
relied on that silent fallback, either omit `reference_models` (to use the DEFAULT
set) or give it a non-empty array.

- **fix(drivers)**: the no-progress fingerprint (`round | issues | converged_streak
  | runs count+bytes`) could not observe round-0 progress — round 0 fills PLAN.md +
  FEATURE_MATRIX.md before any `runs/round-N.md` exists, so a round 0 spanning ≥3
  sessions on a large target fingerprinted as static and false-tripped NO_PROGRESS
  (exit 5). The fingerprint now includes round-0 bootstrap bytes (PLAN +
  FEATURE_MATRIX). Kept identical across both drivers. (+2 driver tests: a round-0
  bootstrap run reaches --max-sessions instead of NO_PROGRESS.) PL-2.
- **fix(moa)**: a config `reference_models` that is an empty array (silently ran
  aggregator-only) or a non-array typo (silently fell back to the paid DEFAULT
  models) now surfaces as a clean `error:` (exit 1) — aligning with the "zero
  criteria → refuse" discipline. Absent `reference_models` still uses the DEFAULT.
  (+2 MoA tests.) MO-2 / MO-3.
- **docs(moa-decision)**: the reference now documents the exit-1 contract (user-side
  config/argument/input/output-write errors) alongside 0 and 2, with the full exit-
  code semantics and the "capture the stdout decision on an --output write failure"
  rule. PL-3.
- **test**: closed three previously-uncovered paths — the F6 coordinator-mode env
  sanitization (the child must not inherit orchestration-only mode vars), the codex
  driver's driver.log writability guard (unwritable → die exit 2 before any session),
  and `LOOP_TESTING_GATE_STALE_SECONDS=0` disabling the stale-sentinel auto-disarm.

Deferred (tracked): a driver concurrency lock (needs a portable mkdir-lock + PID
liveness + trap composition across the two drivers' differing traps; P3), and making
the skill/references state how to locate the installed script dir (LLM-visible
metadata requiring a real-loop run to verify; P2).

## 0.2.3 — 2026-07-12

Second full production-readiness audit (5-track parallel review + per-finding
code cross-verification at v0.2.2 baseline). No P0/P1; this release lands the four
correctness/security P2s plus two stale-comment fixes. Each code fix was written
RED-first (a new test reproduces the defect against the old code, then goes green).
Full suite `ALL GREEN` (MoA 28, stop-gate 24, ledger-gate 16, clean 13).

- **fix(stop-gate)**: the jq parse path used `.stop_hook_active // empty`, but jq's
  `//` treats a literal `false` as empty, so a fresh stop left `stop_active`
  "unknown" and the block-counter reset never fired on the primary parser (the C5
  fix in 0.2.1 only reached the grep fallback). Independent fresh stops then
  accumulated toward the deadlock valve, force-allowing sooner than the fail-closed
  design intends. Now maps `true`→true and false/null/absent→false, matching the
  grep/python3 paths. (+1 stop-gate test: jq present, two fresh stops keep count 1.)
- **fix(ledger-gate)**: `grep -awiqE 'VERIFIED'` carried `-i`, so an OPEN issue whose
  title contained the word "verified"/"VERIFIED" as prose (e.g. "not yet verified")
  was false-denied. The status token is always uppercase; matching is now
  case-sensitive and, for a file write, anchored to the `| STATUS |` column (a bare
  VERIFIED in the free-text title column no longer trips it). Bash commands keep a
  word-boundary match so `sed`/`perl` substitution syntax (`s/OPEN/VERIFIED/`) is
  still caught. (+2 ledger-gate tests: uppercase/lowercase "verified" prose in an
  OPEN title → allow.)
- **fix(moa)**: the assembled decision doc was written to `--output`/stdout without
  passing through `redact()` — every error path was redacted, but the success doc
  was the one uncovered channel. A hostile/compromised or logging endpoint that
  reflects the request could echo the `Authorization` header into its completion,
  landing the raw key in the archived `DEC.md`. The doc is now redacted before it
  leaves the process. (+1 MoA test: an endpoint echoing the auth header into the
  success content cannot land the key in `DEC.md`/stdout — the prior success-path
  redaction test was vacuous because its stub returned no auth material.)
- **fix(sandbox-clean)**: teardown signalled only the bare recorded PID, so a dev
  server's forked worker children (vite→esbuild, npm→node) survived cleanup holding
  ports/CPU. It now snapshots each recorded PID's descendant tree via `pgrep -P`
  (before signalling, so reparented children aren't lost), then SIGTERM→grace→SIGKILL
  the whole set; falls back to the recorded PID where `pgrep` is absent. (+1 clean
  test: a recorded parent that forks a worker — the worker must not survive.)
- **docs**: both unattended drivers' exit-code-5 header now states the composite
  progress fingerprint (round | issues | converged_streak | runs count+bytes) instead
  of the pre-0.2.0 "round AND issues"; removed a stale dev-phase comment in
  `tests/run-all.sh` (the C16 the 0.2.1 hygiene batch tracked but missed).

## 0.2.2 — 2026-07-12

Audit batch 4: two code-review follow-ups on the batch-3 hygiene work. Both are
defensive robustness; behavior on the success path is unchanged and the full
suite is `ALL GREEN`.

- **fix(moa)**: proxy-credential redaction covered only the password. It now also
  scrubs the proxy username (raw and percent-decoded) and the base64 `user:pass`
  Basic-auth blob that `proxyAuthHeader()` writes to the wire — the blob is itself
  the credential, so redacting only its parts could miss it if it ever surfaced in
  an error excerpt. No active leak site existed; this is belt-and-suspenders.
- **fix(install-codex)**: a reinstall killed (INT/TERM) between the staged copy and
  the final atomic swap left a `loop-testing.staging.<pid>` orphan that no later run
  reaps (each uses a fresh `$$`). A scoped `trap` now reaps the staging copy on
  INT/TERM/EXIT, guarded to the `.staging.` basename so it can never touch `$DEST`.
- **test**: black-box moa case now asserts username + base64 blob never appear in
  output; new install signal-interrupt case proves the staging dir is reaped on
  SIGTERM mid-copy (verified failing without the trap).

## 0.2.1 — 2026-07-11

Production-readiness audit follow-up (batch 3 of 3): hygiene and robustness
cleanup. All backward-compatible; full suite `ALL GREEN`. (One item, an explicit
`hooks` declaration in plugin.json, was deferred — it risks double-registering the
Stop hook and needs a live-session smoke test; auto-discovery is verified working.)

- **fix(stop-gate)**: without jq/python3 the grep fallback never emitted an explicit
  `false` for `stop_hook_active`, so the block-counter reset didn't fire on a fresh
  stop and independent stops accumulated toward the ceiling. Also dropped an unused
  `converged_streak` grep.
- **fix(ledger-gate)**: the Bash write-verb allowlist now also covers
  `mv/cp/dd/perl/python`, so a command inlining a fabricated VERIFIED verdict via
  e.g. `perl -i` on the ledger path is caught. Dropped a dead NotebookEdit case arm.
- **fix(drivers)**: parity cleanup — the loop driver normalizes `round` like the codex
  driver, the codex driver gained the loop driver's driver.log writability guard, and
  watchdog kill-grace is unified to `-k 15`. A session that produces no STATE.md at all
  now fails fast after 1 session instead of burning 2.
- **fix(sandbox-clean)**: escalates SIGTERM to SIGKILL for a recorded process that
  ignores SIGTERM, so it doesn't leak past cleanup.
- **fix(install-codex)**: copies to a staging dir and swaps it in atomically, so a
  mid-copy failure can't leave a partial/unmarked install that the next reinstall
  refuses as "foreign".
- **fix(moa)**: an empty model name in config is now a clean `error` (exit 1) instead
  of a 400; a password in `*_PROXY` is added to the redaction set.
- **fix(unattended-codex)**: the skill-dir write-protection restore trap is now wired
  for `EXIT INT TERM` explicitly (not just implicit EXIT-on-signal), with test coverage.
- **chore(template)**: the seeded ISSUES.md placeholder no longer counts as a live
  issue (moved into an indented comment).
- **docs**: round-0 states the unfixable-baseline → BLOCKED terminal action;
  exit-and-report states the `round:` == `max_rounds` → INCOMPLETE rule precisely;
  moa-decision notes the direct-openai reasoning-model parameter limits.

## 0.2.0 — 2026-07-11

Production-readiness audit follow-up (batch 2 of 3): functional hardening that
unblocks unattended long runs and proxied environments. Minor bump — the behavior
changes are backward-compatible (they remove false-positives and add recovery), each
with a new env knob to tune or disable. Full suite `ALL GREEN` (MoA 25, driver +
sandbox + hook suites all green).

**What changes for you (all backward-compatible):**
- The unattended drivers no longer misfire NO_PROGRESS on a genuinely-progressing
  run (a deep round spanning sessions, or progress via convergence/evidence).
- A crashed run's leftover stop-gate sentinel now auto-recovers instead of taxing
  every future stop.
- New env knobs: `LOOP_TESTING_GATE_STALE_SECONDS` (default 86400, `0` disables),
  `LOOP_TESTING_MOA_MAX_RESPONSE_BYTES` (default 8388608).

- **fix(drivers)**: the no-progress circuit breaker was `round AND issue-count
  unchanged for 2 sessions`. A hard round spanning >1 session, or progress made by
  advancing `converged_streak` / appending `runs/` evidence before `round` ticks,
  changed neither and was misread as stuck (false INCOMPLETE, exit 5). Progress is
  now ANY change in the composite `round|issues|streak|runs(count+bytes)`
  fingerprint. Kept identical across both drivers.
- **fix(sandbox-setup)**: `sandbox-clean` removes the worktree but keeps the
  ownership marker, so a later `sandbox-setup` short-circuited "already initialized"
  and re-seeded WITHOUT recreating the worktree — a second QA run then operated on
  (and committed into) the main tree, defeating isolation. Setup now verifies the
  recorded worktree still exists in `git worktree list` and rebuilds it on the kept
  qa branch if gone.
- **fix(moa)**: the https-origin CONNECT+TLS proxy path (every proxied run) is now
  hardened and tested — an own timeout destroys an orphaned socket on a CONNECT
  hang, and bytes pipelined after the CONNECT header are preserved before TLS. A
  response body is capped at 8 MB (override `LOOP_TESTING_MOA_MAX_RESPONSE_BYTES`)
  so a hostile/misconfigured endpoint can't OOM a headless run. An `--output` write
  failure no longer discards an already-paid-for decision — it goes to stdout with a
  clean error. (+7 MoA tests incl. an end-to-end CONNECT+TLS tunnel with SNI.)
- **fix(stop-gate)**: a crashed run (SIGKILL) left `.active` + a non-terminal STATE
  forever, so every future stop ate a full block cycle. The gate now treats a STATE
  that hasn't been updated in `LOOP_TESTING_GATE_STALE_SECONDS` (default 24h, `0`
  disables) as abandoned — disarm and allow the stop. Fresh RUNNING still blocks.
- **docs**: README gains a stuck-sentinel / crash-recovery section.

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
