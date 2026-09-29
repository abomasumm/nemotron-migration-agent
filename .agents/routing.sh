# shellcheck shell=bash disable=SC2034
# routing.sh: every model and routing decision lives here. Edit freely.
# Claude (orchestrator and last retry) runs only through the official claude CLI on your Pro login.
# Every other model goes omp (or Pi) -> 9router -> OpenCode Go / Command Code GOAT.
# Model strings are "<pi provider>/<model id as 9router exposes it>". Check with:
#   pi --list-models 9router
# then fix ROUTER, GO and GOAT below (and any model id marked VERIFY).

# ---- Harness: omp (Oh My Pi) or pi ----
HARNESS=${HARNESS:-omp}                # omp or pi; override per run with HARNESS=pi
# Flags added to every omp run: keep pipeline runs isolated from your personal omp extensions,
# skills and rules (the kit sends AGENTS.md and its own prompts itself).
OMP_FLAGS="--no-extensions --no-skills --no-rules"
# omp tool names for each access level (VERIFY against omp's docs; add LSP/AST tools here if you want
# workers to use them). Pinning the set also keeps omp's subagent/task tools from starting extra
# model calls on other providers.
OMP_WORKER_TOOLS="read,edit,write,bash,grep,find"
OMP_READ_TOOLS="read,grep,find"

# ---- Connection ----
ROUTER=9router                          # the provider name you gave 9router inside Pi
ROUTER_URL=http://127.0.0.1:20128/v1    # 9router's OpenAI-compatible endpoint (doctor.sh checks it)
GO="$ROUTER/ocg"                        # 9router prefix for OpenCode Go models   (VERIFY)
GOAT="$ROUTER/cmc"                      # 9router prefix for Command Code models  (VERIFY)
# GO and GOAT must differ: the kit uses the prefix to count GOAT calls and to overflow between plans.
# Error text that means "this model or pool can't take the call right now, try the next in its chain".
# Add 9router's wording if it differs. Timeouts are NOT in here: a slow model is a task failure, not capacity.
RATE_LIMIT_PATTERN='429|rate.?limit|usage limit|limit reached|quota|too many requests|overloaded|unavailable|503|502|credit|billing|model not found'
FREE_PREFIXES="$ROUTER/oc"            # free providers inside 9router (OpenCode Free)

# ---- Profile: default | risky | fast ----
# Set the repo's usual profile here. Override for one run with  PROFILE=fast .agents/runner.sh run
# or for one task with  profile: risky  in its frontmatter.
#   default  balanced: best-of-2 on features/debug/data/ui, senior review on risky and long tasks
#   risky    every task treated as risk: high (two workers, Sol senior review, Opus sign-off), no review
#            shortcuts, one task at a time. For auth, payments, migrations, production data.
#            Uses more Opus quota because you sign off every task.
#   fast     one worker unless risk: high, no judge, no off-peak wait, 3 tasks in parallel, 60 s polling,
#            DeepSeek at high instead of xhigh effort. For prototypes, internal tools, urgent backlogs.
PROFILE=${PROFILE:-default}
case "$PROFILE" in fast) DS_EFFORT=high ;; *) DS_EFFORT=xhigh ;; esac

