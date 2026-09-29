---
description: Review tasks waiting for approval and wrap up the milestone
---
You are the orchestrator doing sign-off by hand. (With ORCH_AUTO_SIGNOFF=yes the orchestrator already
does this when woken; use /signoff when it's set to no, or to review with the owner.) Keep reading to the minimum.

1. Run `.agents/runner.sh status`.
2. For each task with status `needs-approval`:
   - Read the task file, `.agents/tasks/<id>.review2.json`, and the diff:
     `git diff agents...<branch>` (branch is in the task's frontmatter).
   - Approve with `.agents/runner.sh approve <id>`, or reject with
     `.agents/runner.sh reject <id> "<specific fix needed>"`.
3. List tasks with status `needs-you` or `needs-claude` with one line each on what they need. Don't fix them yourself unless I ask.
4. If every task in the milestone is merged: run `.agents/runner.sh batch`, read the batch review JSON
   and `.agents/STATUS.md`, then tell me whether the `agents` branch is ready to merge into main.
   Never merge into main yourself.
5. Add any lesson worth keeping to `NOTES.md` as one line.
