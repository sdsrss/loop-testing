# Changelog

## Unreleased

Four items from the 2026-09-20 audit's open list — D-07, K-14, T-16, T-08 —
plus three found in passing, each with its own commit. Five of the seven carry
a before-the-fix measurement; T-08 is a shape removed rather than a flake
reproduced, and the `--project /tmp` item had no defect to measure and carries
positive controls instead.

Suite 43 suites / 1739 assertions -> 43 / 1784, 0 failed on a space-free
`$TMPDIR`.

That qualifier used to hide a real gap. Measured under a `$TMPDIR` whose path
contains a space, and stated as **two** results because the runner keeps two
counters and an earlier draft of this paragraph merged them into one wrong
sentence:

- the suite reports **1779 assertions, 5 failed**, all five in `update-check`;
- separately, the fixture-leak gate fails the run on two suites —
  `session-stderr` and `codex-session-stderr` — which leave 25 and 24
  directories behind. A leak trip sets the run's exit status and contributes
  **nothing** to the assertion count, so no arithmetic ever reconciled "5
  failed" with three named places.

All three predate this batch: the same 24 and 25 are measurable at `v0.14.1`.
Every suite this batch touched is green under both shapes. Filed, not fixed.

An independent review round HAS now been run over this batch, and it found more
defects inside these seven fixes than the CHANGELOG first admitted. What it
found, and what was wrong in the first draft of these notes, is in *The review
round* below.

### What changes for you

- **`--no-watchdog` stops promising what it cannot do (D-07).** The flag waives
  the refusal to start when neither `timeout` nor `gtimeout` is on PATH. It does
  not switch a watchdog off, and on a host that has either binary it never did —
  measured: with the flag set, a `sleep 300` session is still killed at the
  session budget, `exit=124` in `driver.log`. Passing it where it cannot apply
  now says so on stderr and in the log instead of being accepted in silence, and
  the refusal message and both READMEs no longer read as a general offer of
  unbounded sessions. **Only the messages change** — what the flag does is
  deliberately untouched, since making it disable the watchdog, or renaming it,
  would change a published CLI contract. Note the new lines are real output: a
  `--no-watchdog` run on a watchdog-equipped host now writes one line to stderr
  and one to `driver.log` that were not there before, which matters if you
  scrape either.
- **Neither gate loses the evidence directory in a monorepo (K-14).** They
  anchor on `$CLAUDE_PROJECT_DIR`, the directory your session started in;
  `sandbox-setup.sh` creates `docs/looptesting/` at the git toplevel. Start a
  session in a subpackage and the two diverge. The stop gate read the missing
  sentinel as "no armed loop" and allowed every stop — the mechanism layer off
  for a whole run, with nothing in any log, because an allowed stop is also what
  a project that never ran the loop looks like. The ledger gate failed the other
  way: a `VERIFIED` write backed by a real replay at the toplevel was denied.
  Both now walk up to the toplevel, and only when there is no evidence directory
  at the anchor and the toplevel has one, so a repo that is not running the loop
  is unaffected and a subpackage running its own loop keeps its own.
- **`clean` no longer hands you `--force` for a worktree it cannot identify.**
  The `legacy` arm — a marker predating worktree stamping — printed a
  ready-to-paste `git worktree remove --force <path>` with "check it first"
  beside it, long after the `unknown` and `foreign` arms stopped doing exactly
  that. It now tells you to look first, with a command that can actually see
  what is in there — `git status --porcelain --ignored -uall` — and gives the
  removal as `git worktree remove -- "<path>"`. The `--` and the quotes are
  part of the fix, not typography: the old line interpolated the path bare, so
  a worktree under `~/My Projects/` produced advice git would misparse.

  **And it tells you where that stops.** git refuses over tracked-modified and
  untracked files; it does **not** refuse over ignored ones, and a finished loop
  sandbox is exactly that state, because the loop commits its fixes and what
  remains is build output, `.env` and logs. So `git worktree remove` will take
  such a worktree silently, at exit 0. Measured: `.env` + `node_modules/` +
  `dist/` + a log → `git status --porcelain` prints nothing, `--ignored -uall`
  prints four lines, and the removal succeeds and destroys the lot.

  The first draft of this bullet said the refusal *was* your check. It is not,
  and this paragraph is the correction — see *The review round* below, where a
  reviewer caught that promise and where the same mistake recurred one level
  down in the inspection command originally named here. The worktree was kept
  before and is kept now; only the advice changed.

### Test integrity

- **T-16, cases that inherited the environment they were testing.** Four hook
  cases did not override `$CLAUDE_PROJECT_DIR`, which Claude Code sets for every
  hook — so running the suite from inside a session anchored the hook at the real
  project. Four sites, but not four defects, and the first draft of this entry
  invited that reading: case K's pair produces the abort below, case M produces
  one failed assertion, and the ledger-gate site produces nothing at all — it
  sets `LOOP_TESTING_DISABLE_LEDGER_GATE=1`, which the hook checks before it
  reads the anchor, so its result cannot depend on one. Hygiene there, a defect
  in the other three. Measured: `CLAUDE_PROJECT_DIR=<repo> bash
  tests/hooks/stop-gate.test.sh` died at `kc: unbound variable`, having tested
  nothing past case K. Fixed at the call sites and, for whatever is written
  next, once in the shared lib. Separately,
  `check-update`'s offline case reaches the branch it names only when the host's
  proxy settings leave `127.0.0.1` alone: measured with `curl -v`, a host whose
  `no_proxy` does not cover it dials the proxy instead. The proxy variables are
  now stripped for that case. Nothing in the fixture proves the strip worked —
  that needs a CONNECT-capable proxy — and the file says so rather than implying
  a gate.
- **The eight remaining fixture accumulators were space-delimited strings**, torn
  apart by `rm -rf $WS_ALL` on any `$TMPDIR` containing a space. Measured: 8
  fixture directories left behind by one suite under such a `$TMPDIR`, 0 after.
- **Three usage-error cases pointed a full-permission driver at the host's real
  `/tmp`**, safe only while argument validation keeps running first. Aimed at a
  throwaway project now, and that ordering is asserted rather than assumed.