# ---- How the plans meter usage ----
# Go and GOAT each have ONE shared pool (Go: $12 per 5h, $30/week, $60/month). Every model draws
# from it at its own rate. The "requests per month" tables are what you'd get using ONLY that model,
# so they are exchange rates, not separate budgets. When Go's 5-hour window fills, ALL Go models stop.
# Pool cost per request on Go, relative to Muse (lower = cheaper):
#   Muse 1x | MiMo Flash 1.5x | DeepSeek 4.1 Flash 1.7x | GLM-5.3 Flash 7x | MiMo Pro 14x
#   GLM-5.2 53x | GLM-5.3 210x | Kimi K3 460x
# Evidence (Sep 2026). LiveBench coding / LiveBench agentic coding / llm-stats coding / AA index / CursorBench 4.0:
#   Opus 5.5            89.3 / 71.7 / 51.7 / -  / 57.8   (best everywhere)
#   DeepSeek V4.1 Flash 80.0 / 77.3 / 43.3 / 40 / -      (TOP agentic score of any model; $0.029 per solved task)
#   Muse Spark 1.3      81.1 / 64.1 / 41.4 / 48 / -      (instruction following 78.0: reliable reviewer)
#   Kimi K3             81.4 / 62.2 / 42.3 / 44 / -
#   GPT-5.6 Sol         83.9 / 56.2 / 45.5 / 47 / 41.7   (strong coder and reviewer, weaker as an agent)
#   Grok 4.7            77.2 / 54.0 / 39.6 / 46 / 46.3   (not used: weaker than Kimi K3 on most sources)
#   GLM-5.3             79.0 / 60.9 / 41.8 / 45 / -      Sonnet 5  80.7 / 59.4 / 36.1 / - / 34.1
#   Gemini 3.8 Flash    72.5 / 54.2 / 37.7 / -  / 39.6   (instruction following 81.4, highest of all)
#   MiMo V2.6 Pro: too new for LiveBench; 46 on AA (top open model there), 41.4 on llm-stats.
# llm-stats full table (agents / tools / vision): Sol 41.3/29.4/36.5, DeepSeek 40.6/32.1/29.5,
#   Muse 39.8/30.3/27.6, Kimi 38.7/30.9/36.2, MiMo Pro 37.5/28.0/27.1, Gemini 3.8 Flash 35.1/23.2/34.1,
#   GLM-5.3 Flash 36.5/28.9/31.7, Sonnet 5 31.3/22.1/33.6, DeepSeek V4 Flash Vision Exp 32.2/21.9/22.1.
# Muse and DeepSeek are verbose (many output tokens per task), so they drain the pool faster
# than the request tables suggest. Scores were measured at max/xhigh effort, so the models below
# request xhigh through Pi's provider/model:thinking syntax.
# Routing rule: strongest per pool-dollar on the hot path; expensive models only where they add a
# different family or a real step up in strength.

# ---- Build seats (OpenCode Go) ----
M_DS="$GO/deepseek-v4.1-flash:$DS_EFFORT"  # WORKER A and long tasks: best agentic score measured, fast, 1.7x
# Muse on Go rejects "max" effort, so it runs at xhigh (Pi's provider/model:thinking syntax).
M_MUSEC="$GO/muse-spark-1.3-contributor:xhigh"  # WORKER B, T1 reviewer, context packs. 1x. Trains on prompts.
M_MIMOP="$GO/mimo-v2.6-pro"         # test-writer, first escalation (third family, 41.4)
M_MIMOF="$GO/mimo-v2.6-flash"       # bulk worker (1M context, 1.5x)
M_GLMF="$GO/glm-5.3-flash"         # backup reviewer and visual QA: a family no worker uses; vision 31.7
M_VIS="$M_GLMF"

# ---- GOAT: separate pool, used for the expensive specialists ----
M_SOL="$GOAT/gpt-5.6-sol:xhigh"     # judge, T2 reviewer, second escalation (VERIFY id)
M_KIMI="$GOAT/kimi-k3"              # UI escalation (42.8 web index; 980/month on GOAT) (VERIFY id)
M_GEM="$GOAT/gemini-3.8-flash"      # visual QA (VERIFY id)

# ---- Claude (Pro login, official CLI only) ----
# Last rung. Opus, not Sonnet: Sonnet 5 scores below DeepSeek and Muse on coding, so it rarely
# fixes what Sol could not. Opus uses more Pro quota per call, hence the low daily cap.
CLAUDE_ESC=CLAUDE_OPUS              # CLAUDE_OPUS or CLAUDE_SONNET

# ---- Orchestrator: Claude runs the pipeline, woken by events ----
# orchestrate.sh tick (from loop.sh or cron) does the cheap checks with scripts and only starts
# `claude -p` when something needs a decision: a new goal to plan, a stuck task, a risky task to sign
# off, or a finished milestone. Every wake is one call that handles all waiting events at once.
# Claude decides; the scripts still do all the mechanics (workers, gates, fallbacks, caps, logs).
ORCHESTRATOR=claude                 # claude, or cos (old behaviour: Muse triages stuck tasks, you run /plan and /signoff)
ORCH_MODEL=opus                     # planning, triage, sign-off (claude CLI model alias)
ORCH_LIGHT_MODEL=sonnet             # wakes that only contain milestone wrap-ups
CLAUDE_ORCH_DAILY_CAP=10            # orchestrator wakes per day, separate from CLAUDE_DAILY_CAP (retries)
ORCH_MIN_GAP_MIN=30                 # minutes between wakes; events that arrive meanwhile are batched.
                                    # Planning a new goal skips the gap.
ORCH_MAX_TRIAGE=2                   # stuck this many times after orchestrator triage -> needs-you, no more wakes
ORCH_AUTO_SIGNOFF=yes               # yes = the orchestrator approves/rejects risk: high tasks;
                                    # no = they wait for you to run /signoff
