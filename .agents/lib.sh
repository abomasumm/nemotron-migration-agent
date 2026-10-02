# shellcheck shell=bash disable=SC2034
# lib.sh: shared helpers. Sourced by runner.sh and cos.sh.
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "run inside a git repo"; exit 1; }
AG="$ROOT/.agents"
TASKS="$AG/tasks"; LOGS="$AG/logs"; WT="$ROOT/.worktrees"
mkdir -p "$TASKS" "$LOGS" "$WT" "$AG/locks"
# shellcheck source=/dev/null
source "$AG/routing.sh" || exit 1
REPO_PROFILE=$PROFILE

# GNU timeout is "gtimeout" on macOS (brew install coreutils)
TIMEOUT=$(command -v timeout || command -v gtimeout) || { echo "need timeout/gtimeout"; exit 1; }
today() { date +%F; }
now() { date '+%F %T'; }

# ---------- task file frontmatter ----------
fm_get() { awk -v k="$2" 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit}
  f{ i=index($0,":"); if(substr($0,1,i-1)==k){v=substr($0,i+1); sub(/^[ \t]+/,"",v); print v; exit} }' "$1"; }

fm_set() { local f=$1 k=$2 v=$3 tmp; tmp=$(mktemp)
  awk -v k="$k" -v v="$v" 'NR==1&&$0=="---"{f=1;print;next}
    f&&$0=="---"{ if(!done) print k": "v; f=0; print; next }
    f{ i=index($0,":"); if(substr($0,1,i-1)==k){print k": "v; done=1; next} } {print}' "$f" >"$tmp" && mv "$tmp" "$f"; }

body() { awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{f=0;b=1;next} b{print}' "$1"; }
task_files() { local f; for f in "$TASKS"/T-*.md; do [[ $(basename "$f") =~ ^T-[0-9]+\.md$ ]] && echo "$f"; done | sort; }
tlog() { printf -- '- %s %s\n' "$(now)" "$2" >>"$1"; }   # append to task file's log

# ---------- locks (portable, mkdir based) ----------
lock() { local d="$AG/locks/$1"; local n=0
  until mkdir "$d" 2>/dev/null; do n=$((n+1)); [ $n -gt 60 ] && return 1; sleep 1; done; }
unlock() { rmdir "$AG/locks/$1" 2>/dev/null; }

# ---------- usage caps ----------
# Counts real model calls today (outcome rows like gate-pass or b2win are not calls).
count_today() { local n; n=$(grep "^$(today)," "$LOGS/runs.csv" 2>/dev/null | grep -vE ',(gate-|b2)[a-z]*,' | grep -c ",$1"); echo "${n:-0}"; }
logout() { logrun "$1" "$2" "$3" 0 0; }   # outcome row: logout <id> <gate-pass|gate-fail|b2win|b2loss> <model>
goat_ok() { [ "$(count_today "$GOAT/")" -lt "$GOAT_DAILY_RUN_CAP" ]; }
is_goat() { case "$1" in "$GOAT"/*) return 0;; *) return 1;; esac; }
claude_ok() { [ "$(count_today "$CLAUDE_ESC")" -lt "$CLAUDE_DAILY_CAP" ]; }

logrun() { # id role model rc seconds
  echo "$(today),$(date +%T),$1,$2,$3,$4,$5" >>"$LOGS/runs.csv"; }

# ---------- model runners ----------
# run_model <id> <role> <model> <tools|none> <promptfile> <outfile> <cwd> <timeout>
# On a capacity error (RATE_LIMIT_PATTERN) walks the role's fallback chain in routing.sh.
# Returns 75 if every option was full, so the runner can pause the task instead of failing it.
training_ok() { case "$1" in *contributor*|"$ROUTER"/oc/*|*-free) [ "${ALLOW_TRAINING:-no}" = yes ] ;; *) true ;; esac; }
capacity_err() { grep -qiE "$RATE_LIMIT_PATTERN" "$1.err" "$1" 2>/dev/null; }
run_model() {
  local id=$1 role=$2 model=$3 fb rc tried=""
  if ! training_ok "$model"; then
    echo "blocked: $model may train on prompts and ALLOW_TRAINING is not yes" >"$6.err"; : >"$6"
    logrun "$id" "$role" "$model" 4 0; return 4
  fi
  _run_once "$@"; rc=$?
  [ $rc -eq 0 ] && return 0
  capacity_err "$6" || return $rc
  shift 3
  for fb in $(fallback_chain_for_role "$model" "$role"); do
    training_ok "$fb" || continue
    is_goat "$fb" && ! goat_ok && continue
    case " $tried " in *" $fb "*) continue ;; esac; tried="$tried $fb"
    echo "$(now) $id $role: $model full, trying $fb" >>"$LOGS/fallbacks.log"
    _run_once "$id" "$role" "$fb" "$@"; rc=$?
    [ $rc -eq 0 ] && return 0
    capacity_err "$3" || return $rc
    model=$fb
  done
  echo "$(now) $id $role: every option full, pausing" >>"$LOGS/fallbacks.log"
  return 75
}

# Split "provider/model:level" into model and thinking level (level may be empty).
split_model() { case "${1##*:}" in minimal|low|medium|high|xhigh|max) echo "${1%:*} ${1##*:}" ;; *) echo "$1 " ;; esac; }

_run_once() {
  local id=$1 role=$2 model=$3 tools=$4 pf=$5 out=$6 cwd=$7 tmo=$8 rc t0
  t0=$(date +%s)
  if [ "${model#CLAUDE_}" != "$model" ]; then
    # Official Claude Code CLI on your Pro login. Never set ANTHROPIC_API_KEY here.
    local cm; cm=$(echo "${model#CLAUDE_}" | tr '[:upper:]' '[:lower:]')
    ( cd "$cwd" && env -u ANTHROPIC_API_KEY "$TIMEOUT" "$tmo" claude -p --model "$cm" \
        --permission-mode acceptEdits --allowedTools "Read,Edit,Write,Glob,Grep,Bash" \
        "Follow the task instructions provided on stdin." <"$pf" ) >"$out" 2>"$out.err"
    rc=$?
  elif [ "$HARNESS" = omp ]; then
    # Oh My Pi: prompt goes on stdin (print mode reads non-TTY stdin as the message);
    # thinking level goes in --thinking; tools are pinned per access level.
    local base lvl tf=() of=()
    read -r base lvl <<<"$(split_model "$model")"
    case "$tools" in
      none) tf=(--no-tools) ;;
      "$WORKER_TOOLS") [ -n "$OMP_WORKER_TOOLS" ] && tf=(--tools "$OMP_WORKER_TOOLS") ;;
      "$READ_TOOLS") tf=(--tools "$OMP_READ_TOOLS") ;;
      *) tf=(--tools "$tools") ;;
    esac
    read -ra of <<<"$OMP_FLAGS"
    local e; for e in ${OMP_EXTENSIONS:-}; do of+=(-e "$e"); done
    ( cd "$cwd" && "$TIMEOUT" "$tmo" omp -p --no-session "${of[@]}" --model "$base" \
        ${lvl:+--thinking "$lvl"} "${tf[@]}" <"$pf" ) >"$out" 2>"$out.err"
    rc=$?
  else
    local tf=(); [ "$tools" = none ] && tf=(--no-tools) || tf=(--tools "$tools")
    ( cd "$cwd" && "$TIMEOUT" "$tmo" pi -p --no-session --model "$model" "${tf[@]}" \
        "Follow the task instructions provided on stdin." <"$pf" ) >"$out" 2>"$out.err"
    rc=$?
  fi
  logrun "$id" "$role" "$model" "$rc" "$(( $(date +%s)-t0 ))"
  return $rc
}

WORKER_TOOLS="read,bash,edit,write,grep,find,ls"
READ_TOOLS="read,grep,find,ls"

in_offpeak() { local h; h=$((10#$(date +%H)))
  if [ "$OFFPEAK_START" -gt "$OFFPEAK_END" ]; then [ "$h" -ge "$OFFPEAK_START" ] || [ "$h" -lt "$OFFPEAK_END" ]
  else [ "$h" -ge "$OFFPEAK_START" ] && [ "$h" -lt "$OFFPEAK_END" ]; fi; }

goat_or() { if is_goat "$1" && ! goat_ok; then echo "$2"; else echo "$1"; fi; }

# Pull the first {...} block out of a model reply (models sometimes add prose around JSON)
json_block() { awk 'BEGIN{RS="\001"} {s=index($0,"{"); e=0; for(i=length($0);i>0;i--) if(substr($0,i,1)=="}"){e=i;break}
  if(s&&e>s) print substr($0,s,e-s+1)}' "$1"; }

# A throwaway checkout for read-only jobs (repo map, context pack), so an agent that ignores its
# instructions can never edit your main checkout. Reset on every use.
ro_tree() { local p="$WT/_readonly" b="$INTEGRATION_BRANCH"
  git -C "$ROOT" show-ref --verify --quiet "refs/heads/$b" || b=$MAIN_BRANCH
  if [ -d "$p" ]; then git -C "$p" checkout -q --detach "$b" && git -C "$p" reset -q --hard "$b" && git -C "$p" clean -qfd
  else git -C "$ROOT" worktree add -q --detach "$p" "$b"; fi
  echo "$p"; }

pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }
