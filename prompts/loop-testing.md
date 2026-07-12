# loop-testing

Start or resume the loop-testing autonomous QA loop on the current project. Argument
(optional): `$ARGUMENTS` — empty starts / resumes the loop; `status` reports progress
only; `report` prints the final report only.

- **empty — start / resume.** Use the `loop-testing` skill and run the autonomous QA
  self-test / self-fix / self-iterate loop on this project. If
  `docs/looptesting/STATE.md` exists, resume from its next action (do NOT reset the round
  count or clear the ledger); otherwise start from round 0. Follow the skill exactly and
  keep its red lines.

- **`status`** — do NOT start a run: read `docs/looptesting/STATE.md` and report the
  current round, converged_streak, status, next action, and blockers, plus open / verified
  issue counts from `docs/looptesting/ISSUES.md`.

- **`report`** — do NOT start a run: print and summarize
  `docs/looptesting/FINAL_REPORT.md` if it exists; otherwise show the status summary.
