# Agent pipeline kit: Claude-orchestrated, Architecture B through 9router, on Oh My Pi (no Paperclip)

Claude is the orchestrator. Opus 5.5 (Claude Code, Pro login) plans milestones, triages tasks the pipeline
couldn't finish, signs off risky work and closes milestones. It is woken by `orchestrate.sh` only when one of
those decisions is waiting, so it spends Pro quota on decisions, not on polling. Cheap models on OpenCode Go
and Command Code GOAT do the building and checking through Oh My Pi (omp) -> 9router. Plain Pi still works:
set HARNESS=pi. Scripts do everything deterministic. Claude never goes through 9router.

# How to run it

The workflow, start to finish. Steps A to C happen once; D repeats for every milestone.

```
A. Machine setup (once)  ->  B. Add a repo (once per repo)  ->  C. Control desk (once, optional)
                                         |
                                         v
D. Each milestone:  brief -> queue -> loop builds -> you check -> merge + push -> (update kit) -> next brief
```

## A. Machine setup (once per Mac)
1. **Install the tools.**
   ```bash
   brew install bash coreutils jq tmux gh node gitleaks semgrep ripgrep
   ```
   Plus Claude Code, Oh My Pi (`brew install can1357/tap/omp`), 9router (`npm i -g 9router`) and,
   as a fallback harness, Pi. Put `/opt/homebrew/bin` first in your PATH (in `~/.zshrc`): `which bash`
   must print `/opt/homebrew/bin/bash`, also inside tmux, and `gtimeout` must exist.
2. **Claude Code.** Run `claude`, then `/login` with your Pro account. `ANTHROPIC_API_KEY` must not be set.
3. **9router.** Change the default password, bind to 127.0.0.1, require an API key, turn Cloud Sync off.
   Add OpenCode Go (`ocg/`) and Command Code GOAT (`cmc/`). RTK on; Caveman, Ponytail, Headroom, PXPipe off;
   no fallback combos (the kit does fallbacks). Add `export NINEROUTER_API_KEY=...` to `~/.zshrc`.
4. **omp.**
   - Install the 9router plugin: `omp plugin install pi-9router-ext`. The kit loads it explicitly
     (`OMP_EXTENSIONS` in routing.sh), because pipeline runs switch other extensions off.
   - Merge `.agents/omp-models.example.yml` into `~/.omp/agent/models.yml`. It includes the
     `9router-direct` provider, which visual QA needs: the plugin sends Gemini a token limit GOAT rejects.
   - Merge `.agents/omp-config.example.yml` into `~/.omp/agent/config.yml`.
   - Check: `omp models 9router` lists the `ocg/` and `cmc/` models.
5. **Keep repos out of iCloud.** If "Desktop & Documents Folders" syncs to iCloud, keep repos elsewhere
   (e.g. `~/code`): sync fights with git worktrees. Repo paths must not contain spaces.

## B. Add a repo (once per repo)
1. **Install the kit** from the kit folder, pointing at the repo:
   ```bash
   bash ~/path/to/agent-pipeline-kit/setup.sh ~/code/my-repo
   cd ~/code/my-repo
   ```
2. **Tell the kit about the repo.**
   - `.agents/local.sh`: this repo's settings (PROFILE, ALLOW_TRAINING, MAIN_BRANCH, caps). Set
     `ALLOW_TRAINING=no` for any code that isn't yours. Leave `routing.sh` alone; it belongs to the kit.
   - `.agents/gates/check.sh`: the test, lint, typecheck and build commands. It detects Node
     (`package.json`) and Python (`pyproject.toml`) by itself; add anything else.
   - `AGENTS.md`: one line on the project, its commands and conventions. Every agent reads it.
3. **Check everything.** Fix every FAIL; warnings are informational.
   ```bash
   .agents/doctor.sh             # tools, kit version, repo, 9router, omp (free)
   .agents/doctor.sh --models    # every model replies "ready" (a little Go/GOAT quota)
   .agents/doctor.sh --claude    # claude -p works on your Pro login (a little Pro quota)
   ```
