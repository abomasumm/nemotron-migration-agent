# Agent pipeline kit: Claude-orchestrated, Architecture B through 9router, on Oh My Pi (no Paperclip)

Claude is the orchestrator. Opus 5.5 (Claude Code, Pro login) plans milestones, triages tasks the pipeline
couldn't finish, signs off risky work and closes milestones. It is woken by `orchestrate.sh` only when one of
those decisions is waiting, so it spends Pro quota on decisions, not on polling. Cheap models on OpenCode Go
and Command Code GOAT do the building and checking through Oh My Pi (omp) -> 9router. Plain Pi still works:
set HARNESS=pi. Scripts do everything deterministic. Claude never goes through 9router.

## One-time setup (per machine)
1. Install: git, jq, curl, Node, Claude Code, Oh My Pi (`curl -fsSL https://omp.sh/install | sh`,
   `brew install can1357/tap/omp`, or `bun install -g @oh-my-pi/pi-coding-agent`), 9router (`npm i -g 9router`).
   macOS also: `brew install bash coreutils`. Recommended: gitleaks, semgrep, ripgrep.
2. Claude Code: run `claude`, then `/login` with your Pro account. Make sure ANTHROPIC_API_KEY is not set.
3. 9router: change the default password, bind to 127.0.0.1, require an API key, turn Cloud Sync off.
   OpenCode Go uses the model prefix `ocg/` and Command Code GOAT uses `cmc/`.
   Turn RTK on. Leave Caveman, Ponytail, Headroom and PXPipe off.
   No fallback combos for these models: the kit handles fallbacks itself.
   `export NINEROUTER_API_KEY=...` in your shell profile.
