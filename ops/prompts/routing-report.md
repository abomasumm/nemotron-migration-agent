Weekly routing report (scheduled, Mondays, read-only).

1. For each repo: `./kitctl <repo> stats 7`, `./kitctl <repo> log fallbacks 200` and
   `./kitctl <repo> log orchestrator 200`.
2. Write `digests/routing-YYYY-MM-DD.md` with:
   - **Per model**: calls, error rate, median seconds, gate pass rate, best-of-2 wins, per repo and in total.
   - **Overflow**: which roles fell back to the other plan or paused, how often, and at what times of day.
   - **Claude use**: orchestrator wakes per day and why (plan / triage / signoff / wrapup); Opus retries
     and whether they rescued the task.
   - **Suggestions**, at most three, each with the evidence behind it and the exact `local.sh` line to try,
     e.g. `M_DS="$GO/mimo-v2.6-pro"` if MiMo Pro beats DeepSeek on gate pass rate over 20+ tasks.
     Suggest nothing on fewer than 20 tasks of evidence; say "not enough data yet" instead.
3. Read-only: change nothing. The owner decides and edits `local.sh` themselves.
