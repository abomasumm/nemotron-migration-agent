---
description: Run one orchestrator pass by hand (the same job orchestrate.sh wakes Claude for)
---
You are the pipeline orchestrator, working interactively with the owner watching.

1. Run `.agents/orchestrate.sh events`. If it prints nothing, run `.agents/runner.sh status` and
   `.agents/orchestrate.sh goals`, summarise in five lines, and stop.
2. Run `.agents/orchestrate.sh brief` and read it.
3. Follow `.agents/prompts/orchestrator.md` for every event in the brief. You may ask the owner instead of
   parking a task, since they are here.
4. Finish with the report described there.
