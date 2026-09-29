---
description: Plan a milestone by hand (the orchestrator normally does this after `orchestrate.sh goal`)
argument-hint: <milestone goal>
---
You are the orchestrator. Plan this milestone and write task files. Do not write code.
(The usual route is `.agents/orchestrate.sh goal "<goal>"`, which packs context and wakes you to plan.
Use /plan when you want to plan with the owner in the loop.)

Goal: $ARGUMENTS

1. Read `.agents/context.md` (the chief of staff's summary for this goal), `REPO_MAP.md` and `NOTES.md`.
   If context.md is missing or its goal line doesn't match, stop and tell me to run:
   `.agents/cos.sh pack "<goal>"`. Open other files only when the summary leaves a real gap.
2. Split the goal into tasks. One task = one reviewable change, ideally under 300 changed lines,
   touching only the files it lists. Prefer more small tasks over fewer big ones.
3. Write each task to `.agents/tasks/T-NNN.md`, continuing the numbering of existing files,
   using exactly the format in `.agents/tasks/TEMPLATE.md`. Leave `goal:` empty unless the owner names
   a goal id from `.agents/orchestrate.sh goals`. Rules:
   - `type`: patch (small precise change), feature (new behaviour, few files), debug (a bug with a repro),
     ui (visual/components), data (SQL, dbt, pipelines), bulk (mechanical edits across many files),
     long (unattended multi-step work).
   - `risk: high` for auth, payments, data loss, schema or migrations, shared/core modules, public APIs.
     High-risk tasks get two competing workers, a senior review and my sign-off.
   - `logic: yes` when behaviour can be tested; a separate agent writes failing tests first.
   - `files:` comma-separated paths or globs the worker may change. Be precise; the scope guard enforces it.
   - `after:` task ids that must merge first, if any.
   - Acceptance criteria must be testable. Name functions and symbols in `backticks`.
4. Finish with a table (id, type, risk, title) and any decisions you need from me.
   Do not run the runner; the loop picks the tasks up. If a goal id was given, finish with
   `.agents/orchestrate.sh planned <goal id>`.
