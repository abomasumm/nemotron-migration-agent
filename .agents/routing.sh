# shellcheck shell=bash disable=SC2034
# routing.sh: every model and routing decision lives here. It belongs to the kit: setup.sh --update
# replaces it. Put this repo's own settings in .agents/local.sh, which is loaded below and never replaced.
# Every model runs on Nebius Token Factory through pi, with the repo's own pi config in .agents/pi/
# (never your personal ~/.pi). Model strings are "tokenfactory/<model id>[:thinking level]". Check with:
#   PI_CODING_AGENT_DIR=.agents/pi pi --list-models tokenfactory

# Per-run overrides from the environment (PROFILE=fast .agents/runner.sh run) beat local.sh.
_ENV_PROFILE=${PROFILE:-}

# ---- Harness: pi, isolated from your own setup ----
ROUTING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PI_CODING_AGENT_DIR="$ROUTING_DIR/pi"
# No MCP servers, extensions, skills, prompt templates or AGENTS.md discovery: the kit sends AGENTS.md
# and its own prompts itself, and --tools would still let MCP tools through.
PI_FLAGS="--no-mcp --no-extensions --no-skills --no-prompt-templates --no-context-files"

# ---- Connection ----
TF=tokenfactory                                    # provider name in .agents/pi/models.json
TF_URL=https://api.tokenfactory.nebius.com/v1      # doctor.sh checks it with NEBIUS_API_KEY
# Error text that means "this model can't take the call right now, try the next in its chain".
# Timeouts are NOT in here: a slow model is a task failure, not capacity.
RATE_LIMIT_PATTERN='429|rate.?limit|too many requests|overloaded|service unavailable|temporarily unavailable|503|502'

# ---- Profile: default | risky | fast ----
# Set the repo's usual profile here. Override for one run with  PROFILE=fast .agents/runner.sh run
# or for one task with  profile: risky  in its frontmatter.
#   default  balanced: best-of-2 on features/debug/data/ui, senior review on risky and long tasks
#   risky    every task treated as risk: high (two workers, senior review, orchestrator sign-off), no review
#            shortcuts, one task at a time. For auth, payments, migrations, production data.
#   fast     one worker unless risk: high, no judge, 3 tasks in parallel, 60 s polling, workers at high
#            instead of xhigh effort. For prototypes, internal tools, urgent backlogs.
PROFILE=${PROFILE:-default}
case "$PROFILE" in fast) EFFORT=high ;; *) EFFORT=xhigh ;; esac

# ---- Models (all on Token Factory) ----
# Picked by Artificial Analysis Intelligence Index v5 per dollar (Oct 2026). One NVIDIA Nemotron model, the
# strongest and cheapest Nemotron, checks every change: it is a family no worker uses, so no model ever
# grades its own family's work. Three other families write the code.
M_NEMO="$TF/nvidia/Nemotron-3.5-Super-VL"                  # judge, every review, UI screenshot QA (index 14)
M_DS="$TF/deepseek-ai/DeepSeek-V4.1-Flash-1017:$EFFORT"    # orchestrator, WORKER A (index 32)
M_MM="$TF/MiniMaxAI/MiniMax-M3.1-Flash:$EFFORT"            # WORKER B, repo map, context packs (index 29)
M_GLM="$TF/zai-org/GLM-5.3-Flash:$EFFORT"                  # pin tests, first retry (index 28)
M_DS_MAX="${M_DS%:*}:max"                                  # last rung: the strongest model at full effort
M_HELPER=$M_MM                                             # repo map, context packs, setup suggestions

# ---- Orchestrator: DeepSeek V4.1 Flash 1017 runs the pipeline, woken by events ----
# orchestrate.sh tick (from loop.sh) does the cheap checks with scripts and only wakes the orchestrator
# when something needs a decision: a new goal to plan, a stuck task, a risky task to sign off, or a
# finished milestone. Every wake is one call that handles all waiting events at once.
# The orchestrator decides; the scripts still do all the mechanics (workers, gates, fallbacks, caps, logs).
ORCH_MODEL=$M_DS                    # planning, triage, sign-off
ORCH_LIGHT_MODEL=$M_DS              # wakes that only contain milestone wrap-ups
ORCH_DAILY_CAP=20                   # orchestrator wakes per day
ORCH_MIN_GAP_MIN=10                 # minutes between wakes; events that arrive meanwhile are batched.
                                    # Planning a new goal skips the gap.
