---
name: loop-testing
description: Start or resume the autonomous QA self-test loop on this project — a deterministic entry point that needs no trigger phrase. Optional argument - `status` (report progress from STATE.md) or `report` (print FINAL_REPORT.md); default starts or resumes the loop.
---

The user explicitly invoked the loop-testing QA loop. Argument: `$ARGUMENTS`
(empty → start / resume the loop; `status` → report progress only; `report` →
print the final report only).

Dispatch on the argument:

- **empty — start / resume.** Invoke the `loop-testing` skill and run the autonomous
  QA self-test / self-fix / self-iterate loop on the current project. If
  `docs/looptesting/STATE.md` already exists, **resume** from its next action — do NOT
  reset the round count or clear the ledger; otherwise start from round 0. Follow the
  skill exactly (round-0 inventory → the five-step round loop → convergence exit). The
  skill's own red lines and mechanism-layer hooks still apply.

- **`status` — progress only, do NOT start a run.** Read `docs/looptesting/STATE.md`
  and summarize: current `round`, `converged_streak`, `status`, last / next action, and
  any blockers. Then read `docs/looptesting/ISSUES.md` and give open / verified issue
  counts by severity (P0–P3). If `docs/looptesting/` does not exist, say the loop has not
  run in this project yet and that `/loop-testing` starts it.

- **`report` — final report only, do NOT start a run.** If
  `docs/looptesting/FINAL_REPORT.md` exists, print and summarize it (final status,
  coverage summary, fix list issue ↔ commit, open / to-confirm items, blind spots). If it
  does not exist but a run is in progress, say so and show the `/loop-testing status`
  summary instead.

- **any other argument — optional scope hint(s) for a start / resume run.** Refines a
  run; it never changes the default full-loop behavior when omitted. Two kinds, combinable:
  - **focus** (free text, e.g. `只测 X` / `focus on the CLI`): still do the round-0
    inventory, but prioritize scenario design and the round loop on the named area, and
    record the narrowed scope in `PLAN.md` so coverage stays honest — do NOT report
    un-scoped areas as covered.
  - **round cap** (e.g. `最多 3 轮` / `at most 3 rounds`): on a START (no `STATE.md` yet)
    write `max_rounds: N` into `STATE.md` instead of the default 12; on a RESUME keep the
    recorded value unless the user restates it, and never set it below the current
    `round:`. This only lowers the runaway cap — convergence still stops earlier
    (`converged_streak` reaches 2 → `CONVERGED`); reaching the cap unconverged writes
    `status: INCOMPLETE` (existing exit semantics, see `references/exit-and-report.md`).