4. omp: merge `.agents/omp-models.example.yml` into `~/.omp/agent/models.yml` (the 9router provider, with the
   DeepSeek compat settings omp needs) and `.agents/omp-config.example.yml` into `~/.omp/agent/config.yml`
   (points omp's own background model roles at 9router). Check: `omp models 9router`.
   Using plain Pi instead? Set `HARNESS=pi` in routing.sh and use `.agents/pi-9router.example.json`.

## Per repo
```
bash setup.sh /path/to/repo
```
Edit `.agents/routing.sh` (ROUTER/GO/GOAT names, MAIN_BRANCH, ALLOW_TRAINING),
`.agents/gates/check.sh` (test/lint/build commands) and `AGENTS.md`. Then:
```
.agents/doctor.sh              # tools, harness, repo, 9router
.agents/doctor.sh --models     # every model replies "ready"
.agents/doctor.sh --claude     # claude -p works on your Pro login
git add .agents .claude CLAUDE.md AGENTS.md NOTES.md .gitignore && git commit -m "agent pipeline"
.agents/cos.sh map             # writes REPO_MAP.md; skim it
```

## Running a milestone
```
tmux new -s agents 'caffeinate -is .agents/loop.sh'   # once: scheduler + orchestrator tick every LOOP_SLEEP (caffeinate keeps the Mac awake)
.agents/orchestrate.sh goal "what to build"   # you: queue the goal
    # tick: Muse packs context -> Claude wakes, writes .agents/tasks/T-NNN.md (goal: G-001), marks it planned
    # runner: builds, tests, gates, reviews, merges into `agents`
    # tick: Claude wakes for stuck tasks (re-brief, split, escalate or park) and risky sign-offs
    # tick: all tasks merged -> batch review -> Claude wraps up and marks the goal done
.agents/orchestrate.sh goals                  # progress by goal;  .agents/runner.sh status  by task
git checkout main && git merge agents         # you: the only step Claude never does
```
Anything Claude hands back to you is `needs-you` in `runner.sh status`, with the question in the task's log
and in `.agents/logs/orchestrator.log`.

Driving it by hand instead: `claude` then `/orchestrate` runs one orchestrator pass with you watching;
`/plan` and `/signoff` still work on their own.

Fallback mode (`ORCHESTRATOR=cos`, the v3 behaviour) is for when Pro quota is short or the `claude` CLI is
broken: Muse triages stuck tasks once a day, and you run `/plan` and `/signoff` yourself. Switch by
restarting the loop: `tmux new -s agents 'ORCHESTRATOR=cos caffeinate -is .agents/loop.sh'` (or edit
routing.sh to make it permanent). In this mode `orchestrate.sh goal` refuses, because nothing would plan the
goal, and the loop warns about goals left open from claude mode. Merge conflicts are still re-queued every pass.
A middle ground is `ORCHESTRATOR=claude` with `ORCH_AUTO_SIGNOFF=no`: Claude plans and triages, you sign off.

## One repo or several
It's one system. Every repo runs this kit unchanged, with its own loop, task queue and Claude orchestrator.
Going from one repo to several adds a layer above the repos. Nothing inside a repo changes:

| | One repo | Several repos |
|---|---|---|
| Kit in each repo | as above | as above, installed in each |
| `~/code/ops/repos.txt` | one line | one line per repo |
| Who queues goals | you (or DeepSeek Harness through `kitctl`, on your say) | DeepSeek Harness's scheduled check, from `~/code/ops/backlog.md` |
| Per-repo caps | routing.sh defaults | lowered per repo in `.agents/local.sh` so all repos fit one Pro plan, one Go pool and one GOAT pool |

Start with one repo. Add the portfolio layer once a second repo has run a few goals cleanly. `kitctl`, the
backlog, the scheduled check and `local.sh` are designed but not built yet.

`docs/architecture.html` describes the whole system. A switch at the top changes the view between
**One repo** and **Several repos**. Open it with `#multi` at the end of the URL to start on the
several-repos view.

## How the orchestrator spends Pro quota
| Setting (routing.sh) | Default | What it does |
|---|---|---|
| `ORCH_MODEL` / `ORCH_LIGHT_MODEL` | opus / sonnet | Opus for planning, triage and sign-off; Sonnet when a wake only has wrap-ups. |
| `CLAUDE_ORCH_DAILY_CAP` | 10 (risky: 16) | Wakes per day, separate from `CLAUDE_DAILY_CAP` (Opus retries). Events wait for tomorrow after that. |
| `ORCH_MIN_GAP_MIN` | 30 (fast: 10) | Minimum time between wakes; events arriving meanwhile go into one wake. Planning skips it. |
| `ORCH_MAX_TRIAGE` | 2 | A task that stays stuck after this many triages goes to `needs-you` without another wake. |
| `ORCH_AUTO_SIGNOFF` | yes | no = risky tasks wait for you to run `/signoff`. |
| `ORCH_BACKOFF_MIN` | 60 | After a Pro usage-limit error, no wakes for this long (not counted against the cap). |
| `ORCH_ALLOWED_TOOLS` | see file | Headless permissions: read anything, edit task files and NOTES.md, run only kit commands and read-only git. |

A wake is skipped when the waiting events are identical to the last successful wake (Claude already saw them);
an unresolved event gets one more look the next day. Every wake is a row in `runs.csv` (role `orchestrator`,
model `ORCH_OPUS` or `ORCH_SONNET`), its prompt is `.agents/orch/wake.prompt`, and its reply goes to
`.agents/orch/wake-*.out` and `.agents/logs/orchestrator.log`.

## Profiles
Set the repo's usual profile with `PROFILE=` near the top of `.agents/routing.sh`. Override it for one run with
`PROFILE=fast .agents/runner.sh run`, or for one task with `profile: risky` in the task's frontmatter.

| Profile | Use it for | What changes |
|---|---|---|
| `default` | Most work | Best-of-2 on feature/debug/data/ui, Sol senior review on risky and long tasks, one task at a time. Bulk/long run any time (`OFFPEAK_ONLY=no`; set yes to hold them for off-peak). |
| `risky` | Auth, payments, migrations, production data | Every task treated as risk: high: two workers, judge, Sol senior review, Opus sign-off on every task; no review shortcuts; one task at a time; Opus retry cap 3/day. Uses noticeably more Opus quota. |
| `fast` | Prototypes, internal tools, urgent backlogs | One worker unless a task is risk: high, no judge, 3 tasks in parallel, 60 s polling in loop.sh, 10 min pause when pools are full, DeepSeek at high effort, bigger review shortcut (50 lines). |

## Task statuses
`queued -> claimed -> building -> gating -> reviewing -> merged`
Side exits: `needs-approval` (risk high, the orchestrator signs off), `needs-claude` (Claude retry cap hit,
resumes next day), `stuck` (retry chain exhausted; the orchestrator triages), `conflict` (auto re-queued),
`needs-you` (parked for you), `dropped` (closed without merging, e.g. split into smaller tasks).

Goal statuses: `new -> packed -> planned -> wrapup -> done`.

## Commands
| Command | What it does |
|---|---|
| `runner.sh run` | Scheduler. Starts queued tasks up to MAX_PARALLEL; respects `after:` and off-peak hours. |
| `runner.sh task T-012` | Run one task now, in the foreground (debugging). |
| `runner.sh approve T-012` / `reject T-012 "why"` | Used by /signoff. |
| `runner.sh batch` | One review over all small tasks that skipped per-task review. |
| `runner.sh status [--json]` | Table of all tasks (JSON lines for the orchestrator). |
| `runner.sh show T-012` | Compact digest of one task: brief, log, verdicts, last failure, gates, diffstat. |
| `runner.sh requeue / escalate / park / drop T-012 "text"` | Orchestrator actions: run again with a hint, run on the Claude retry, hand to you, close. |
| `orchestrate.sh goal "text" [profile]` | Queue a milestone goal. |
| `orchestrate.sh tick` | Housekeeping, then wake Claude if events are waiting (loop.sh and cron call this). |
| `orchestrate.sh events` / `brief` / `goals` | What's waiting, what Claude would be given, goal progress. |
| `orchestrate.sh wake` | Wake Claude now, ignoring the gap (still capped). |
| `cos.sh pack "goal"` / `map` / `status` / `triage` / `daily` | Cheap-model helper jobs: context pack, repo map, status note. |
| `cos.sh conflicts` | Re-queue merge-conflicted tasks on the new base (no model; runs every loop pass). |
| `doctor.sh [--models] [--claude]` | Health checks. |
| `stats.sh [days]` | Per-model calls, errors, speed, gate pass rate and best-of-2 wins in this repo. Use it to tune routing.sh. |
| `loop.sh` | Scheduler and orchestrator tick in a tmux window (recommended over cron). |

## Where to look when something breaks
- `.agents/logs/runs.csv`: every model call (date, time, task, role, model, exit code, seconds)
- `.agents/logs/fallbacks.log`: calls that overflowed from one plan to the other
- `.agents/tasks/T-012.gates.log`: test, scope and security output
- `.agents/tasks/T-012.*.out` and `.out.err`: model replies and errors
- `.agents/logs/T-012.log` and `cron.log`: runner output
- `.agents/logs/orchestrator.log`: every wake, its events and Claude's report; `.agents/orch/`: prompts and replies
- 9router dashboard: raw requests, RTK savings, provider errors

## How the kit drives omp
Each call is `omp -p --no-session --no-extensions --no-skills --no-rules --model <9router model> --thinking <level> --tools <set>`,
with the prompt on stdin. Workers get `OMP_WORKER_TOOLS` (read, edit, write, bash, grep, glob by default: add omp's LSP/AST
tools there if you want workers to use them), read-only jobs get `OMP_READ_TOOLS`, reviewers get `--no-tools`.
Pinning the tools keeps omp's subagent/task tools from starting extra model calls. The repo map and context pack run
in a throwaway checkout (`.worktrees/_readonly`), so they can't touch your working copy.

## Safety rules baked in
- Claude only runs through the official `claude` CLI, with ANTHROPIC_API_KEY removed from its environment.
- The orchestrator can't write code, commit, merge into main or push: its headless tool list only allows task
  files, NOTES.md, kit commands and read-only git. Only you merge `agents` into main.
- Models that train on your prompts (Muse Contributor) only run when `ALLOW_TRAINING=yes` in routing.sh.
- Workers can only change files listed in the brief; `.agents/`, `.claude/` and `CLAUDE.md` are always off limits.
- Claude retries (Opus by default) and orchestrator wakes have separate daily caps; GOAT calls are capped per day.
- Go and GOAT each meter one shared pool. When a call hits a capacity error (RATE_LIMIT_PATTERN), it walks
  that role's fallback chain in routing.sh (`fallback_chain`, `fallback_chain_for_role`): the same model on
  the other plan first, then free options where a weaker answer is safe. Workers never drop to free models;
  if every option is full the task pauses for 30 minutes (status queued, `not_before` set). Every switch is
  written to `.agents/logs/fallbacks.log`.
- Free models (OpenCode Free, Go's free models) are listed and explained at the top of
  routing.sh. Ones that may log or train on prompts only run when `ALLOW_TRAINING=yes`.
- Types listed in `BEST_OF_2` always get two competing workers from different families.