ORCH_MAX_TRIAGE=2                   # stuck this many times after orchestrator triage -> needs-you, no more wakes
ORCH_AUTO_SIGNOFF=yes               # yes = the orchestrator approves/rejects risk: high tasks;
                                    # no = they wait for you (runner.sh approve/reject)
ORCH_TIMEOUT=20m                    # one wake (planning a large milestone takes the longest)
# pi can't pin paths or commands, so the orchestrator gets file tools and no shell. It lists kit commands
# in its reply (RUN: lines) and orchestrate.sh runs only the allowed ones; edits it makes outside task
# files and NOTES.md to files that were clean before the wake are undone.
ORCH_TOOLS="read,grep,find,ls,edit,write"

# ---- Fallbacks: tried in order when a call hits RATE_LIMIT_PATTERN ----
# Same strength first, then a model that keeps the role's family rules. If every option is full the
# task pauses PAUSE_MINUTES instead of falling back further.
fallback_chain() { case "$1" in
  "$M_DS"|"$M_DS_MAX") echo "$M_MM" ;;
  "$M_MM")    echo "$M_GLM" ;;
  "$M_GLM")   echo "$M_MM" ;;
  *)          echo "" ;;            # Nemotron: no other family may review, so the task pauses instead
esac; }
fallback_chain_for_role() { fallback_chain "$1"; }

# ---- Repo settings ----
MAIN_BRANCH=main                    # your real default branch
INTEGRATION_BRANCH=agents           # agents merge here; you merge to main after sign-off
TEST_GLOBS="test/* tests/* __tests__/* *.test.* *.spec.* *_test.* spec/*"

# ---- Limits ----
ESC_MODEL=$M_DS_MAX                 # last rung of every retry ladder, and runner.sh escalate
ESC_DAILY_CAP=10                    # last-rung retries per day
MAX_PARALLEL=1                      # raise to 2-3 after ~20 clean tasks
BEST_OF_2="feature debug data ui migrate"  # types that always get two competing workers (risk:high always does)
TRIVIAL_LINES=20                    # low-risk patches under this skip per-task review
FORCE_RISK=""                       # high = treat every task as risk: high
USE_JUDGE=yes                       # no = when both workers pass, take worker A without a judge
T2_ON_LONG=yes                      # senior review on every long task
PAUSE_MINUTES=30                    # wait when every model for a role is rate-limited
FLAKY_RERUNS=2                      # reruns of failed gates; a pass on rerun marks a test flaky
LOOP_SLEEP=300                      # loop.sh polling interval, seconds

# ---- This repo's own settings ----
# .agents/local.sh belongs to the repo: PROFILE, MAIN_BRANCH, caps, model swaps. Anything set above can
# be set there. setup.sh --update never touches it. See local.sh.example.
# .agents/secrets.sh holds this machine's API keys (exported, so pi sees them). Git ignores it.
# shellcheck source=/dev/null
[ -f "$(dirname "${BASH_SOURCE[0]}")/secrets.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/secrets.sh"
# shellcheck source=/dev/null
[ -f "$(dirname "${BASH_SOURCE[0]}")/local.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/local.sh"
PROFILE=${_ENV_PROFILE:-$PROFILE}

# ---- Roles chosen in the app: .agents/config.json {"roles": {"<role>": "provider/model[:level]"}} ----
# Written by the web app's model picker; wins over the defaults above and local.sh. Roles are fixed (see
# catalog.json), only the model per role changes.
if [ -f "$ROUTING_DIR/config.json" ] && command -v jq >/dev/null; then
  _role() { jq -r --arg r "$1" '.roles[$r] // empty' "$ROUTING_DIR/config.json" 2>/dev/null; }
  _v=$(_role orchestrator); [ -n "$_v" ] && { ORCH_MODEL=$_v; ORCH_LIGHT_MODEL=$_v; }
  _v=$(_role reviewer);     [ -n "$_v" ] && M_NEMO=$_v
  _v=$(_role worker_a);     [ -n "$_v" ] && M_DS=$_v
  _v=$(_role worker_b);     [ -n "$_v" ] && M_MM=$_v
  _v=$(_role tester);       [ -n "$_v" ] && M_GLM=$_v
  _v=$(_role helper);       [ -n "$_v" ] && M_HELPER=$_v
  _v=$(_role last_retry);   [ -n "$_v" ] && { ESC_MODEL=$_v; M_DS_MAX=$_v; }
  unset _v
fi

# ---- Profile overrides (applied on top of the values above, including local.sh) ----
case "$PROFILE" in
  default) ;;
  risky) FORCE_RISK=high; TRIVIAL_LINES=0; MAX_PARALLEL=1
         ESC_DAILY_CAP=$(( ESC_DAILY_CAP + 2 )); ORCH_DAILY_CAP=$(( ORCH_DAILY_CAP * 16 / 10 )) ;;
  fast)  BEST_OF_2=""; USE_JUDGE=no; T2_ON_LONG=no; TRIVIAL_LINES=50
         MAX_PARALLEL=3; PAUSE_MINUTES=10; LOOP_SLEEP=60; ORCH_MIN_GAP_MIN=5
         M_DS="${M_DS%:*}:high"; M_MM="${M_MM%:*}:high"; M_GLM="${M_GLM%:*}:high" ;;
  *) echo "routing.sh: unknown PROFILE=$PROFILE (use default, risky or fast)" >&2; exit 1 ;;
