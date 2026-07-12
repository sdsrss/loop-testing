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

- **any other argument** — treat it as extra guidance for a start / resume run (for
  example, a specific area or entry point to focus on).