4. **Commit the kit before the first goal** (the `agents` branch starts from what's committed;
   `orchestrate.sh goal` refuses until it is), then map the repo:
   ```bash
   git add .agents .claude CLAUDE.md AGENTS.md NOTES.md .gitignore && git commit -m "agent pipeline"
   .agents/cos.sh map            # writes REPO_MAP.md; skim it
   ```
5. **Empty or untested repo?** The pipeline can only check work against tests, and `check.sh` passes
   everything when there's nothing to run. Make the first goal a scaffold that names the stack and sets up
   test, lint, typecheck and build commands, or set that up yourself in an interactive Claude Code session.
   Legacy code without tests: first add tests that pin down current behaviour.

## C. Control desk with DeepSeek Harness (once, optional)
dsh is where you draft briefs and check on pipelines in plain language. It acts only through `kitctl`,
an allow-listed, logged wrapper. Everything it does, you can also do by hand (shown in D).
1. Copy the control desk outside your repos and list your repos:
   ```bash
   cp -R ~/path/to/agent-pipeline-kit/ops ~/code/ops && cd ~/code/ops
   cp repos.txt.example repos.txt     # edit: "<name> <path>" per repo
   ./kitctl overview                  # every repo's goals, tasks, usage and loop health
   ```
2. In dsh (`tmux new -s dsh 'npx @deepseek-ai/dsh web --no-open'`, then http://127.0.0.1:3080):
   9router as a custom provider (`http://127.0.0.1:20128/v1`, `openai-completions`, DeepSeek V4.1 Flash on
   `cmc/`); `~/code/ops` as a **workspace-write** workspace (dsh reads `ops/AGENTS.md`, its rules); each repo
   as a **read-only** workspace. Never full access.
3. Run the trust test in `ops/README.md` before relying on it, and optionally add the morning-summary and
   weekly routing-report scheduled tasks.

## D. Each milestone
One goal per repo at a time. A goal is one milestone: typically 3 to 6 tasks and a few hours of runtime.

**1. Write the brief.** Use `ops/templates/goal-brief.md`: a one-line summary, the outcome, 3 to 6
testable acceptance bullets naming real functions, routes and files, the scope (test files too), low or
high risk, and constraints. In dsh: "draft a brief for <repo>: <idea>", then switch the chat to Sol or
Kimi and ask what's missing or untestable. Sharper briefs mean fewer retries and fewer Claude wakes.

**2. Queue it.** Pick the profile: `risky` for auth, payments, schema or migrations.
```bash
.agents/orchestrate.sh goal "$(cat brief.md)" [risky]        # by hand, in the repo
./kitctl my-repo goal --file briefs/my-repo-x.md [risky]     # or tell dsh "queue it"
```

**3. Make sure the loop is running.** It runs the scheduler and the orchestrator every 5 minutes.
```bash
tmux new -s agents 'caffeinate -is .agents/loop.sh'          # in the repo; Ctrl+b then d to detach
tmux ls                                                      # "agents" must be listed
```
Within a few minutes Muse packs context, Claude is woken to plan, and task files appear.

**4. Watch it (optional).**
```bash
.agents/orchestrate.sh goals      # packed -> planned -> wrapup -> done
.agents/runner.sh status          # each task: queued -> building -> gating -> reviewing -> merged
tail -f .agents/logs/runs.csv     # every model call as it happens
~/code/ops/kitctl overview        # all repos at once, with today's usage against the caps
```
Claude is woken on its own for stuck tasks (re-brief, split, escalate or park) and for sign-off on
high-risk tasks. You don't need to do anything unless a task lands in `needs-you`.

**5. Handle `needs-you` tasks.** `.agents/runner.sh show T-012` explains what went wrong. Then either
`.agents/runner.sh requeue T-012 "hint"`, or leave it parked and fix it yourself. dsh can explain the
digest and propose the hint; `kitctl` lets it requeue or park only tasks in `needs-you`.

**6. Check, merge, push** once the goal shows `done`. Claude never merges into main or pushes; you do.
```bash
git log --oneline main..agents                               # what the pipeline committed
git checkout agents && npm ci && npm test && npm run build && git checkout main   # optional: run it yourself
git status --short                                           # commit your own changes first, if any
git merge agents && git push
```
The next runner pass fast-forwards `agents` to `main` by itself, so new tasks start from what you merged.
If `git merge` reports a conflict, stop and look before resolving it.

**7. Between milestones.**
- Skim `NOTES.md`: Claude adds one-line lessons there (e.g. "list test files in scope").
- Fold lessons into your brief template.
- Pick up kit fixes, then restart the loop (see "Updating the kit in a repo" below):
  ```bash
  bash ~/path/to/agent-pipeline-kit/setup.sh --update .
  ```

## E. Habits
- **Daily:** `kitctl overview` (or dsh's morning digest): anything in `needs-you`, stopped loops, pool pauses.
- **Weekly:** read `ops/kitctl.log` (everything done through kitctl); check the Go and GOAT consoles.
- **After two weeks:** `.agents/stats.sh 14`, then tune models and caps in `local.sh`. Raise `MAX_PARALLEL`
  to 2 or 3 after about 20 clean tasks.
- **Several repos:** give each its own loop and lower caps in each `local.sh` so they share one Pro plan
  and one GOAT pool (see "One repo or several").

## F. Stopping, pausing and fallback
| To | Do |
|---|---|
| Stop the loop | `tmux kill-session -t agents` (running tasks stop; queued tasks wait) |
| Restart it | `tmux new -s agents 'caffeinate -is .agents/loop.sh'` in the repo |
| See why it exited | run `caffeinate -is .agents/loop.sh` without tmux and read the error |
| Run without Claude orchestrating | `tmux new -s agents 'ORCHESTRATOR=cos caffeinate -is .agents/loop.sh'` (see below) |
| Steer a pass yourself | `claude`, then `/orchestrate`; or `/plan` and `/signoff` |

## G. When something looks wrong
| Symptom | Likely cause and fix |
|---|---|
| `[exited]` right after starting tmux | The loop failed at once. Run it without tmux to see why (often tmux using macOS's old bash: fix PATH, `tmux kill-server`). |
| Every model "not found" in `.out.err` | The 9router plugin isn't loaded: check `OMP_EXTENSIONS` in routing.sh and `doctor.sh`. |
| Goal stays `packed`, log says "events unchanged" | Claude already saw this exact event and left it. Read its reply at the bottom of `.agents/logs/orchestrator.log`. |
| Goal sits at `new` or `packed` and nothing runs | The loop isn't running (`tmux ls`). |
| Task in `needs-you` | `runner.sh show T-NNN`; requeue with a hint, or fix by hand. |
| Task in `needs-claude` | Opus retry cap reached for today; it resumes tomorrow. |
| Tasks paused (`not_before` set) | A pool was full; see `.agents/logs/fallbacks.log`. They resume on their own. |
| `doctor.sh --models` FAIL | Wrong model id, or the model rejects a setting; the error text says which. |
| `git merge agents` conflict | Usually files changed on both sides (e.g. `.gitignore`). Look at both versions before choosing. |

# Reference

## Updating the kit in a repo
```
bash ~/path/to/agent-pipeline-kit/setup.sh --update /path/to/repo
```
It replaces the kit's own files (scripts, prompts, `routing.sh`, slash commands) with the kit's current
version and records it in `.agents/KIT_VERSION`; `doctor.sh` warns when a repo is behind. A kit file you
had edited in the repo is backed up to `.agents/.kit-backup/<time>/` first, and the output names it so you
can move the setting into `local.sh`. Never touched: `.agents/local.sh`, `.agents/gates/check.sh`,
`AGENTS.md`, `NOTES.md`, tasks and goals. Run it between milestones, commit, and restart the loop.

| File | Owned by | On `--update` |
|---|---|---|
| `.agents/*.sh`, `prompts/`, `routing.sh`, `.claude/commands/` | kit | replaced (edits backed up) |
| `.agents/local.sh` | repo | never touched |
| `.agents/gates/check.sh`, `AGENTS.md`, `NOTES.md` | repo | never touched |

Settings resolve in this order, last wins: `routing.sh` defaults, then `local.sh`, then a per-run
environment override (`PROFILE=fast .agents/runner.sh run`), then the profile's adjustments. The risky
profile scales Claude caps rather than replacing them, so a lowered cap in `local.sh` stays lower.

## What happens inside a milestone
```
orchestrate.sh goal       -> goal G-NNN is new
tick: Muse packs context  -> packed; Claude wakes, writes .agents/tasks/T-NNN.md, marks it planned
runner: per task          -> tests first (must fail on the old code), two workers, gates, judge,
                             first review (other family), senior review if risky -> merged into `agents`
tick: stuck task          -> Claude re-briefs, splits, escalates or parks it for you
tick: high-risk task      -> Claude reads the diff and approves or rejects
tick: all tasks merged    -> batch review of small tasks -> Claude (Sonnet) wraps up -> done
you                       -> merge `agents` into main, push
```
Anything Claude hands back to you is `needs-you` in `runner.sh status`, with the question in the task's
log and in `.agents/logs/orchestrator.log`.

## Fallback mode
`ORCHESTRATOR=cos` (the v3 behaviour) is for when Pro quota is short or the `claude` CLI is broken: Muse
triages stuck tasks once a day, and you run `/plan` and `/signoff` yourself. Switch by restarting the loop
with `ORCHESTRATOR=cos` (or set it in `local.sh`). In this mode `orchestrate.sh goal` refuses, because
nothing would plan the goal, and the loop warns about goals left open from claude mode. Merge conflicts are
still re-queued every pass. A middle ground is `ORCHESTRATOR=claude` with `ORCH_AUTO_SIGNOFF=no`: Claude
plans and triages, you sign off.

## One repo or several
It's one system. Every repo runs this kit unchanged, with its own loop, task queue and Claude orchestrator.
Going from one repo to several adds a layer above the repos. Nothing inside a repo changes:

| | One repo | Several repos |
|---|---|---|
| Kit in each repo | as above | as above, installed in each |
| `ops/repos.txt` | one line | one line per repo |
| Who queues goals | you (or dsh through `kitctl`, on your say) | dsh's scheduled check, from `ops/backlog.md` (not built yet) |
| Per-repo caps | routing.sh defaults | lowered per repo in `.agents/local.sh` so all repos fit one Pro plan, one Go pool and one GOAT pool |

Start with one repo. Add the portfolio layer once a second repo has run a few goals cleanly. `local.sh`
and `kitctl` exist; the cross-repo backlog and its scheduled check are designed but not built yet.

`docs/architecture.html` describes the whole system. A switch at the top changes the view between
**One repo** and **Several repos**. Open it with `#multi` at the end of the URL to start on the
several-repos view.

## Control desk (`ops/`)
`kitctl` is the only way dsh touches a pipeline: status, goals, usage and logs any time; queue a goal, or
requeue or park a `needs-you` task, when you say so; never approve, reject, escalate, drop, git or file
edits. Every call is logged to `kitctl.log`. dsh's rules are in `ops/AGENTS.md`, which dsh reads
automatically. Also there: `repos.txt`, the goal-brief template, and the morning-summary and weekly
routing-report prompts. Setup and the trust test are in `ops/README.md`.

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
Set the repo's usual profile with `PROFILE=` in `.agents/local.sh`. Override it for one run with
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
| `stats.sh [days]` | Per-model calls, errors, speed, gate pass rate and best-of-2 wins in this repo. Use it to tune `local.sh`. |
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
Each call is `omp -p --no-session --no-extensions -e <9router plugin> --no-skills --no-rules --model <9router model> --thinking <level> --tools <set>`,
with the prompt on stdin. Workers get `OMP_WORKER_TOOLS` (read, edit, write, bash, grep, glob by default: add omp's LSP/AST
tools there if you want workers to use them), read-only jobs get `OMP_READ_TOOLS`, reviewers get `--no-tools`.
Pinning the tools keeps omp's subagent/task tools from starting extra model calls. The repo map and context pack run
in a throwaway checkout (`.worktrees/_readonly`), so they can't touch your working copy.

## Safety rules baked in
- Claude only runs through the official `claude` CLI, with ANTHROPIC_API_KEY removed from its environment.
- The orchestrator can't write code, commit, merge into main or push: its headless tool list only allows task
  files, NOTES.md, kit commands and read-only git. Only you merge `agents` into main.
- Models that train on your prompts (Muse Contributor) only run when `ALLOW_TRAINING=yes` (set it per repo in `local.sh`).
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