esac

# ---- Routes ----
route_worker() { case "$1" in
  pin)  echo "$M_GLM" ;;            # characterization tests: the test-writer family
  *)    echo "$M_DS" ;;             # patch, feature, debug, data, ui, long, bulk, migrate
esac; }

# Worker B for best-of-2 (always a different family from worker A)
route_alt() { if [ "$(family "$(route_worker "$1")")" = "$(family "$M_MM")" ]; then echo "$M_DS"; else echo "$M_MM"; fi; }

# Retry ladder after the first attempt fails (space separated, in order)
route_ladder() { case "$1" in
  pin)   echo "$M_MM $ESC_MODEL" ;;                 # pin's first worker is GLM
  patch|long|ui|bulk) echo "$M_MM $M_GLM $ESC_MODEL" ;;
  *)     echo "$M_GLM $ESC_MODEL" ;;                # feature, debug, data, migrate: A and B already ran
esac; }

# Test-writer: always a different family from the worker ($1)
route_tests() { if [ "$(family "$1")" = "$(family "$M_GLM")" ]; then echo "$M_MM"; else echo "$M_GLM"; fi; }
# Every review, the judge and visual QA are Nemotron, a family no worker uses.
route_t1()     { echo "$M_NEMO"; }
route_t2()     { echo "$M_NEMO"; }
route_t2_alt() { echo "$M_NEMO"; }
route_judge()  { echo "$M_NEMO"; }
route_uiqa()   { echo "$M_NEMO"; }
route_mapper() { echo "$M_HELPER"; }
route_cos()    { echo "$M_HELPER"; }

route_timeout() { case "$1" in
  patch) echo 10m ;; bulk) echo 15m ;; long) echo 30m ;; review) echo 5m ;; *) echo 20m ;;
esac; }

# Model family, so best-of-2, test-writers and reviewers never share one with the worker.
# From catalog.json when the model is listed there, otherwise guessed from the name.
family() { local id=${1#*/} f; id=${id%:*}
  f=$(jq -r --arg id "$id" '.models[] | select(.id == $id) | .family' "$ROUTING_DIR/catalog.json" 2>/dev/null)
  [ -n "$f" ] && { echo "$f"; return; }
  case "$1" in
    *emotron*) echo nemotron ;; *DeepSeek*|*deepseek*) echo deepseek ;; *MiniMax*|*minimax*) echo minimax ;;
    *GLM*|*glm*) echo glm ;; *Qwen*|*qwen*) echo qwen ;; *Kimi*|*kimi*) echo kimi ;; *) echo other ;;
  esac; }

# Every model the pipeline can call (doctor.sh smoke-tests these)
all_models() { printf '%s\n' "$ORCH_MODEL" "$M_NEMO" "$M_DS" "$M_MM" "$M_GLM" "$M_HELPER" "$ESC_MODEL" | awk '!seen[$0]++'; }