ORCH_TIMEOUT=20m                    # one wake (planning a large milestone takes the longest)
ORCH_BACKOFF_MIN=60                 # after Claude reports a usage limit, don't wake again for this long
# Error text from the claude CLI that means your Pro window is used up (VERIFY wording on first hit).
CLAUDE_LIMIT_PATTERN='usage limit|limit reached|rate.?limit|5-hour|weekly limit|out of (usage|credits)'
# What the orchestrator may do in headless mode (Claude Code permission rules; VERIFY on your version).
# It can read anything, edit only task and goal files and NOTES.md, and run only the kit's commands and
# read-only git. It cannot edit source code, merge into main, or push.
# Comma-separated, one string each.
ORCH_ALLOWED_TOOLS="Read,Grep,Glob,Edit(.agents/tasks/**),Write(.agents/tasks/**),Edit(NOTES.md),Bash(.agents/runner.sh:*),Bash(.agents/orchestrate.sh:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*)"
ORCH_DISALLOWED_TOOLS="Bash(git push:*),Bash(git merge:*),Bash(git checkout:*),Bash(git reset:*),Bash(git commit:*),WebFetch,WebSearch"

# ---- Free models inside 9router (considered for every role) ----
# OpenCode Free: no auth, model list changes without notice, treat as training/logging. Last resort only.
M_OC_FREE="$ROUTER/oc/auto"
# Go's own free models: don't draw the pool, unknown quality, anonymous. Bulk-only safety net.
M_BUNNY="$GO/space-bunny-free"
# Considered and NOT used: Vertex AI credits (left out at your request), Kiro (50 credits/month, OAuth through a proxy risks the account, older models),
# Antigravity and Claude Code OAuth (subscription logins must not go through 9router), OpenRouter :free
# models (need a key, low daily caps, logged). The discontinued iFlow, Qwen Code and Gemini CLI tiers are gone.

# ---- Fallback combos: tried in order when a call hits RATE_LIMIT_PATTERN ----
# Rules: same model on the other plan first; then a model that keeps the role's family rules; free
# models only where a weaker answer is safe (reviews get re-checked, bulk edits are gated). Workers
# never fall back to weaker free models: if every option is full the task pauses 30 minutes instead.
fallback_chain() { case "$1" in
  "$M_DS")     echo "$GOAT/deepseek-v4.1-flash:$DS_EFFORT" ;;
  "$M_MUSEC")  echo "$GOAT/muse-spark-1.3-contributor:xhigh" ;;
  "$M_MIMOP")  echo "$GOAT/mimo-v2.6-pro" ;;
  "$M_MIMOF")  echo "$GOAT/mimo-v2.6-flash $M_BUNNY" ;;
  "$M_SOL")    echo "$M_MIMOP $GOAT/mimo-v2.6-pro" ;;
  "$M_KIMI")   echo "$GO/kimi-k3 $M_MIMOP" ;;
  "$M_GEM")    echo "$M_VIS" ;;
  *)           echo "" ;;
esac; }
# Reviewer-seat fallbacks (T1) add GLM-5.3 Flash after the other plan: a family no worker uses.
# Chief of staff and mapper fall back to OpenCode Free last.
fallback_chain_for_role() { case "$2" in
  review1)          echo "$(fallback_chain "$1") $M_GLMF $GOAT/glm-5.3-flash" ;;
  cos-*|mapper)     echo "$(fallback_chain "$1") $M_GLMF $M_OC_FREE" ;;
  *)                fallback_chain "$1" ;;
esac; }

# ---- Repo settings ----
ALLOW_TRAINING=yes                  # yes = models that train on your prompts (Muse Contributor) may run.
                                    # Set to no for any repo whose code isn't yours to share.
MAIN_BRANCH=main                    # your real default branch
INTEGRATION_BRANCH=agents           # agents merge here; you merge to main after /signoff
TEST_GLOBS="test/* tests/* __tests__/* *.test.* *.spec.* *_test.* spec/*"

# ---- Limits ----
CLAUDE_DAILY_CAP=2                  # claude -p escalations per day (Opus uses more quota than Sonnet)
GOAT_DAILY_RUN_CAP=80               # all GOAT calls per day (plan-wide window is shared)
MAX_PARALLEL=1                      # raise to 2-3 after ~20 clean tasks
BEST_OF_2="feature debug data ui"    # types that always get two competing workers (risk:high always does)
TRIVIAL_LINES=20                    # low-risk patches under this skip per-task T1 review
OFFPEAK_START=22                    # bulk/long tasks only run between these local hours
OFFPEAK_END=7
OFFPEAK_ONLY=yes                    # no = bulk/long tasks run any time
FORCE_RISK=""                       # high = treat every task as risk: high
USE_JUDGE=yes                       # no = when both workers pass, take worker A without asking Sol
T2_ON_LONG=yes                      # senior review on every long task
PAUSE_MINUTES=30                    # wait when every model for a role is full
LOOP_SLEEP=300                      # loop.sh polling interval, seconds

