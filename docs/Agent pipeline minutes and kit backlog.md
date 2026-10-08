# Agent pipeline: minutes and kit backlog

Oct 5, 2026 · @Hori

## Summary

Your setup is an event-driven, hierarchical orchestrator–worker pipeline: scripts run the control flow, Claude makes the decisions, and cheap models do the building and checking. It's cheap, careful and easy to debug, but slow per change. So it suits defined, testable backlogs, while design, urgent fixes and tiny changes stay interactive. No new architectures are needed: specialise inside the kit with profiles, task types, gates and a few lanes. omp stays the default harness and Pi is a spare. **No kit code has changed yet**; the backlog below lists what to build, in order.

These minutes cover the discussion from "what kind of agent architecture is mine?" onward. Earlier decisions are in `HANDOFF.md` v4.2.

## Architecture: what it is, benefits, downsides

The architecture is an **event-driven, hierarchical orchestrator–worker pipeline with a deterministic control plane**. It sits at the "workflow" end of the workflow-vs-agent spectrum: bash scripts own scheduling, gates, fallbacks, caps and retries, and models fill fixed steps.

| Trait | What it means in your kit |
| --- | --- |
| Orchestrator–workers, in layers | Claude decides what gets built and whether it's acceptable; cheap models build; you approve and merge; dsh is your desk on top. |
| Generate-and-verify | Tests first (must fail on old code), best-of-2 workers, a judge, cross-family reviewers. |
| Model cascade | The retry ladder escalates MiMo, then Sol, then Opus only when cheaper models fail. |
| Shared state in files | Task files, goal files, logs and git worktrees are the shared memory. |
| Human on the loop | Two touches per milestone (goal and merge); Claude wakes only for decisions. |

**Benefits**

- **Cost:** expensive intelligence goes to decisions, volume work runs on flat-fee pools; $40 a month in total.
- **Quality:** several independent checks, and no model approves its own family's work.
- **Resilience:** fallbacks, pauses and caps instead of crashes or runaway spending; every switch is logged.
- **Debuggable:** bash, plain files and git; rerun one script to reproduce a problem.
- **Low attention:** you set goals and merge.
- **Swappable models:** routing is one file; `stats.sh` shows which models earn their place.

**Downsides**