- **T-08, the three setsid waits the audit names.** An iteration count is not a
  time budget, and on expiry the message blamed the driver ("never wrote its
  lock pid") for what was only this harness failing to observe. Now a wall-clock
  deadline, overridable with `LOOP_TESTING_TEST_WAIT`. The old bounds were 10s
  for four of the six loops and 15s and 20s for case 19's pair — not a uniform
  "10s" as first written here; all six are 30s now. The cost is not zero and no
  count shows it: on a host that never reaches the state, those six waits go
  from 35s and 40s to 90s each, and the host that pays is the loaded one T-08 is
  about. **Not a reproduction:** the flake is intermittent, the audit did not
  reproduce it and neither did this round. The shape is removed and the budget
  widened; that is all this claims. `tests/driver/shutdown.test.sh` still uses
  the iteration-count shape in twelve more loops, and has its own `wait_lock_pid`
  that shadows the shared one — untouched here, so read the heading as the three
  cases named, not as "the setsid waits" in general.

### Ledger

- **K-15 was already closed** and never credited. All four things the audit said
  were missing are in `skills/loop-testing/SKILL.md` today — the deterministic
  locate command, the note that `${CLAUDE_PLUGIN_ROOT}` is guaranteed only to
  hook processes, the warning not to pick a plugin-cache directory by name, and
  the `BLOCKED` exit when nothing is found.

  The credit is a chain, not one commit, and the first draft of this entry gave
  all four to `930a20f`. Three predate it: the hook-process note came from
  `9674e5a`, the don't-pick-by-name warning from `63c3dd7`, and `085eac8`
  (v0.5.0) is the oldest commit `git log -S'BLOCKED'` reports for that file —
  weaker than it looks, and stated as such, because `-S` finds commits where an
  occurrence COUNT changed, so it locates a commit that touched the string
  rather than the one that introduced the clause. `930a20f` contributed the
  *deterministic form*
  of a locate command that already existed as `ls -d`. The method first cited
  for this — "verified against the file, not inferred from the diff" — can
  establish that all four are present and can never establish which commit added
  one; it was offered as support for exactly the half it cannot support.
- **Retracted — there was no such defect.** An earlier draft of this section,
  and the accumulator commit's message, said that under a `$TMPDIR` containing
  a space `sandbox-clean --purge` deletes a branch holding unharvested fix
  commits and orphans the marker its follow-up needs. **It does not, and never
  did.** Three lines of fixture did: `purge-ref-identity` extracted a worktree
  path with `awk '{p=$2}'`, which truncates at the first space, so its `cd`
  failed, the fix commit was never created, and six assertions failed in a
  cascade that reads exactly like a purge destroying real work. `shutdown` had
  the same class in two copies, joining argv with `"$*"` for `script -c`. Both
  repaired: under a spaced `$TMPDIR`, `purge-ref-identity` is 44/0 and
  `shutdown` is 154/0, no leftovers, and both unchanged space-free.

  The misreading is worth more than the bug would have been. A reviewer
  reported the purge failure as being in the script and marked it VERIFIED; the
  failures were real and reproducible, and what they were evidence OF was never
  checked. It then entered these notes as an open destructive-path defect — in
  a section whose subject is claims outrunning their evidence.

### The review round

Four independent reviewers over `v0.14.1..HEAD`, none of them the author. They
found **nine defects inside these seven fixes**, four of them High, and two of
those would have shipped as harm rather than noise. Every one below was
reproduced by the author before being acted on; two reviewer claims were
retracted after that check, and both retractions came from the reviewer.

**The two that blocked.**

- **F1 — the refusal my own advice leaned on.** dd09b85 replaced a paste-ready
  `--force` with plain `git worktree remove`, on the claim that git refuses
  while anything uncommitted or untracked is there. git does not refuse over
  IGNORED files, and a finished loop sandbox is exactly that state. So the
  repair told the user a guard would catch them in the one case where no guard
  fires. The old advice was dangerous and honest; that one was worse.
- **F2 — a new false deny.** K-14's walk-up moved cwd to the toplevel, which
  turned on the bare-basename rule, which made every path ending in `ISSUES.md`
  the ledger from any subdirectory — a false deny carrying an accusation, in
  the topology K-14 was written for. Fixing one direction of H-01 while opening
  the other is the specific thing that change set out to avoid.

**The rest:** a fixture self-probe that could not fail (it asserted the git
toplevel was *non-empty* rather than that it was the fixture's own repo, so an
inherited `GIT_DIR` sent the case at an unrelated repository); a consumer of
`WS_ALL` left reading it bare, so a 30-fixture process sweep covered one; an
unresolved anchor gaining authority it never had; a `|| :` that swallowed a
timeout and then blamed the driver for it; two cases whose own titles named a
premise they did not check; and five comments that no longer described their
code. All repaired above. **Not all with a RED**, and the first draft of this
line said otherwise: a failing-test-first repair is possible where a behaviour
changed — F1, F2, the anchor pair, the fixture probes — and is not where the
change was a comment, a message string, or a gate whose target is already
correct in the tree. Those carry a positive control instead: the defect is
injected into a working-tree copy and the check is shown to go red. Where
neither was done, the commit says so.

**Corrections to the first draft of these notes**, which is the part a reader
of the batch acted on. The commit messages are left as written — the repair
commits cite them by sha, and rewriting would dangle those citations — so the
corrections live here:

- `796af26` says "+7 assertions (stop-gate 72 -> 73, ledger-gate 161 -> 163)".
  Measured at `796af26^`: **67 -> 73 and 158 -> 163, +11**. The 72 is that
  commit's own *mutated-run* pass count, quoted correctly two paragraphs
  further down and misread as a baseline at the top. The 161 has no such
  excuse: it is not the baseline (158) and not the mutated run (162), so it is
  simply a number that was never measured — which a reviewer caught while
  checking the correction itself. Same error in `5712345`:
  "driver-limits 35 -> 36" is **33 -> 36**; its codex-limits figure is right and
  the +6 total is right.
- The shape behind both: a RED run already contains the new test code, so it is
  not the baseline. Recorded because it produced two false numbers in one batch.
- `85dbb80`'s "roughly 5x margin" assumes a 10s old bound; case 19's was 15s, so
  7.5x — and a single probe on an idle host bounds latency on that host only,
  which is the property an intermittent bug is about.
- `c5f2943`'s "with one site's `env -u` also reverted, the abort comes straight
  back" holds for case K's pair, not for all four sites.
- `08634bf` says "the six repair commits cite those by sha" as the reason not to
  rewrite history. The reason holds and the number does not: the range has kept
  growing as the review round went on, and the count was stale the moment the
  next repair landed. Cited counts of one's own commits age badly; the citation
  argument never needed one.
- **The user-facing `clean` bullet above kept the premise this round retracted.**
  It told the reader that `git worktree remove` "refuses while anything in there
  is uncommitted or untracked; that refusal is the check" — the exact sentence
  `ab542cb` was written to withdraw, left standing in the section a reader of
  the release acts on while the shipped script said the opposite and this
  section called it "worse than the `--force` it replaced". Corrected above. It
  is the v0.14.0 shape — notes claiming what the code does not do — occurring
  inside the round convened to catch it, and it was a reviewer who found it.

## 0.14.1 — 2026-09-21

### Corrections to the 0.14.0 notes, and the fixes behind them

0.14.0 shipped without an independent review round — stated in its own notes at
the time. That round has now happened, and it found that four of the entries
below claimed more than the code delivered. The corrections come first because
they are the part a reader of 0.14.0 acted on.

**Four findings were reported closed that were not.**

- **D-06, the driver lock.** 0.14.0 says "A driver lock held by a process you
  cannot signal is refused instead of stolen", with no qualifier, and names "another
  account on a shared box" as the case. That is the case it did not close. The
  fix replaced one probe that cannot answer (`kill -0` returning EPERM) with two
  that can also fail to answer — and both failures resolved to `gone`, the verdict
  that authorises stealing the lock. On a procfs mounted `hidepid=2` (ordinary
  hardening on exactly the shared box the note names) a live holder is invisible
  and its lock was still stolen. So was a holder on a host whose `ps` cannot
  answer. Both are now closed, by requiring a negative answer to prove the probe
  could have answered at all.
- **S-04, the unidentifiable worktree.** The guard tested whether
  `git worktree list --porcelain` FAILED. It also exits 0 and silently omits an
  entry whose admin dir is unreadable, which is the trigger the audit named, so
  the omission still came out as "already gone": `--purge` deleted the baseline
  tag, the branch, the evidence dir and the ownership marker over a worktree
  still standing on disk, and closed at exit 0 — the success code. Now closed for
  the worktree, the branch, the evidence dir and the marker, by testing for the
  checkout's own `.git` file, which survives both failure modes. The baseline tag
  is still deleted: it is identified by its recorded SHA rather than by name, and
  README.md already documents it as removed before the branch decision — the
  `BASELINE_HEAD` field in the kept marker is the anchor that replaces it.
- **S-06, clean signalling its own ancestors.** Partly closed, and the note did
  not say "partly". The guard covers this process and its parent unconditionally,
  and ancestors above that only when `ps` can answer — the loop could not tell
  "reached the top of the process tree" from "could not ask", so the chain
  silently truncated and the cleanup sent SIGTERM to its own parent and
  grandparent. 0.14.0 is still strictly better than 0.13.0 here, where an
  ancestor in `.pids` self-killed the cleanup unconditionally; it was the
  completeness that was overstated.
- **T-10, the leaking test fixture.** The commit titled "audit T-10" changed a
  different file, for a different defect. The file the finding names was never
  touched and still leaked every workspace it had made whenever it exited early
  — 11 of them, measured by injecting an early exit into the window, against 0
  after the fix. `tests/hooks/stop-gate.test.sh` turned out to hold the same
  construct and to leak 10 the same way; both are fixed here.
  (The audit report's own line numbers for T-10 are stale, which is the likely
  reason the fix went elsewhere; that report has been corrected too.)

**"No file format changed" was wrong.** `templates/FINAL_REPORT.md` is
instantiated verbatim into your `docs/looptesting/`, and 0.14.0 renumbered it.
Tooling keyed to the old section numbers is affected, and two of the changes are
not shifts but changes of meaning:

| Section | 0.13.0 | 0.14.0 |
|---|---|---|
| §6 | 遗留低级问题（P3） | 既有/环境问题 |
| §7 | 代码交付与红线声明 | 验证清单 |
| §8 | 残余风险与续跑入口 | 代码交付与红线声明 |
| §9 | — | 残余风险与续跑入口 |

A parser reading "§7 = 红线声明" now reads 验证清单, and "§8 = 残余风险" now
reads the red-line declaration. Nothing else about the format changed.

**"Both were verified by injecting the exact defects they exist for"** was
written by the same commit that widened the gate, not outgrown later. `69f3a7c`
injection-tested the gate it landed. Eight commits afterwards `23f267d` widened
the pattern to two more fixture prefixes, verified with a full green run — which
a permanently dead gate also produces — and published that sentence, covering
both halves, in the same diff. The gates do work; the sentence covered more than
its evidence from the day it was written.

### Fixes

- A worktree that `git worktree list` omits at exit 0 is no longer read as gone,
  and the branch deletion is gated on the same verdict — git's own "checked out
  elsewhere" refusal reads the same unreadable admin dir, so it was not a
  protection but a probe that failed silently (S-04, second arm).
- A driver lock holder that no probe can see is refused rather than stolen, and
  the verdict `case` is now matched-to-steal instead of matched-to-refuse: it
  listed the two refusals and let anything unanticipated fall through to the
  removal (D-06, residual).
- `clean` stops before the `.pids` stage when it cannot walk its own ancestry,
  and leaves the ledger for a later run rather than clearing a stage that did
  nothing (S-06, residual).
- The refusal over a worktree this run cannot identify no longer hands you
  `git worktree remove --force`. "If it is the sandbox's" reads as a yes exactly
  when the probe failed, which is when the worktree usually IS the sandbox's.
  The wording dates from 0.10.0 and was never a 0.14.0 regression; what 0.14.0
  changed is how often it fires, by adding a new way to reach the `unknown`
  verdict. The `foreign` arm keeps the `--force` advice, which is correct there.
- A parallel install's staging directory is no longer reaped when its owner is
  alive but unsignalable. The cost was not the discarded copy: a reap landing
  between the victim's two `mv`s left that install with its skill directory gone
  and only the `.bak` beside it (IN-1, residual).
- The last `$HOME` sibling of the two fixes that shipped in 0.14.0:
  `${CODEX_HOME:-$HOME/.codex}` reads as guarded and is not — the `:-` protects
  the outer name while the inner `$HOME` is expanded unguarded exactly when
  CODEX_HOME is unset. Under `set -u` that killed the Codex driver before
  `--help`.
- Test integrity: a negative assertion handed a `-`-leading needle straight to
  `grep`, which consumed it as an option and returned "not found" — reporting a
  present string as absent AND counting it as a pass. Four helpers were missing
  `--`; all four are fixed.
- The fixture-leak gate identifies leaks by containment now, not by a
  hand-maintained list of name prefixes that nothing kept in sync. Two counting
  defects went with it: moa suites were counted with `find` and executed with a
  one-level glob, and a suite's failed assertions were printed in TOTAL but never
  reached the ALL GREEN verdict.

This release had the independent review round 0.14.0 went without, and it found
eleven defects inside these repairs — three in the fixes' own logic, including a
canary that could not detect the failure it existed for, and a `--purge` that
deleted the ledger a new fail-closed path had just promised to keep. All eleven
are fixed here, each mutation-checked. That ratio is the third consecutive
release where the repair round carried about as many defects as the batch it
repaired, which is the argument for running it rather than a reason to doubt it.

Suite: 43 suites / 1657 assertions → 43 / 1739, measured with
`bash tests/run-all.sh | grep '^TOTAL:'` on a clean tree, not recalled.

## 0.14.0 — 2026-09-21

### What runs after something has already gone wrong

Thirteen findings from the 2026-09-20 audit, in two halves. The first is the code
that runs once a run is already in trouble: a teardown in an environment that is
not a login shell, a setup that refuses, a second driver meeting a lock. The
second is the test suite that was green across every one of them — five of its
own findings, plus three more of the same class that the audit had not seen.

No file format changed, no flag was removed, and nothing changes about a run that
succeeds. **Upgrading from 0.13.0** needs no action; the whole release reverts by
pinning the previous version — `/plugin install loop-testing@loop-testing
--version 0.13.0` for Claude Code, or re-running `install/install-codex.sh` from
a `v0.13.0` checkout for Codex.

Suite: 40 suites / 1548 assertions → 43 / 1657, both measured with
`bash tests/run-all.sh | grep '^TOTAL:'` on a clean tree, not recalled.

**This release has not had an independent review round.** The two before it each
found defects inside green, self-tested fixes — 18 in ten of them at v0.9.0, and
at v0.12.0 a CRITICAL introduced by the repair of a previous round. That history
is why the note is here rather than left implicit.

### Audit batch B — the teardown, the refusals, and a lock that could be stolen

Six code findings, and what they have in common is where they live: the paths
that run when something has already gone wrong. None is on the happy path, which
is why the suite was green across all six. Two documentation findings from the
same batch follow them.

**What changes for you.**

- A teardown started without `HOME` in the environment — cron, a systemd unit
  with no `User=`, `env -i`, a container entrypoint — now finishes. It used to
  exit 1 on an unbound variable inside the guard that protects `$HOME`, before
  removing the worktree and before disarming the stop-gate sentinel, so the
  cleanup failed exactly where $HOME did not exist and left the session unable
  to stop (S-05).
- A live worktree is no longer reported as "already gone" when `git worktree
  list` fails outright — an unreadable or locked `.git/worktrees`, a corrupted
  admin entry. The failed command used to read as absence, so `--purge` deleted
  the baseline tag and closed with "purge done." and exit 0 over a sandbox that
  was still standing. It now says it could not tell, keeps everything, and exits
  4, the code that already meant "ran but stopped short" (S-04).
- `sandbox-clean` will not signal its own process or its ancestors, whatever
  `docs/looptesting/.pids` says. That file is written from parsed `lsof`/`ss`
  output, and the process holding a port can be the session — or the unattended
  driver — that is running the cleanup; the recorded PID was expanded into its
  descendant tree, which contains the cleanup itself, so clean signalled itself
  and died before removing anything (S-06).
- A refused setup no longer leaves a `qa-baseline` tag behind. The tag was
  created before the worktree stage and the ownership marker is written at the
  end, so "worktree path already exists" — a refusal whose own message tells you
  to re-run — exited with a tag nothing recorded, and the retry correctly
  declined to claim it. The tag is now created last, after everything that can
  refuse (S-07).
- A worktree a rebuild could not claim stays named across later rebuilds. The
  marker is the only place that path is written down, and the second rebuild used
  to overwrite the record with its own verdict — after which `--purge` deleted
  the evidence dir that held it and never mentioned the worktree again (S-09).
- A driver lock held by a process you cannot signal is refused instead of
  stolen. `kill -0` fails both for "gone" and for "alive, owned by someone else",
  and the second reading put two `bypassPermissions` drivers on one `STATE.md`,
  `ISSUES.md` and worktree — the one thing the lock exists to prevent. A holder
  owned by root, by a systemd unit, or by another account on a shared box is
  ordinary (D-06).

**Documentation.** `templates/FINAL_REPORT.md` was missing two of the ten
sections `references/exit-and-report.md` §5 defines — pre-existing/environment
issues, and the verification checklist — so the model did not write them. Its
red-line sentence omitted `amend` and `rebase`, which SKILL.md forbids, and its
commit list never asked for the disclosure that matters: commits listed per
branch, with anything that landed on the main branch called out. It also carried
a P3-only section the reference does not define, beside a section already
ordered P0→P3 (K-12). And both READMEs now state that the target must be a git
repository — the sandbox is a worktree cut from it, `sandbox-setup.sh` refuses
with exit 3 without one, and the isolation gate then stops the run as `BLOCKED`;
previously that refusal was where you found out (K-13).

### The test suite, and what its green was not saying

The audit's P3 list included five findings about the tests themselves. They are
worth the same attention as product defects, because every claim this project
makes about a fix rests on the suite that checked it.

- A suite re-declared its cleanup trap at each workspace with a literal list of
  every variable so far, and at the last one the list was wrong. Six directories
  per run, for months, invisible because the suite was green (T-10).
- Two assertions in that same file called a helper defined in a different lib.
  The shell printed "command not found" on every run; the tally counted neither
  a pass nor a failure. One of them sits under a comment reading "this is the
  assertion that would have caught the defect."
- An assertion that a marker field is *empty* used a fixed-string match on the
  key, so it matched any value and could not fail (T-05).
- Two sites handed out `PASS=$((PASS+2))` when the fixture could not hold on
  that host — two passes for two assertions that did not run. The unknown-verdict
  case is now covered by a fixture that needs no privileges to work, so the arm
  is tested everywhere rather than on non-root hosts only (T-11).
- A captured refusal message that nothing ever asserted on, in a section whose
  neighbour asserts exactly that (T-12).
- An interrupt test that found its window with `sleep 0.5`. When the race is
  lost, the signal arrives before anything is staged and three assertions pass
  over a run that never entered the state they describe. It polls for the state
  now, and says so when it never arrives (T-13).

`tests/run-all.sh` gained two gates, because every one of those was invisible to
the gates it already had: a suite that grows the fixture count in `$TMPDIR`
fails the run, and so does a suite whose output contains "command not found".
Both were verified by injecting the exact defects they exist for — the run ends
in FAILED while the offending suite's own tally still reads "0 failed".

**Two more `$HOME` fixes, same shape as S-05.** The SessionStart update check
read `$HOME` bare under `set -u` and ended a hook with a raw unbound-variable
error in the user's terminal; it now does nothing at all when there is no cache
root, like every other unavailable resource in that file. And `install-codex.sh`
refused the same way instead of naming the two things that fix it — `--target`
or `CODEX_HOME`.

**Documentation.** Both READMEs sent the harvest step to `FINAL_REPORT.md §4`
for the ISSUE-to-commit table; it is in §3. The test for it reads the number off
the template rather than hardcoding it, so renumbering fails the suite instead of
quietly invalidating the instructions.

Every fix in this release is one commit carrying its finding ID, the numbers
measured before it, and the mutation check showing the new assertions can fail.

## 0.13.0 — 2026-09-20

### What a crash leaves behind, and what a failed session says

Two things, and they are the same thing seen from either side of a failure. The
skill now knows what to do with the four crash-adjacent situations it can find on
disk, instead of leaving them to the model; and a failed unattended session says
why it failed, instead of reporting `exit=N` and nothing more. Suite: 37 suites /
1389 assertions → 40 suites / 1548 assertions, both measured from a clean tree
with `bash tests/run-all.sh | grep '^TOTAL:'` — the first from a detached
worktree at `v0.12.0`, not recalled.

**Upgrading from 0.12.0.** No file format changed and no flag was removed. Three
defaults behave differently and are worth knowing before your next run: a project
whose `STATE.md` already holds a terminal status **reports instead of starting a
new round** when the skill is re-triggered with no arguments; a `FINAL_REPORT.md`
sitting next to `status: RUNNING` is now diagnosed rather than trusted; and the
unattended drivers **write a redacted tail of each session's stderr into
`driver.log`** — set `LOOP_TESTING_DISABLE_SESSION_STDERR=1` to keep that on
`/dev/null`. The whole release reverts by pinning the previous version —
`/plugin install loop-testing@loop-testing --version 0.12.0` for Claude Code, or
re-running `install/install-codex.sh` from a `v0.12.0` checkout for Codex.

**This release took five review rounds across two independent reviewers, and
three of the five found defects in the repair rather than in the original.** That
is recorded in the per-change notes below rather than smoothed over, because it
is the second release in a row where it happened and it is the reason D-05 needed
a second attempt at all.

### Audit batch A — what happens after a crash, and the two read-only modes

The product's central promise is that a crash is recoverable: progress lives in
`docs/looptesting/`, and re-triggering the skill continues from it. No script
implements that promise — `stop-gate` and both drivers only check whether a
terminal status was written — so what happens after a crash is decided entirely
by the prompt text the model reads. Four crash-adjacent situations were visible
on disk and named nowhere (audit K-09, K-10, K-11), and the two read-only modes
had no answer for the one hook that cannot see they are read-only (K-03).
Suite: 37 suites / 1389 assertions → 38 suites / 1420 assertions, measured from
a clean tree with `bash tests/run-all.sh | grep '^TOTAL:'`.

**What changes for you.**

1. **A finished run is not restarted.** Re-triggering the skill with no arguments
   on a project whose `status:` is already `CONVERGED` / `INCOMPLETE` / `BLOCKED`
   now reports instead of opening a new round. The unattended drivers already
   exited 0 there; the skill disagreed, so a project that had delivered a
   `FINAL_REPORT.md` could grow rounds on top of it and make that report's own
   round count false.
2. **A `FINAL_REPORT.md` sitting next to `status: RUNNING` is diagnosed, not
   guessed at.** That is the exit sequence interrupted between its first and
   second step. It is resolved by completeness — all ten sections present and the
   stop condition actually met resumes the exit sequence; anything less deletes
   the half-written report and keeps testing. Neither blanket rule is safe: one
   throws away a finished report, the other ships a half-written one as final.
3. **A round log numbered past `round:` costs that round, not the ledger.** The
   round was interrupted before it settled, so its scenarios are re-run and it
   cannot count toward `converged_streak`. Issues already filed stay filed.
4. **`.active` is re-armed when resuming.** The resume path never reaches the
   sandbox step that creates the sentinel, so every continuation after a crash
   ran with the Stop hook silently disarmed — indistinguishable, on disk, from a
   healthy one.
5. **`status` and `report` say what to do when the gate blocks them.** The Stop
   hook cannot see `$ARGUMENTS`, so a read-only query in a project with a live
   loop is blocked and told to "continue the round loop" — the one thing those
   modes forbid. The answer is now written down, including the two wrong exits:
   do not start a run to satisfy the gate, and do not delete `.active`, which
   would strip the guardrail off someone else's live run. The ceiling (3) is
   stated so the model knows the block terminates.

- **docs(protocol,skill)**: name the four crash-adjacent resumes (audit K-09,
  K-10, K-11) and the read-only/Stop-hook interaction (K-03). `round-0.md` §0
  owns the diagnoses; `exit-and-report.md` §4 now points at §0 for the window it
  creates, rather than leaving two prompt files to drift the way K-02 did.
- **ci**: pin `@anthropic-ai/claude-code` to 2.1.278 instead of `@latest` (audit
  H-06). The job is a schema gate whose verdict is the CLI's validator, so an
  unpinned install made a red run indistinguishable from a manifest this repo
  broke, and a green one no evidence about the next.
- **test**: one new suite, `tests/commands/resume-protocol.test.sh` (31
  assertions). Every assertion was run against the pre-fix text and failed there
  (26 of 31; the rest are extraction and pinning checks), and four were
  mutation-checked against the specific reverts they exist to catch — including
  a `.active` rule that keeps "confirm it exists" but loses the command to
  rebuild it, which is the shape that would have passed a vocabulary match. The
  suite also pins `MAX_BLOCKS=3` in `hooks/stop-gate.sh` to the number SKILL.md
  now quotes.

### D-05 returns: a failed unattended session says why

The session-stderr capture pulled from 0.12.0 is back, with the design its review
asked for. **A failed unattended session now appends the last 20 lines (4000
bytes) of that session's stderr to `driver.log`, redacted**, under
`session N stderr:` — where an expired key, a rate limit, an unknown flag or a
bad working directory actually says which one it was. Every one of those used to
arrive as `exit=N` plus the no-progress verdict, indistinguishable. Set
`LOOP_TESTING_DISABLE_SESSION_STDERR=1` to keep it on `/dev/null`.

**What changed from the version that was pulled.** That one bounded the capture at
a writer — `2> >(tail -c … > "$SINK.part"; mv -f …)` — and the opt-out made it
fatal: the sink is then `/dev/null`, `/dev/null.part` is not creatable by a normal
user, so the writer exited, the session's stderr pipe lost its reader and every
session died of SIGPIPE at round 0; under root the rename replaced the
`/dev/null` device node itself. This one is a plain redirect into a fresh file per
session. No writer, no second path derived from the sink, nothing to wait for.

Three review rounds across two independent reviewers found the rest, and two of
the three were defects in the repair rather than in the original:

1. **One file per session, not one file reused.** `O_TRUNC` resets a file's size,
   never the offset of an already-open file description, so a background
   grandchild still holding fd 2 wrote into the *next* session's file at its
   stale offset — its output filed under that session, and that session's own
   error pushed out of the tail window. Reproduced: session 2's expired-key
   message absent from the log. The D-05 symptom, produced by the D-05 fix.
2. **The byte cap amputated labels.** `tail -c` cuts on a byte boundary before
   redaction runs, so a credential straddling 4000 bytes reached the rules with
   its `"api_key":"` removed — a bare run, under the fallback, published verbatim
   while the filler after it was masked, so the line read as redacted. One
   4091-byte HTTP dump leaked 18 of a 31-character secret. The partial first line
   is dropped now, and the log says so when that leaves nothing.
3. **Redaction: a quoted `"authorization": "Basic …"` bypassed the header rule**
   entirely (JSON, Python and Ruby all put a quote where it wanted a colon), and
   glued credential names — `accessToken`, `ClientSecret`, `dbPassword` — bypassed
   the name rule, which wants a separator before the secret word. Both are
   matched now. Two attempts to do the glued case *structurally*, on
   capitalisation, failed in opposite directions: `accessToken` and `nextToken`
   are both lowerCamelCase, `AccessToken` and `SyntaxToken` are both PascalCase,
   so case discriminates nothing. It is an enumerated prefix list.

**Known holes, stated rather than closed** (both READMEs carry the full list): a
value under 10 characters after a credential-shaped name is not masked, which
costs `token: unexpected end of input` one word; an unlisted prefix
(`twilioToken=`) and a glued suffix (`keyId=`) are not recognised; hyphenated CSS
spec names (`ident-token:`) are; an unlabelled 40-character AWS key is not, because
widening the fallback to reach it redacts every absolute path in every `ENOENT`;
an `authorization` value on the following line is not; and within one session the
capture file is unbounded. The masking is shape-matching and is documented as
best effort, not a guarantee.

- **fix(driver)**: capture each session's stderr into its own file and append a
  redacted tail to `driver.log` (audit D-05). `shutdown_handler` keeps that file,
  and names it on stderr, when a session outlived `SIGKILL` — that is the one
  case where it is the only record of what the surviving full-permission session
  was doing, and the path that deleted it did so at the moment the user was being
  told to go investigate.
- **test(driver)**: two suites, one per driver copy, 63 + 47 assertions. The
  cross-session case carries a self-probe, because both of its assertions pass if
  the grandchild never writes. Three assertions across these suites were found
  passing for the wrong reason during review and rewritten — one of them by
  applying the reviewer's method to a fixture of my own, where a marker added
  without adjusting the arithmetic moved the byte cut and left the leak assertion
  naming a fragment that was never exposed.

## 0.12.0 — 2026-09-20

### Audit batch 2 — three of the four it started with

v0.11.0 shipped the audit's eleven-item blocking list. This is the start of what
the same report filed as batch 2: the one remaining fail-open in the mechanism
layer, the MoA routing that reported a broken configuration as ready, and the
convergence rule that decides whether the loop ever stops. Suite:
36 suites / 1308 assertions → 37 suites / 1389 assertions, both measured from a
clean tree with `bash tests/run-all.sh | grep '^TOTAL:'`.

It started with four. **The fourth — writing each session's stderr into
`driver.log`, so a failed unattended run says why — was pulled from this release
and is not in it.** Two independent review passes found 1 CRITICAL, 2 HIGH,
4 MEDIUM and 3 LOW in that one change, every one of them introduced by it, and
the last round's CRITICAL was introduced by the round of repairs before it: with
the documented privacy opt-out set, the capture pipe had no reader and every
session died of SIGPIPE at round 0, and under a root user (Docker's default) the
writer replaced the `/dev/null` device node with a regular file. The feature is
diagnostics; the other three are safety and correctness. It returns as its own
change, with the design the reviewer recommended instead of the one that kept
failing.

Every fix here was written by one agent and then attacked by two others that had
not written it, and that second pass is most of what follows: **the fixes this
batch set out to make contained more HIGH defects than the batch was fixing.**
The pattern from the last two releases repeated exactly — across both rounds,
1 CRITICAL, 7 HIGH, 13 MEDIUM and 10 LOW inside commits whose own tests were
green.

The one worth reading: **the H-03 fix made the Stop hook fail OPEN, twice.** Its
builtins-only dedupe is O(n²) and runs after the hook's internal timeout budget,
and the platform treats a Stop hook killed by its 15s manifest timeout as
"allow" — 18 000 machine-field lines took 14.7s. The first repair capped the line
COUNT, which the second review showed does not bound the cost at all: 200 legal
lines of 100 KB each is 20 MB of scanning, killed at 15s, where the parse it
replaced answered in 0.8s. Values are bounded now as well as lines. The header
comment asserting the gate "cannot approach the timeout" had been true only of
the code it replaced, and says so.

Also worth stating: the first measurement said the new hook was *faster* than the
old one. The harness passed a relative path into a subshell that had already
`cd`'d, so the hook never ran and the timing was bash failing to open a file — a
correct ship-blocking finding nearly dismissed on a broken check.

**Upgrading from 0.11.0.** Nothing to migrate: no file format changed, no flag
was removed, and the unattended drivers are byte-identical to 0.11.0. One default
behaves differently and is worth knowing before your next run: **a `STATE.md`
carrying two different `status:` values now blocks the stop** where it used to
take the first one, and one carrying more than 200 machine-field lines is refused
outright. If you hand-write that file, keep `status:` and `round:` to one line
each. The whole release reverts by pinning the previous version — `/plugin install loop-testing@loop-testing --version 0.11.0` for Claude
Code, or re-running `install/install-codex.sh` from a `v0.11.0` checkout for Codex.

**What changes for you.**

1. **A STATE.md carrying two different `status:` values now blocks the stop.** The
   gate took the first one, so an example or quoted `status: CONVERGED` written
   above the real `status: RUNNING` let the session stop and deleted the `.active`
   sentinel on the way out. Repeats that agree still parse; only disagreement
   blocks, and the reason names both values.
2. **A STATE.md the gate cannot parse cheaply is refused, not parsed anyway.**
   More than 200 `status:`/`round:` lines, or values longer than 64 characters,
   and the gate blocks and says so. An honest STATE.md has two such lines.
3. **`moa.mjs` says when your model ids cannot resolve.** With only
   `OPENAI_API_KEY` set, the OpenRouter-namespaced default models resolve to
   `api.openai.com`, where every request 404s — and `--dry-run` used to report
   that configuration as fully resolved. Both `--dry-run` and the real run now
   name it and the three ways out. A custom `OPENAI_BASE_URL` stays quiet, since
   gateways do accept namespaced ids.
4. **A round that tests less than before resets the convergence streak**, instead
   of merely not counting: A-converged / B-shrunk / C-converged used to reach
   `converged_streak: 2` on two rounds that were never consecutive. "Not
   significantly below previous rounds" is now a number — `cases_this_round` at
   least 80% of the maximum over the last three rounds, read from
   `runs/round-N.md`, with one exception that has to be an inequality rather than
   a paragraph and has its own slot in the round template. One case is defined:
   a FEATURE_MATRIX row times a PLAN scenario.
5. **A P0-P2 marked `CANNOT_REPRODUCE` no longer blocks convergence forever.**
   `issue-rules.md` requires that state for anything that will not reproduce
   while the convergence criteria refused it. `FIXED_UNVERIFIED` is now named and
   refused on purpose, with its way out stated.

- **fix(hooks)**: a conflicting `status:` line is ambiguity, not a verdict (audit
  H-03). `head -1` resolved a duplicated machine field by position, which is
  fail-open in the destructive direction — the same shape as deciding a path's
  role from raw command text. The parse is builtins-only: `sort`/`wc` would have
  read a terminal status as unparseable on the bare PATH the grep-only and
  python3-only legs run under. **Review then found three defects inside that
  fix**, two of them fail-open where the code it replaced blocked: the parse was
  unbounded (O(n²), 14.7s on 18 000 machine-field lines, past the 15s manifest
  timeout that the platform treats as "allow"), reporting an ambiguous `round:`
  as -1 disabled the progress reset for a whole continuation chain so the
  deadlock valve force-allowed a *live, advancing* loop on its fourth stop, and
  an empty `status:` value was dropped rather than counted, letting a bare
  `status:` above a real `status: CONVERGED` disarm the gate. The parse is now
  capped at 200 machine-field lines and fails closed; progress is measured by the
  round-value SET rather than one normalized integer; an empty value counts.
  A second review pass then showed that line cap does not bound the COST — 200
  legal lines of 100 KB each is 20 MB of scanning, killed at 15s where the old
  parse answered in 0.8s — and that truncating the round signature to a prefix
  re-opened the force-allow it was written to close. Values are capped at 64
  characters and the signature is the whole set. Two residuals are stated rather
  than closed: round values differing only past character 64 dedupe to one, and a
  `round:` line carrying something volatile means this valve never fires.
- **deferred**: the D-05 session-stderr capture is NOT in this release. Two
  review passes found 1 CRITICAL, 2 HIGH, 4 MEDIUM and 3 LOW inside it, all
  introduced by the change itself, and the CRITICAL was introduced by the repairs
  to the round before: with `LOOP_TESTING_DISABLE_SESSION_STDERR=1` set, the
  bounded writer resolved to `/dev/null.part`, which a normal user cannot create,
  so the capture pipe had no reader and every session died of SIGPIPE at round 0
  — and under a root user (Docker's default) the writer's rename replaced the
  `/dev/null` device node with a regular file holding the unredacted tail. The
  reviewer's own advice on a further MEDIUM was to abandon the pipe design the
  repair had adopted. The unattended drivers are therefore byte-identical to
  0.11.0, and a failed session still reports `exit=N` and nothing more. It comes
  back as its own change: a plain-file redirect with a per-session truncator, and
  a redaction set that does not treat `key` as a substring — `monkey`,
  `keyboard` and `token: expected ';'` were all being gutted out of exactly the
  diagnostics the feature exists to preserve.
- **fix(moa)**: warn when a namespaced `vendor/model` id resolves to provider
  `openai` at the stock endpoint (audit M-06). Warned, not refused: refusing
  would repeat the M-03 first attempt, which turned a documented exit-2 degrade
  into exit 1 and stalled the loop.
- **docs(protocol)**: convergence criteria 3 and 7 made decidable (audit K-06,
  K-07), plus the two copies each rule runs through — `runs/round-N.md` is named
  the single source for `cases_this_round` (K-21) and the `STATE.md` template's
  shorter zero-list defers to the reference and carries the new trigger (K-22).
  A template that disagrees with the protocol is the rule the model follows.
- **fix(moa)**: the M-06 gate decided by the provider NAME and by a string
  compare against the default base URL, so it stayed silent on two live
  404-every-request configs — a differently-cased `api.openai.com`, and any
  `OPENROUTER_*` variable pointed at stock OpenAI. It resolves the URL and
  compares hosts now, for any provider. Deciding a referent's role by its name
  instead of resolving it is this project's recurring defect shape, and the fix
  written for it had the same bug.
- **test**: one new suite, `tests/commands/convergence-criteria.test.sh`, plus
  two rounds of repairs to the assertions themselves, because review showed four
  of them green against reverts of the very rules they claimed to hold, two more
  green against the pre-fix binary, and the stop-gate regression case green
  against a file that still escaped the timeout. Where a test asserts over a document or a report, it now names
  the phrase that distinguishes the right rule from the wrong one, and says in
  its own header that a text predicate cannot do more than that.

## 0.11.0 — 2026-09-20

Two batches, in the order they landed: a fresh-user QA pass, then the blocking list
from a full audit of the project. The second is the larger of the two and comes first
here because it is what decides whether this release is safe to run unattended.

**Upgrading from 0.10.0.** Nothing to migrate: no file format changed, no flag was
removed, and markers written by every version since 0.1.0 still load. Four defaults
behave differently and are listed under "What changes for you" below — the ones to
know before your next run are that `--purge` now keeps more than it used to, that
`sandbox-setup.sh` can exit `9` where it previously carried on, and that a proxy
username is no longer treated as a secret. If a change does not suit you: the ledger
gate is off with `LOOP_TESTING_DISABLE_LEDGER_GATE=1`, the shutdown wait is tunable
with `LOOP_TESTING_STOP_GRACE`, and the whole release reverts by pinning the previous
version — `/plugin install loop-testing@loop-testing --version 0.10.0` for Claude
Code, or re-running `install/install-codex.sh` from a `v0.10.0` checkout for Codex.

### Audit batch 1 — the blocking list

An independent six-reviewer audit of the whole project found 101 issues, 2 of them
rated P0, and concluded the project was a mature beta rather than production-grade.
Its two blocking reasons were that the documented way to stop an unattended run did
not stop it, and that a key with a trailing space or `\r` was echoed into a decision
document verbatim. This batch is its eleven-item blocking list.

Every fix here was written by one agent and then attacked by a second one that had
not written it, and that second pass is most of what follows: **it found a defect
inside all five of the fixes, including three regressions and one P0 that the first
round's own tests called closed.** The pattern from the previous release repeated
exactly — green tests prove the cases the author thought of.

The finding not in the audit: **`bash tests/run-all.sh` printed `ALL GREEN` while
running 12 of 35 suites.** The loop feeds the file list on stdin, and a suite added
in this batch drains stdin, so it ate the rest of the list and the run ended early
with nothing to see. All 35 pass once they actually run, so nothing was hiding — but
every "full suite green" claim made while that was true covered a third of the tree.
The runner now compares suites executed against files found and fails on a mismatch.

Totals are now one line the runner prints and a release note can quote:
`TOTAL: 36 suites, 1308 assertions, 0 failed`, recomputable with
`bash tests/run-all.sh | grep '^TOTAL:'`. A suite is one file under `tests/` matching
`*.test.*`; an assertion is one pass-or-fail decision a suite reports. Three different
totals were quoted for this same tree earlier in the batch, which is what that line
exists to end.

**What changes for you.**

1. **You can stop an unattended run.** `Ctrl-C`, `SIGTERM`, `SIGHUP` and a process-group
   signal now stop the agent session, not just the driver, and the lock is released only
   after the session is gone. Pressing `Ctrl-C` twice escalates to `SIGKILL` immediately
   instead of cancelling the first stop. The driver prints what it is waiting for, so a
   20-second wait no longer reads as a hang.
2. **The unattended drivers run the agent with `--permission-mode bypassPermissions`
   (Claude) and `-s danger-full-access` (Codex).** That was always true and was never
   written down. Both READMEs now say so, and say the watchdog kill is the only boundary.
3. **`--purge` deletes by identity, not by name.** A `qa-baseline` tag or `qa/loop-testing`
   branch you re-pointed is kept and named. `--purge` deletes nine files it wrote,
   by name, and removes `runs/`, `decisions/` and `.driver.lock` whole. Anything else
   in the directory keeps the directory, and the ownership marker and `STATE.md` are
   kept with it — as they are whenever a ref is kept, so the `--discard-fixes`
   follow-up the tool recommends still has the record it needs.
4. **`sandbox-setup.sh` refuses an unreadable ownership marker (exit 9)** instead of
   announcing "already initialized" with no worktree behind it.
5. **The README's purge command works when pasted.** It printed candidate install paths
   and bound `SKILL_DIR` to nothing, or to a truncated cache path.
6. **The proxy username is no longer redacted from decision documents.** Only the
   password and the base64 `user:pass` blob that goes on the wire are treated as
   secrets, because an ordinary username such as `admin` was rewriting every
   occurrence of that word in the archived output. If your `*_PROXY` URL carries a
   username you would rather not see in evidence files, remove it from the URL.
7. **A `docs/looptesting/moa.config.json` keeps `--purge` permanently incomplete.**
   That is the path `README.md` documents for it, and purge treats any file it did
   not write as yours, so the directory is kept every time and no flag finishes the
   job. Move the config elsewhere and pass `--config`, or remove the directory by
   hand once you have taken what you want. Relocating the default path out of the
   directory purge owns is filed for the next batch.
8. **Purge keeps the evidence directory whenever it keeps a ref**, because the
   marker inside it is what the recommended follow-up reads. In `--mode branch` that
   is every run: git will not delete the branch you are standing on, so switch away,
   delete it, and purge again. A purge that had to leave a worktree standing exits
   `4` rather than reporting a plain "done".
9. **Shutdown exit codes are `130` (INT), `143` (TERM), `129` (HUP) and `131` (QUIT)**,
   and the wait before `SIGKILL` is tunable with `LOOP_TESTING_STOP_GRACE`.
10. **The unattended drivers write `docs/looptesting/.sandbox/created-dirs.env`** so a
   headless run's evidence directory is recognised as the tool's own and `--purge` can
   remove it, instead of being kept forever with the wrong explanation.
11. **`moa.mjs --dry-run` prints a different report**: one line per endpoint naming the
   proxy decision, the `NO_PROXY` list, and base URLs with any userinfo stripped. A
   non-`http:` proxy for an endpoint that actually selects it is now refused at config
   time with exit 1 instead of being spoken to in plaintext.
12. **`sandbox-setup.sh` rebuilds the worktree when the marker records an empty one**
   rather than treating the absence as "we own this" and arming the sentinel with no
   isolation behind it.

- **fix(driver)**: stop the child session before releasing the lock (audit D-01, P0).
  `timeout` puts the session in its own process group, and the driver ran it as a
  foreground subshell with no `wait`, so a signal killed the driver, freed
  `.driver.lock`, and left a `bypassPermissions` session running — a driver started
  afterwards then raced it for the same `STATE.md` and worktree. The session is now
  launched in the background and awaited; the handler signals its group, polls, and
  escalates to `SIGKILL` at a bound derived from the watchdog's own `-k 15` rather than
  chosen. Two further holes were found by review, not by the fix: releasing the lock
  before the session had actually exited, and a second signal arriving mid-wait finding
  the guard variable already cleared and freeing the lock anyway — reachable by pressing
  `Ctrl-C` twice, which is what a user does when nothing prints for 20 seconds. A
  session that survives `SIGKILL` now keeps the lock, with the lock's pid rewritten to
  name the survivor so the next driver refuses rather than stealing it. Known and
  documented: a `SIGKILL`ed driver, and a grandchild that escaped via `setsid`.
- **fix(moa)**: redact the value that is actually sent (audit M-01, P0). `collectSecrets`
  stored the raw env value while the request sent `value.trim()`, and redaction is a
  literal match, so a key with a trailing space or `\r` — a CRLF `.env` is enough — came
  back from an echoing endpoint and landed in `DEC.md` and on stdout. Both forms are now
  registered. Review then found three more paths to the same leak: a secret straddling
  the 20000-character field cut, one escaped by `JSON.parse` round-tripping, and one
  inside an object key at the depth cap, where serialization ran before redaction. All
  now redact before every cut and during serialization. The length floor that briefly
  guarded against mangling ordinary words was removed: it leaked any credential shorter
  than four characters, and inverted the first fix for a value whose trimmed form was
  shorter still.
- **fix(moa)**: honor `NO_PROXY`/`no_proxy` and refuse a proxy scheme that is not `http:`
  (audit M-02, M-03). An `https://` proxy was spoken to in plaintext with
  `Proxy-Authorization` attached, and `socks5://` was spoken to as if it were HTTP. The
  first attempt refused *any* non-http proxy variable, which broke the ordinary Clash and
  v2rayA setup where `all_proxy` is socks and never selected, and turned the documented
  exit 2 degrade into exit 1, stalling the loop instead of degrading it. Only the variable
  an endpoint actually selects is now refused.
- **fix(hooks)**: decide ledger writes by lexing the command (audit H-01, H-04, H-05,
  H-07). The old predicate denied any command that merely contained an ISSUE-ID, the word
  VERIFIED, the ledger path and any write-ish token, so a read-only
  `grep … 2>/dev/null` was refused with an accusation of faking verification — while
  `sed -i 's/FIXED_UNVERIFIED/VERIFIED/' ISSUES.md` passed untouched. Both are the same
  bug: a predicate over raw command text cannot tell what role a path plays in a command,
  so every tightening under-matched and every loosening over-matched. The gate now lexes
  with `shlex` and compares operand tokens to the ledger path, falling back to the old
  regex without `python3`, past a length cap, or on a lexer rejection — because a command
  the lexer rejects is frequently still a command the shell runs. Four review rounds each
  found another way to name a writer indirectly: `sponge`, `tee`, a lone writer fed by a
  redirect, wrapper verbs like `command` and `env`, and `sort -o`. The header now states
  what still gets through rather than claiming the family is closed.
- **fix(sandbox)**: purge deletes a tag or branch only when it still resolves to the
  recorded `BASELINE_HEAD` (audit S-03); setup validates the marker it resumes from and
  refuses with exit 9 rather than defaulting to "we own this" (S-01); both readers strip a
  carriage return, and only a carriage return, so a CRLF marker no longer produces a
  CR-named worktree and a path ending in a space still resolves (S-08); re-anchoring
  accepts a candidate only when its own `git-common-dir` matches ours, so a bare repo or
  a `--separate-git-dir` nested inside another repository no longer builds the sandbox in
  the wrong repository (S-02).
- **fix(sandbox,driver)**: `--purge` removes only files the sandbox wrote, keeps and names
  anything else, and keeps the ownership marker and `STATE.md` whenever it keeps the
  directory — otherwise the next `--purge` refuses at exit 3 with no way to finish. That
  combination could only arise once the driver claimed the evidence directory it created
  (D-03), and neither half produced it alone.
- **fix(install)**: the Codex prompt is claimed by a checksum recorded at install time,
  never by filename (audit H-02). A prompt you wrote, or one you edited after installing,
  is kept and named on both install and uninstall, and a symlink at that path is never
  written through — which on macOS would have created the far end of a dangling link.
- **fix(driver)**: `unattended-codex.sh` absolutizes a relative `--project` (audit D-02),
  which otherwise failed every session and reported it as the no-progress circuit breaker.
- **docs**: the `SKILL.md` fallback for "scripts not found" told the model to isolate by
  hand, which `round-0.md` forbids and its own gate blocks — it now locates the install
  deterministically or stops at `BLOCKED` (K-01); the `FINAL_REPORT` template told the
  model to clean before writing the report, the reverse of the protocol (K-02); the README
  purge command defines `SKILL_DIR` before using it, quoted so a careless paste fails
  naming the placeholder rather than binding an empty or truncated path, and the glob's
  plugin and skill segments are derived from the manifests so a rename cannot leave the
  documentation stale and the test green (K-05); `issue-rules.md` no longer calls the
  ledger gate fail-closed (K-04).
- **test(runner)**: every suite runs, every suite reports a tally, and a suite that
  reports none — or reports zero assertions — fails the run instead of passing quietly
  (audit T-03, T-04). `run-all.sh` no longer uses `mapfile`, which is bash 4+, so the
  runner starts on macOS's bash 3.2 (T-09).
- **test(driver,sandbox)**: `agent-binary-preflight.test.sh` no longer `chmod`s the real
  `~/.codex` (audit T-01), and `clean-pid-guard.test.sh` reaps its sentinel (T-02).

Still open, deliberately: the marker's recorded `TOP` is never compared against the
repository being purged, so a marker carried to another machine drives deletion in the
wrong repository (audit S-14). The comparison is two lines; the rule around it is not,
because a renamed project directory makes `TOP` legitimately stale while every other
field stays correct. It needs a rename-tolerant rule, a message and tests of its own.

### Fresh-user QA pass

A fresh-user QA pass: install → use → update → self-heal → uninstall, run end to
end in a throwaway `HOME` against the plugin as a stranger would receive it. The
headline find is that the plugin's own skill never loaded. Claude Code registers
`commands/*.md` as flat **skills**, in the same namespace as `skills/*/SKILL.md`
— so `commands/loop-testing.md` and `skills/loop-testing/` both claimed the name
`loop-testing`, the `commands/` copy won, and `SKILL.md` was unreachable through
the slash command *and* the trigger phrases. The command's body said "invoke the
`loop-testing` skill", which resolved back to itself. Confirmed by sentinel
probes in a live session, not by reading: replacing each file's body with a
distinct token and invoking `/loop-testing`, `/loop-testing:loop-testing` and
`自测` returned the `commands/` token every time, and a variant instructed to
reach the skill via the Skill tool looped on itself and never reached it.
`claude plugin details` reported `Skills (2) loop-testing, loop-testing` before
the fix and `Skills (1)` after, with always-on context dropping ~248 → ~177 tok.
The rest of the batch is what the same pass turned up around it. Full suite
`ALL GREEN`: 486 shell assertions across 24 suites → 670 across 28 (both trees
measured the same way — summing each suite's own reported pass count; moa
unchanged at 41 node tests). Every new assertion is mutation-checked: the
collision guard goes red when `commands/loop-testing.md` is restored, and the
manifest guards go red when `${CLAUDE_PLUGIN_ROOT}` is dropped from a hook
command, when a hook points at a script that does not ship, and on a version
desync.

**What changes for you.**

1. **`/loop-testing` now reaches the real skill.** The slash command keeps its
   name and its four modes (`status`, `report`, focus, round cap) — the dispatch
   moved into `SKILL.md`, where `$ARGUMENTS` substitutes the same way. Verified
   live: `/loop-testing status` on a project that never ran reports that it never
   ran and starts nothing.
2. **`sandbox-clean.sh --purge` refuses an unreadable ownership marker** instead
   of concluding it owned nothing. If you scripted around a `purge done.` exit 0
   that was really a no-op, it now exits 3 and names the file.
3. **`sandbox-setup.sh` and `sandbox-clean.sh` answer `--help`/`-h`**, printing
   their usage and exit codes. `--help` wins over `--purge` on the same line.
4. **The update-check throttle moved to `${CLAUDE_PLUGIN_DATA}`** for plugin
   installs, so `claude plugin uninstall` removes it (`--keep-data` keeps it).
   Codex and `--plugin-dir` loads still use `~/.cache/loop-testing/`.

- **fix(skill)**: remove `commands/loop-testing.md` and fold its four-mode
  dispatch into `skills/loop-testing/SKILL.md`. The two files registered the same
  skill name, so `commands/` shadowed the skill and nothing in `SKILL.md` — the
  round protocol, the red lines, the script locations, the dual persona — ever
  loaded through either documented entry point.
- **fix(sandbox)**: `sandbox-clean.sh` validates the ownership marker before
  acting on it. Every field is read with a `grep '^KEY=' | cut` helper, so a
  truncated or corrupted marker returned empty for *every* key — indistinguishable
  from "this run created nothing". `--purge` printed `purge done.` and exited 0
  over a sandbox whose qa branch, baseline tag, worktree and evidence dir were all
  still on disk. A marker must now carry `SANDBOX_VERSION` (numeric), `MODE` and
  `TOP` — the three keys every marker has written since v0.1.2, so v1 markers are
  unaffected — or it is treated as less knowable than a missing one: exit 3 under
  `--purge`, deleting nothing, naming the file.
- **fix(driver)**: `unattended-loop.sh` / `unattended-codex.sh` preflight the
  agent binary. Both checked `timeout`/`gtimeout` carefully and never checked
  `$CLAUDE_BIN` / `$CODEX_BIN`, so a missing or misspelled binary burned two
  session slots and surfaced as `NO_PROGRESS: … agent likely failed before round
  0` — blaming the loop for an executable that was not there. Now exit 2 before
  the first session, naming the binary.
- **fix(sandbox)**: `--help` / `-h` on `sandbox-setup.sh` and `sandbox-clean.sh`,
  rendered from each script's own header block so usage and exit codes cannot
  drift from the comment documenting them. These are the two scripts the README
  tells a user to run by hand, including the destructive `--purge`; both used to
  answer `unknown argument: --help` and exit 2.
- **fix(hooks)**: `update-check.sh` writes its 24h throttle to
  `${CLAUDE_PLUGIN_DATA}` when set, falling back to `${XDG_CACHE_HOME}`. The
  explicit `LOOP_TESTING_UPDATE_CACHE` override still outranks both. Verified
  that Claude Code exports the variable to hook processes and that
  `claude plugin uninstall` reaps that directory.
- **fix(ci)**: the `plugin-validate` job was a no-op gate. `claude plugin validate .`
  resolves to the *marketplace* manifest (both manifests live in `.claude-plugin/`),
  reported `"contents": []` and exited 0 without ever reading `plugin.json`, the
  skill, or the hooks — so a broken plugin manifest would have shipped green. It
  now validates both manifests by name and asserts `.manifest.type == "plugin"`,
  which is the failure itself: a marketplace-typed report means the plugin was
  never inspected, whatever the exit code says. Deliberately not
  `.contents | length > 0` — `contents` lists files *with findings*, so that would
  assert a warning exists and would break the day the one warning is resolved.
  The plugin target runs non-strict: its only warning is the repo-root `CLAUDE.md`
  (contributor/agent guidance, which Claude Code strips from the install payload),
  and warnings are printed rather than fatal.
- **test(manifest)**: new `tests/manifest/plugin-manifest.test.sh` — nothing
  covered `hooks/hooks.json` or `.claude-plugin/*.json`, and the CI step that
  looks like it does, does not: `claude plugin validate .` resolves to the
  *marketplace* manifest (both manifests live in `.claude-plugin/`), reports
  `"contents": []` and exits 0 without reading `plugin.json`, the skill, or the
  hooks. Asserts manifest validity, kebab-case name, the three-field version sync,
  that every hook command resolves through `${CLAUDE_PLUGIN_ROOT}` and points at a
  script that ships, that each hook declares a timeout, and that no absolute or
  `../` path appears in the hook wiring.
- **test(command)**: `tests/commands/loop-testing.test.sh` retargeted from the
  deleted `commands/loop-testing.md` to `SKILL.md`, and gained
  `component_names_unique` — the regression guard for the collision itself, which
  fails when any two of `skills/*/` and `commands/*.md` share a name. Parity with
  the Codex prompt is now asserted per semantic element in each file's own
  language, since `SKILL.md` is Chinese and `prompts/loop-testing.md` is English.
- **test(sandbox)**: new `clean-marker-integrity.test.sh` (corrupted, truncated
  and empty markers; v1-marker backward compatibility; the documented `exit 4`
  `purge incomplete` path) and `script-help.test.sh` (`--help` output, inertness,
  and that an unknown flag is still a usage error).
- **test(driver)**: new `agent-binary-preflight.test.sh` — missing binary path and
  missing PATH name for both drivers, zero sessions started, and a control proving
  the preflight does not reject a binary that is present.
- **test(hooks)**: `update-check.test.sh` gains three cases for the throttle
  location — `CLAUDE_PLUGIN_DATA` set (file lands there, XDG untouched), unset
  (XDG fallback unchanged), and the explicit `LOOP_TESTING_UPDATE_CACHE` override
  outranking both.
- **docs(readme)**: the `--purge` contract now states that an unreadable marker
  refuses like a missing one and documents `exit 4`; the mechanism-layer bullet
  names `LOOP_TESTING_DISABLE_LEDGER_GATE=1`, which was implemented and reachable
  but documented only inside `hooks.json`; the cleanup table reflects the new
  throttle location. Both READMEs.

## 0.10.0 — 2026-09-19

Minor: the sandbox stops claiming things by name. `sandbox-clean.sh` used to
force-remove whatever worktree stood at the path its marker recorded, and
`--purge` used to delete `docs/looptesting/` on a marker field that every
released version wrote as a constant `true`. Both destroyed work that was never
the sandbox's, untracked files included — and the second did it on the workflow
this tool documents, since clean keeps `qa/loop-testing` precisely because the
fix commits live nowhere else, so harvesting them means putting a worktree on
that branch at the path the marker still names. Found by a converge maintenance
round and then hammered by five rounds of independent pre-ship review, which
rejected four earlier attempts at this change before this one; each round is the
`author ≠ reviewer` step that caught eighteen defects inside the ten fixes
behind `0.9.0`. Full suite `ALL GREEN` (337 shell assertions across 22 suites →
486 across 24; moa unchanged at 41 node tests). Every new assertion is
mutation-checked — reverting the property it names turns it red — and two that
could not be made red were deleted or rebuilt rather than left standing as
coverage they did not provide.

**What changes for you.** Five things, and one of them needs a hand.

1. **A sandbox created by 0.9.1 or earlier carries no ownership stamp**, so
   `clean` can no longer tell its worktree from one of yours. It keeps that
   worktree and prints the exact `git worktree remove --force <path>` line to
   remove it — check the worktree first, `--force` discards anything
   uncommitted or untracked in it. After one rebuild the sandbox carries a
   stamp and never needs this again. Resuming is unaffected: `setup` still
   answers `already initialized` for these sandboxes, because adopting a
   worktree to continue a run is reversible and force-removing one is not.
2. **`--purge` now keeps `docs/looptesting/` in four cases** — the directory was
   already yours, the marker predates the field being measured, the field says
   the question was never answered, or a worktree it could not claim is still
   registered. An upgraded sandbox always lands in one of them, so purge will
   leave the evidence dir for you to remove.
3. **The ownership marker is `SANDBOX_VERSION=2`**, adding `WORKTREE_STAMP`,
   `UNCLAIMED_WORKTREE`, and a `CREATED_LOOPTESTING_DIR` that is now
   `true | false | unknown` instead of a constant. Anything parsing the marker
   sees new keys and a new value domain.
4. **`--purge` exits `4`** when it ran but stopped short — it may already have
   deleted the baseline tag, so this is not a no-op. `0` still means it finished.
5. **A relative `--worktree-path` resolves against your current directory.** It
   used to resolve against both the current directory and the repo root, in
   different checks within the same run; from a subdirectory the destination now
   differs from the old repo-root anchoring.

If you script against the old behavior, pin `0.9.1` in your marketplace install
until you have adjusted.

- **fix(sandbox)**: worktree ownership is a nonce stamped inside the worktree's
  own git admin dir, which git deletes together with the worktree, so it cannot
  outlive the thing it identifies and a worktree recreated at the same path does
  not inherit it. The lookup returns `absent / stale / legacy / ours / foreign /
  unknown`, and "cannot tell" never authorizes a deletion. It runs on bash
  builtins and git alone — an earlier attempt let a missing `awk`, and then a
  missing `cat`, be read as an ownership verdict.
- **fix(sandbox)**: `--purge` trusts `CREATED_LOOPTESTING_DIR` only from
  `SANDBOX_VERSION=2` on, and `sandbox-setup.sh` no longer re-emits a v1
  constant under a v2 marker, which would have laundered an unmeasured value
  into a fact on the ordinary upgrade path. Whether the sandbox created the
  directory is recorded in a breadcrumb written the moment it is known, and only
  when this run can honestly answer.
- **fix(sandbox)**: a dangling registration — the directory deleted by hand — is
  cleared with a scoped `git worktree remove`, re-tested immediately before the
  call. It is never `git worktree prune`, which takes no path and would drop
  every prunable registration in the repo, including worktrees of yours that a
  `git worktree repair` could otherwise have restored.
- **fix(sandbox)**: `--worktree-path` is canonicalized once, to an absolute
  physical path with `.` and `..` folded and no glob expansion. Recorded
  verbatim, a relative path made every later ownership lookup miss, so clean
  leaked its own worktree while reporting success; unquoted, a segment like
  `READ*` was matched against the current directory and silently retargeted the
  sandbox.
- **fix(sandbox)**: a rebuild no longer deletes the ownership marker before it
  knows the rebuild worked, and records a worktree it walked away from as
  `UNCLAIMED_WORKTREE` so purge can still name it. A `worktree add` failure
  carries git's own reason, and a malformed `SANDBOX_VERSION` no longer reaches
  the shell's integer parser.
- **fix(sandbox)**: `sandbox-setup.sh` re-verifies isolation in worktree mode
  before answering "already initialized" — it previously proved only that the
  path was registered, so it could adopt a user's checkout and commit fixes onto
  their branch.
- **docs(sandbox)**: both READMEs enumerate the four cases where purge keeps the
  evidence dir, carry the kept-worktree row in the artifacts table, and state
  that the removal command they name discards uncommitted work.
  `templates/FINAL_REPORT.md` no longer promises clean removes the worktree.

## 0.9.1 — 2026-09-19

Patch: one safety fix. It was found by a converge maintenance round against this
repo, and then hardened by an independent pre-ship review of that round's own
output — the same author-≠-reviewer step that caught eighteen defects inside the
ten fixes behind `0.9.0`. The review rejected the round's two other fixes: both
introduced regressions in the worktree / evidence-dir ownership logic, so only
this one ships and the rest go back for rework. Two mutants confirm the new
test's assertions are load-bearing rather than decorative. Full suite
`ALL GREEN` (337 shell assertions across 22 suites, up from 324 across 21; the
new `tests/sandbox/clean-pid-guard.test.sh` accounts for all 13; moa unchanged
at 41 node tests).

**What changes for you.** Nothing you can depend on: no flag, exit code, file
format or default moves. The only new output is a single
`sandbox-clean: refusing to signal PID … from .pids` line, on a code path that
previously terminated your shell instead.

- **fix(sandbox)**: `sandbox-clean.sh` filtered the PIDs recorded in
  `docs/looptesting/.pids` by *shape* (all-numeric) rather than by *value*, so a
  `0` line reached `kill "$pid"` — and `kill 0` signals every process in the
  sender's own process group: the agent session, the unattended driver, and any
  sibling jobs, mid-cleanup, before the worktree is ever removed. That file is
  written by the agent from parsed `lsof -t -i :PORT` / `ss -ltnp` output, which
  is exactly where a stray `0` comes from, so this was reachable input rather
  than a hypothetical. `00` slipped through the same way; PID `1` was masked
  only by `kill -0` failing for non-root. The guard now compares the value and
  strips leading zeros first, so `0000123` is still stopped as the real PID 123
  it is.

## 0.9.0 — 2026-09-19

Minor: an eight-round dogfooding `/loop-testing` run against this repo itself,
then a two-round pre-landing review of the resulting patch. The loop found ten
defects in the shipped scripts (four P1). The review then found eighteen more
*in those ten fixes* — two ship-blocking, one of them a secret-redaction bypass
that never shipped — all folded in here. Everything below is a `fix:` — no new
capability — but two user-visible behaviors move, so this is a minor, not a
patch. Full suite `ALL GREEN` (setup 44 → 58 asserts, purge 40 → 62,
codex-limits 33 → 43, driver-limits 31 → 33, driver-terminal 8 → 11,
moa 34 → 41 node tests, plus a new `tests/portability/` suite).

**What changes for you.** `sandbox-setup.sh` now REFUSES with the new exit code
`8` when it cannot write `docs/looptesting/` — it previously printed `ready` and
exited `0` while leaving an unclaimable worktree/branch/tag behind and a silently
disarmed stop-gate. And both unattended drivers now actually stop when you signal
their process group; they previously released their concurrency lock and kept
launching sessions. No action is required. If you script against the old exit
codes, pin `0.8.1` in your marketplace install until you have adjusted.

- **fix(sandbox / ISSUE-001)**: `sandbox-clean.sh --purge` could never remove the
  qa branch and baseline tag after a `clean` → re-`setup` cycle, and printed a
  bare `purge done.` that read as "everything cleaned" while fix commits sat on a
  branch it never mentioned. The rebuild now records the refs as `ADOPTED_*` and
  purge reports them by name with their commit count. It deliberately does NOT
  re-claim ownership: the marker records ownership by NAME, so a user who had
  replaced `qa/loop-testing` with their own branch of that name would have had it
  deleted — silently, when it held no commits beyond the recorded baseline.
- **fix(sandbox / ISSUE-008)**: `sandbox-setup.sh` ignored every failure while
  creating `docs/looptesting/`. A read-only `docs/`, a root-owned dir or a full
  filesystem produced a `ready` that had created no evidence dir, no `.active`
  sentinel (so the stop-gate was inert) and no ownership marker (so cleanup was
  fail-closed on artifacts it had just created). A preflight now creates and
  probes all four evidence dirs before touching git, writes a real byte so ENOSPC
  is caught here rather than at the marker write, and a refusal rmdir's exactly
  the directories it created.
- **fix(driver / ISSUE-009)**: `trap handler EXIT INT TERM` ran the handler and
  RETURNED into the loop, so `kill -TERM -- -<pgid>` — the shutdown both drivers
  document — only dropped the concurrency lock while sessions kept launching, and
  on the Codex side un-protected the skill dir mid-run. Signal handlers now clean
  up and exit 130/143.
- **fix(moa / ISSUE-004)**: aggregator JSON with array or object values for
  `rationale` / `risks` was silently dropped from the decision record, leaving a
  pointer to a section that did not contain it — while the prompt asks for
  "≤3 条要点", which models answer with arrays. Values now render as Markdown,
  bounded by a depth cap (a deeply nested answer used to crash the renderer and
  discard the already-paid committee calls), a per-field length cap, and key
  escaping so a key cannot forge a section of the document.
- **fix(moa / ISSUE-006)**: a `moa.config.json` whose top level is not a JSON
  object took two bad paths — `null` surfaced an internal TypeError, while an
  array or string was ignored in silence and the run proceeded against the
  DEFAULT paid models. Both are now a clean `error:` and exit 1.
- **fix(codex-driver / ISSUE-005)**: the skill-directory guard cleared write with
  `chmod -R a-w` and restored with `u+w`, permanently stripping group and other
  write bits from a shared install on every run. It now clears only the owner bit
  and restores the exact read-only set it found. The header no longer calls this a
  guarantee: the session runs as the owner and can undo it in one command, and
  root ignores the bits entirely — it is a speed bump, not a control.
- **fix(sandbox / ISSUE-007)**: `--purge` told users who had already merged the qa
  branch to "harvest them first". It now checks reachability and says so, while
  excluding the branch's own remote-tracking mirror — a backup `git push` of the
  qa branch is not a harvest, and reporting it as one pointed at the flag that
  deletes the commits. The wording states the observation, not a verdict.
- **fix(sandbox / ISSUE-002, driver / ISSUE-003, ISSUE-010)**: `die()` printed its
  exit-code argument as part of the message (`…choose another) 6`); the drivers
  named the internal variable instead of the flag (`--max_sessions`); and an
  annotated `round: 3 of 12` parsed as `312` in `driver.log` and the summary line.
- **fix(driver / portability)**: the flag-name fix above briefly used `${v,,}`,
  a bash 4.0 expansion, on a line that runs on every invocation — a fatal bad
  substitution on stock macOS bash 3.2, which CI cannot see because the matrix is
  ubuntu-only. New `tests/portability/bash3.test.sh` gates shipped scripts against
  case-modification expansions, `mapfile`/`readarray` and `declare -A`, and carries
  a self-probe so a broken pattern cannot turn the gate into a green no-op.

## 0.8.1 — 2026-07-13

Batch 7: three documentation clarifications in the skill references, surfaced by
a real-loop A/B smoke test of the v0.8.0 prompts (two fresh agents, one on new
prompts and one on v0.7.0, run against a planted-bug CLI). Each clarifies an
*existing* mechanism that both agents inferred or tripped over — no behavior
change. Full suite `ALL GREEN`.

- **docs(skill / R73)**: `loop-round.md` §4 now states the evidence-tree vs
  commit-tree split explicitly — `docs/looptesting/` lives in the MAIN worktree
  (so it survives worktree cleanup) while code edits and `fix(qa)` commits happen
  in the sandbox worktree on the qa branch. Both smoke agents inferred this from
  setup output rather than reading it.
- **docs(skill / R74)**: `issue-rules.md` §7 now documents the `ledger-gate.sh`
  ordering it already enforces — the replay must be written to `runs/round-N.md`
  BEFORE the ISSUES.md status is flipped to VERIFIED; the reverse order is
  blocked (fail-closed). Both smoke agents ate one deny and reordered.
- **docs(skill / R75)**: `moa-decision.md` §5 tightens the previously narrow
  "real-key smoke test" wording — ANY real committee call when a key is present
  (not just an explicit smoke test) is a paid/external action gated by FR-6.7;
  a key present in the environment is NOT user authorization for the paid call.
  Adds a `--dry-run` check step. `issue-rules.md` §9 clarifies a DEC link may be
  left `待生成` for trivial suggestions rather than forcing a paid call each time.

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