# ---- Profile overrides (applied on top of the values above) ----
case "$PROFILE" in
  default) ;;
  risky) FORCE_RISK=high; TRIVIAL_LINES=0; MAX_PARALLEL=1; CLAUDE_DAILY_CAP=3; CLAUDE_ORCH_DAILY_CAP=16 ;;
  fast)  BEST_OF_2=""; USE_JUDGE=no; OFFPEAK_ONLY=no; T2_ON_LONG=no; TRIVIAL_LINES=50
         MAX_PARALLEL=3; PAUSE_MINUTES=10; LOOP_SLEEP=60; ORCH_MIN_GAP_MIN=10 ;;
  *) echo "routing.sh: unknown PROFILE=$PROFILE (use default, risky or fast)" >&2; exit 1 ;;
esac

# ---- Routes ----
# muse_or X: Muse Contributor when ALLOW_TRAINING=yes, otherwise X.
muse_or() { [ "$ALLOW_TRAINING" = yes ] && echo "$M_MUSEC" || echo "$1"; }

route_worker() { case "$1" in
  bulk) echo "$M_MIMOF" ;;
  *)    echo "$M_DS" ;;             # patch, feature, debug, data, ui, long (agentic 77.3)
esac; }

# Worker B for best-of-2 (always a different family from worker A)
route_alt() { case "$(family "$(route_worker "$1")")" in
  ds) muse_or "$M_MIMOF" ;;
  *)  echo "$M_DS" ;;
esac; }

# Retry ladder after the first attempt fails (space separated, in order)
route_ladder() { case "$1" in
  ui)    echo "$M_KIMI $M_SOL $CLAUDE_ESC" ;;
  bulk)  echo "$M_DS $(muse_or "$M_MIMOP")" ;;
  patch) echo "$(muse_or "$M_MIMOF") $M_MIMOP $M_SOL $CLAUDE_ESC" ;;
  long)  echo "$(muse_or "$M_MIMOF") $M_MIMOP $M_SOL $CLAUDE_ESC" ;;
  *)     echo "$M_MIMOP $M_SOL $CLAUDE_ESC" ;;       # feature, debug, data: both A and B already ran
esac; }

# Test-writer and T1 reviewer: always a different family from the worker ($1)
route_tests() { case "$(family "$1")" in mimo) echo "$M_DS" ;; *) echo "$M_MIMOP" ;; esac; }
# T1 is always the strongest cheap model outside the worker's family (Muse 48, MiMo Pro 46 on AA).
route_t1()    { case "$(family "${1:-}")" in muse) echo "$M_MIMOP" ;; *) muse_or "$M_MIMOP" ;; esac; }
route_t2()     { echo "$M_SOL"; }
route_t2_peer() { echo "$M_KIMI"; }  # senior review when Sol itself wrote the code (non-OpenAI)
route_t2_alt() { echo "$M_MIMOP"; }  # senior review / judge when GOAT is full
route_uiqa()   { echo "$M_GEM"; }     # then GLM-5.3 Flash on Go
route_mapper() { muse_or "$M_DS"; }
route_cos()    { muse_or "$M_DS"; }

route_timeout() { case "$1" in
  patch) echo 10m ;; bulk) echo 15m ;; long) echo 30m ;; review) echo 5m ;; *) echo 20m ;;
esac; }

family() { case "$1" in
  *deepseek*) echo ds ;; *glm*) echo glm ;; *mimo*) echo mimo ;; *kimi*) echo kimi ;;
  *muse*) echo muse ;; *gpt*|*sol*) echo openai ;; *gemini*) echo google ;; *grok*) echo xai ;;
  CLAUDE_*) echo claude ;; *) echo other ;;
esac; }

# Every model the pipeline can call (doctor.sh smoke-tests these)
all_models() { printf '%s\n' "$M_DS" "$M_MUSEC" "$M_MIMOP" "$M_MIMOF" "$M_VIS" "$M_SOL" "$M_KIMI" "$M_GEM" \
  "$GOAT/deepseek-v4.1-flash:$DS_EFFORT" "$GOAT/muse-spark-1.3-contributor:xhigh" "$GOAT/mimo-v2.6-pro" \
  "$GOAT/mimo-v2.6-flash" "$GO/kimi-k3" "$M_GLMF" "$GOAT/glm-5.3-flash" "$M_BUNNY" "$M_OC_FREE"; }