- **Slow per change:** sequential stages, 5-minute polling, one task at a time; 15–30 minutes per task, hours per milestone.
- **Brief quality is the bottleneck:** vague goals become retries and extra Claude wakes.
- **Only as good as the tests:** weak tests let wrong changes pass every gate.
- **No shared memory across workers** beyond the context pack, `NOTES.md` and `AGENTS.md`.
- **Overhead on small tasks:** best-of-2, a judge and two review rounds for a tiny change.
- **Many parts and unverified assumptions:** model IDs, `:xhigh`, 9router error wording, headless Claude flags; kit copies drift between repos (Mentora's old `loop.sh`).
- **Tied to one Mac** that must stay awake and plugged in.
- **Shared quotas:** Pro is shared with your chat; four repos share one Go window while kit caps see one repo at a time.

## Ways to speed up the workflow

The top three picks: better briefs from dsh, event-driven ticks, then parallel tasks with `after:` dependencies once the pipeline is proven. Retries are where the hours go, so anything that prevents retries saves the most time.

| # | Idea | Effect | When |
| --- | --- | --- | --- |
| 1 | Measure time per stage before tuning | Shows whether polling, gates, retries or workers dominate | After the first real milestone |
| 2 | Event-driven loop: start the next task and tick the orchestrator as soon as state changes (`fswatch` on `.agents/tasks`) | Saves roughly 5–15 minutes per milestone step | Now |
| 3 | Sharper goal briefs from the dsh template | Fewer retries and Claude wakes | Now |
| 4 | Fast lane: one-file fixes go to omp interactively or a `fast` task | No pipeline overhead on tiny work | Now |
| 5 | `MAX_PARALLEL` 2–3, with Claude planning `after:` dependencies | Independent tasks run side by side | After \~20 clean tasks |
| 6 | Adaptive best-of-2: second worker only on failure or medium/high risk; or race both and take the first that passes | Saves tokens, or cuts wall-clock | After \~20 clean tasks |
| 7 | Faster gates: affected tests during iterations, full suite before merge; warm dependency caches | Shorter gate runs | After \~20 clean tasks |
| 8 | Auto-refresh `REPO_MAP.md` after each wrap-up | More accurate context packs | After \~20 clean tasks |
| 9 | One-step merge: daily summary of `agents` plus one command or PR | Merging takes a minute | Later |
| 10 | Claude's wrap-up appends lessons to `NOTES.md`; tune prompts from `stats.sh` failure patterns | The pipeline learns | Later |
| 11 | Always-on machine (Mac mini or small server) | Removes the "Mac must stay awake" limit | Later |
| 12 | Build option 2 (`kitctl`), then option 3 | Less typing, then cross-repo quota control | Option 2 soon; option 3 at the second repo |

## Pipeline vs interactive, and specialised lanes

Use the pipeline when "done" can be written down in advance and a test can check it. Edit interactively when the hard part is deciding what to build or judging how it looks.

| Use the pipeline for | Edit directly for |
| --- | --- |
| Feature backlogs in a tested repo (the dashboards) | Unclear requirements: design, API exploration, spikes |
| Several related changes you can describe up front | Work you judge by eye: portfolio visuals, layout, copy |
| Data transforms with clear contracts (data gate) | Urgent production bugs (queue a regression-test task after) |
| Mechanical volume: renames, migrations, tests for legacy code, docs | Tiny changes: one-line fixes, config tweaks |
| Work that can wait hours | Repos with no tests; the first week of a greenfield project |

**Interactive tool choice:** Claude Code (Opus) for architecture, hard bugs and design decisions, in short sessions. omp + ompweb for everyday fixes, refactors and spikes. Pi + pi-web when omp is broken. DeepSeek Harness for briefs, prompts, second opinions and data-file profiling. When the question changes from "what should this be?" to "build these pieces", dsh turns it into a brief and queues it.

**No new architectures.** The kit already specialises through profiles, task types and per-repo gates. Add lanes inside it when a project needs them:

| Lane | For | What's different | When |
| --- | --- | --- | --- |
| Data gate | Data project | `gates/data.sh`: transforms on synthetic fixtures, schema/row/null checks; `risky` for migrations | When that project starts |
| UI gate | Dashboards, portfolio chores | Turn on `ui.sh` (Playwright screenshots) for Gemini visual QA | When UI tasks fail review |
| Codemod lane | Large mechanical refactors | Opus writes a rewrite script; the pipeline checks the result | First big refactor |
| Design loop | Portfolio look | Interactive (Opus or Claude Design), then `fast` chores | Portfolio |
| Research lane | Spikes, library choices | Chat, notebooks or dsh, ending in a written decision | As needed |

Order agreed: prove the pipeline on one dashboard, measure with `stats.sh`, then add the lane the next project needs.

## omp vs Pi

omp is the default for everything; Pi is a spare kept for when omp fails. They overlap by design: omp is a fork of Pi with more tools.

|  | omp | Pi |
| --- | --- | --- |
| Tools | Code navigation, debugger, token-saving edits, subagents, Python/JS kernels | Read, edit, write, bash, plus extensions |
| Release pace | Very fast; can break between updates | Slow and steady |
| Web UI | ompweb | pi-web |
| In the kit | Default harness | `HARNESS=pi` fallback |
| Paperclip | No adapter | `pi_local` adapter |

- **In the pipeline the gap is small.** The kit runs omp with extensions off and basic tools only, so workers mainly gain the token-saving edits.
- **Use Pi when:** omp breaks after an update; you want to check whether a problem is omp's fault (sanity check); or you move to Paperclip.
- **Interactively, Pi is a preference, not a rule.** Its smaller setup suits a plain, predictable session for precise edits; omp handles those edits just as well, with cheaper output. Same models either way.
- **Agreed approach:** set Pi up once (about 10 minutes), pin the omp version and update on purpose, and never use both day to day. Pinning omp alone is an acceptable alternative to keeping Pi.

## Decisions and guidance agreed

1. Keep one architecture; specialise with profiles, task types, gates and lanes, not separate pipelines.
2. The pipeline is for defined, testable backlogs; design, urgent bugs, tiny changes and untested repos stay interactive.
3. Prove the pipeline on one dashboard and measure it before tuning or adding lanes.
4. omp is the default harness. Pi is a configured spare and a sanity check, never a daily second tool.
5. Pin the omp version and run `doctor.sh --models` after any deliberate update.
6. Raise parallelism and make best-of-2 adaptive only after about 20 clean tasks.

## Kit upgrade backlog: do now

These items come from the whole conversation, in the order to do them. Only the doc pages have been produced so far; everything below is still open.

**Fix the Mentora install and finish setup**

- [ ] Run `diff -rq ~/Documents/GitHub/agent-pipeline-kit/.agents .agents` in Mentora; copy over stale kit files, starting with `loop.sh` (it lacks `orchestrate.sh tick`).
- [ ] Confirm the kit folder is current: `git pull`, then `git log --oneline -1` shows `17801bf`.
- [ ] Run `doctor.sh --models` and `doctor.sh --claude`; fix `VERIFY` model IDs in the kit repo first, then commit.
- [ ] Run `cos.sh map` and commit `REPO_MAP.md`.
- [ ] Check whether iCloud syncs Documents; if so, turn it off or move project repos to `~/code`.
- [ ] Run a trivial task (`runner.sh task T-001`), then a trivial goal through the orchestrator.

**Machine and harness**

- [ ] Set up Pi as the fallback: install, add `pi-9router.example.json`, run `HARNESS=pi .agents/doctor.sh --models`.
- [ ] Pin the omp version; update only on purpose.
- [ ] Keep only the `kitloop` function (not the alias) and `kitsetup` in `~/.zshrc`.

**Kit repo housekeeping**

- [ ] Add `.gitignore` with `.DS_Store` to the kit repo.
- [ ] Change the tmux line `setup.sh` prints to `caffeinate -is .agents/loop.sh`.
- [ ] Commit `docs/architecture.html` and `docs/architecture-multirepo.html`.
- [ ] Update `HANDOFF.md`: kit path `~/Documents/GitHub/agent-pipeline-kit`, the `kitsetup` and `kitloop` helpers.

**Small speed-ups**

- [ ] Event-driven loop: start the next task and run the orchestrator tick as soon as a task changes state (`fswatch` on `.agents/tasks`).
- [ ] Per-stage timing in `stats.sh`, so the first milestone shows where time goes.

**Option 2: dsh as control desk** (new `ops/` folder; no existing kit script changes)

- [ ] `kitctl` allow-list wrapper with logging to `kitctl.log`.
- [ ] `repos.txt`, `DSH.md` operating instructions, `templates/goal-brief.md`.
- [ ] Prompts: `morning-summary.md`, `routing-report.md`; schedule both in dsh.
- [ ] Add 9router as a dsh custom provider (DeepSeek on GOAT).
- [ ] Sandbox test: dsh can queue a goal through `kitctl` but can't edit a source file.

## Future changes

Each change waits for a trigger, so nothing here should be built early.

| Trigger | Change | Notes |
| --- | --- | --- |
| \~20 clean tasks | `MAX_PARALLEL` 2–3, with Claude planning `after:` dependencies | Watch the Go 5-hour window |
| \~20 clean tasks | Adaptive best-of-2: second worker only on failure or medium/high risk, or race both | Small edits to `runner.sh` and `routing.sh` |
| \~20 clean tasks | Faster gates: affected tests during iterations, full suite before merge | In each repo's `check.sh` |
| \~20 clean tasks | Rerun `cos.sh map` after each wrap-up | Keeps context packs accurate |
| Before the second repo | `.agents/local.sh` for per-repo settings, `setup.sh --update`, `KIT_VERSION`, a `doctor.sh` "kit behind" warning | Stops kit copies drifting; required for option 3 |
| Second repo running cleanly | Option 3: dsh as portfolio orchestrator (`backlog.md`, scheduled-check prompt, per-repo cap split) | Starting split: 4 wakes, 1 Opus retry per repo; GOAT 30/20/15/15 |
| Data project starts | `gates/data.sh` data gate | Synthetic fixtures; schema, row and null checks |
| UI tasks failing review | Turn on `ui.sh` and `ui.spec.ts` | Screenshots for Gemini visual QA |
| First large refactor | Codemod lane | Opus writes the rewrite script |
| After two weeks of `stats.sh` | Tune routing: MiMo V2.6 Pro as worker A if DeepSeek underperforms; Kimi K3 as retry 2 if Sol rarely rescues | Let your own data override leaderboards |
| Merging becomes a chore | One-step merge: daily `agents` summary plus one command or PR |  |
| Retries repeat the same mistakes | Wrap-up appends lessons to `NOTES.md`; tune prompts from failure patterns |  |
| Pro quota runs short | Sonnet 5.5 for sign-off and first triage; per-event model choice in `orchestrate.sh` | Not built; user chose no change in v4.1 |
| Go pool runs tight | Trial 9router Headroom for a week against the RTK-only baseline; turn `OFFPEAK_ONLY` back on if long/bulk tasks crowd the day | One saver at a time |
| The Mac sleeping becomes a problem | Always-on machine (Mac mini or small server) |  |
| dsh reaches a stable release | dsh plugins (for example, "draft goal brief", "show stuck tasks") | Avoid while it's a release candidate |
| 3+ parallel tasks per repo, regularly | Paperclip | dsh option 3 already covers "one board across repos" |

## Open questions

- Is Mentora (or either dashboard) owned by an employer or client? If so, set `ALLOW_TRAINING=no` for it.
- Stack and test commands for each repo, to fill `check.sh` and `AGENTS.md`.
- Data project: storage, orchestrator, dbt or not, and sources.
- Commit the portfolio's kit publicly, or keep it local via `.git/info/exclude`?
- Times for dsh's scheduled reports (08:45 is a placeholder).
- Repo priority and GOAT split for option 3 (30/20/15/15 is a placeholder).
- Keep Pi as a spare, or rely on pinning omp alone?
