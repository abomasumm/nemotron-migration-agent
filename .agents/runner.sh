#!/usr/bin/env bash
# runner.sh: the agent pipeline.
#   runner.sh run            pick up queued tasks (cron calls this every 5 min)
#   runner.sh task T-012     run one task now, in the foreground
#   runner.sh approve T-012  merge a needs-approval task (used by /signoff)
#   runner.sh reject T-012 "why"   send it back with a note
#   runner.sh batch          one review over all batch-review tasks (end of milestone)
#   runner.sh status [--json]      table of all tasks (--json: one object per task, for the orchestrator)
#   runner.sh show T-012     compact digest of one task: brief, log, verdicts, last failure, diffstat
#   runner.sh requeue T-012 "hint"   run it again from the start, with a hint for the workers
#   runner.sh escalate T-012 "hint"  run it again straight on the Claude retry (counts toward CLAUDE_DAILY_CAP)
#   runner.sh park T-012 "why"       hand it to you (needs-you)
#   runner.sh drop T-012 "why"       close it without merging (e.g. replaced by smaller tasks)
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
PROMPTS="$AG/prompts"; SELF="$AG/runner.sh"
INT_WT="$WT/_integration"

ensure_integration() {
  git -C "$ROOT" show-ref --verify --quiet "refs/heads/$INTEGRATION_BRANCH" ||
    git -C "$ROOT" branch "$INTEGRATION_BRANCH" "$MAIN_BRANCH"
  [ -d "$INT_WT" ] || git -C "$ROOT" worktree add -q "$INT_WT" "$INTEGRATION_BRANCH"
}

fresh_tree() { # name branch -> prints path; tree reset to integration head
  local p="$WT/$1"
  if [ -d "$p" ]; then
    git -C "$p" reset -q --hard && git -C "$p" clean -qfd
    git -C "$p" checkout -q -B "$2" "$INTEGRATION_BRANCH"
  else
    git -C "$ROOT" worktree add -q -B "$2" "$p" "$INTEGRATION_BRANCH"
  fi
  echo "$p"
}

drop_tree() { git -C "$ROOT" worktree remove --force "$WT/$1" 2>/dev/null; git -C "$ROOT" branch -qD "$2" 2>/dev/null; }

commit_all() { git -C "$1" add -A && git -C "$1" commit -qm "$2" --no-verify >/dev/null 2>&1; true; }

diff_lines() { git -C "$1" diff --numstat "$INTEGRATION_BRANCH"...HEAD | awk '{s+=$1+$2} END{print s+0}'; }

make_pack() { # taskfile worktree out
  local f=$1 w=$2 g p s
  {
    [ -f "$ROOT/REPO_MAP.md" ] && { echo "# Repo map"; cat "$ROOT/REPO_MAP.md"; echo; }
    echo "# Files in scope"
    set -f
    for g in $(fm_get "$f" files | tr ',' ' '); do
      git -C "$w" ls-files | while read -r p; do
        # shellcheck disable=SC2053
        [[ $p == $g ]] && { echo "## $p"; head -n 300 "$w/$p"; echo; }
      done
    done
    set +f
    s=$(body "$f" | grep -o '`[A-Za-z_][A-Za-z0-9_.]*`' | tr -d '`' | sort -u | head -15)
    [ -n "$s" ] && { echo "# Where referenced symbols appear"
      for p in $s; do git -C "$w" grep -n -w -m 3 "$p" -- . ':!.agents' 2>/dev/null | head -5; done; }
    [ -f "$ROOT/NOTES.md" ] && { echo; echo "# Known pitfalls"; tail -n 40 "$ROOT/NOTES.md"; }
  } | head -c 60000 >"$TASKS/$(fm_get "$f" id).pack.md"
}

build_prompt() { # promptname taskfile extrafile out
  {
    cat "$PROMPTS/$1.md"; echo
    [ -f "$ROOT/AGENTS.md" ] && { echo "# AGENTS.md"; cat "$ROOT/AGENTS.md"; echo; }
    cat "$TASKS/$(fm_get "$2" id).pack.md" 2>/dev/null; echo
    echo "# Task brief"; cat "$2"
    [ -n "$3" ] && [ -s "$3" ] && { echo; echo "# Read this first: previous attempt"; cat "$3"; }
  } >"$4"
}

attempt_worker() { # id taskfile wt model extra role
  local id=$1 f=$2 w=$3 m=$4 extra=$5 role=$6 type pf
  type=$(fm_get "$f" type); pf="$TASKS/$id.$role.prompt"
  build_prompt worker "$f" "$extra" "$pf"
  echo "Task type: $type. $(sed -n "s/^$type: //p" "$PROMPTS/types.md")" >>"$pf"
  run_model "$id" "$role" "$m" "$WORKER_TOOLS" "$pf" "$TASKS/$id.$role.out" "$w" "$(route_timeout "$type")"
  [ $? -eq 75 ] && touch "$TASKS/$id.paused"
  commit_all "$w" "$id: $role ($m)"
}

tests_fail_on_base() { ( cd "$1" && MODE=tests BASE="$INTEGRATION_BRANCH" bash "$AG/gates/check.sh" ) >"$TASKS/$2.red.log" 2>&1 && return 1; return 0; }

write_tests() { # id taskfile tests-wt worker-model
  local id=$1 f=$2 w=$3 tm pf="$TASKS/$1.tests.prompt"
  tm=$(route_tests "$4")
  build_prompt tests "$f" "" "$pf"
  run_model "$id" tests "$tm" "$WORKER_TOOLS" "$pf" "$TASKS/$id.tests.out" "$w" 15m
  [ $? -eq 75 ] && { touch "$TASKS/$id.paused"; return; }
  commit_all "$w" "$id: tests ($tm)"
  if ! tests_fail_on_base "$w" "$id"; then
    echo "Your tests PASS on the unchanged code, so they do not test the new behaviour. Rewrite them so they fail until the brief is implemented." >"$TASKS/$id.tests.note"
    build_prompt tests "$f" "$TASKS/$id.tests.note" "$pf"
    run_model "$id" tests "$tm" "$WORKER_TOOLS" "$pf" "$TASKS/$id.tests.out" "$w" 15m
    [ $? -eq 75 ] && { touch "$TASKS/$id.paused"; return; }
    commit_all "$w" "$id: tests retry ($tm)"
    tests_fail_on_base "$w" "$id" && echo red >"$TASKS/$id.red" || echo weak >"$TASKS/$id.red"
  else echo red >"$TASKS/$id.red"; fi
}

add_tests() { [ -f "$TASKS/$2.red" ] && git -C "$1" merge -q --no-edit "task/$2-tests" >/dev/null 2>&1; true; }

run_gates() { # wt id taskfile logname
  ( cd "$1" && export BASE="$INTEGRATION_BRANCH" TASK_FILE="$3" TEST_GLOBS="$TEST_GLOBS" &&
      bash "$AG/gates/check.sh" && bash "$AG/gates/scope.sh" && bash "$AG/gates/security.sh" ) >"$TASKS/$4" 2>&1
}

task_risk() { [ -n "$FORCE_RISK" ] && echo "$FORCE_RISK" || fm_get "$1" risk; }

verdict() { grep -o '"verdict"[[:space:]]*:[[:space:]]*"[A-Z]*"' "$1" 2>/dev/null | head -1 | grep -o '[A-Z]*"$' | tr -d '"'; }

review() { # id wt taskfile model role gatelog -> prints verdict
  local id=$1 w=$2 f=$3 m=$4 role=$5 pf="$TASKS/$1.$5.prompt" out="$TASKS/$1.$5.json"
  { cat "$PROMPTS/$role.md"; echo; echo "# Brief"; cat "$f"; echo; echo "# Diff"
    git -C "$w" diff "$INTEGRATION_BRANCH"...HEAD | head -c 80000; echo
    echo "# Gate output (tail)"; tail -n 60 "$TASKS/$6"; } >"$pf"
  run_model "$id" "$role" "$m" none "$pf" "$out" "$w" "$(route_timeout review)"
  [ $? -eq 75 ] && { touch "$TASKS/$id.paused"; echo PAUSED; return; }
  verdict "$out"
}

visual_qa() { # id wt taskfile -> prints verdict
  local id=$1 w=$2 f=$3 shots="$TASKS/$1.shots" pf="$TASKS/$1.uiqa.prompt"
  [ -x "$AG/gates/ui.sh" ] || { echo PASS; return; }
  rm -rf "$shots"; mkdir -p "$shots"
  ( cd "$w" && SHOTS="$shots" bash "$AG/gates/ui.sh" ) >"$TASKS/$id.ui.log" 2>&1 || { echo FAIL; return; }
  { cat "$PROMPTS/uiqa.md"; echo; echo "# Brief"; cat "$f"; echo; echo "# Screenshots (read each file)"
    ls "$shots"/*.png 2>/dev/null; echo; echo "# UI check output"; tail -n 40 "$TASKS/$id.ui.log"; } >"$pf"
  run_model "$id" uiqa "$(goat_or "$(route_uiqa)" "$M_VIS")" read "$pf" "$TASKS/$id.uiqa.json" "$w" 10m
  [ $? -eq 75 ] && { touch "$TASKS/$id.paused"; echo PAUSED; return; }
  verdict "$TASKS/$id.uiqa.json"
}

verify() { # id wt taskfile workermodel gatelog -> 0 pass, 1 fail (writes fail note), 2 paused
  local id=$1 w=$2 f=$3 wm=$4 gl=$5 type risk v1="" vq=PASS need2=0 t1 t2 qf="$TASKS/$1.uiqa.v"
  type=$(fm_get "$f" type); risk=$(task_risk "$f")
  [ "$type" = ui ] && { visual_qa "$id" "$w" "$f" >"$qf" & }
  if { [ "$type" = bulk ] && [ "$risk" != high ]; } || { [ "$type" = patch ] && [ "$risk" != high ] && [ "$(diff_lines "$w")" -le "$TRIVIAL_LINES" ]; }; then
    fm_set "$f" review batch
  else
    t1=$(goat_or "$(route_t1 "$wm")" "$M_DS")
    v1=$(review "$id" "$w" "$f" "$t1" review1 "$gl")
    [ "$v1" = PAUSED ] && { wait; return 2; }
    [ "$v1" = FAIL ] && { cp "$TASKS/$id.review1.json" "$TASKS/$id.fail.md"; wait; return 1; }
    [ "$v1" = PASS ] || need2=1
  fi
  wait; [ "$type" = ui ] && vq=$(cat "$qf" 2>/dev/null)
  [ "$vq" = PAUSED ] && return 2
  [ "$vq" = FAIL ] && { cat "$TASKS/$id.uiqa.json" "$TASKS/$id.ui.log" >"$TASKS/$id.fail.md" 2>/dev/null; return 1; }
  if [ "$risk" = high ] || { [ "$type" = long ] && [ "$T2_ON_LONG" = yes ]; } || [ "$need2" = 1 ]; then
    t2=$(goat_or "$(route_t2)" "$(route_t2_alt)")
    [ "$(family "$t2")" = "$(family "$wm")" ] && t2=$(goat_or "$(route_t2_peer)" "$(route_t2_alt)")
    local v2; v2=$(review "$id" "$w" "$f" "$t2" review2 "$gl")
    [ "$v2" = PAUSED ] && return 2
    [ "$v2" = PASS ] || { cp "$TASKS/$id.review2.json" "$TASKS/$id.fail.md"; return 1; }
  fi
  return 0
}

judge() { # id taskfile wtA wtB -> prints A or B
  local pf="$TASKS/$1.judge.prompt"
  { cat "$PROMPTS/judge.md"; echo; echo "# Brief"; cat "$2"
    echo "# Candidate A"; git -C "$3" diff "$INTEGRATION_BRANCH"...HEAD | head -c 40000
    echo "# Candidate B"; git -C "$4" diff "$INTEGRATION_BRANCH"...HEAD | head -c 40000; } >"$pf"
  run_model "$1" judge "$(goat_or "$(route_t2)" "$(route_t2_alt)")" none "$pf" "$TASKS/$1.judge.json" "$3" 5m
  grep -o '"pick"[[:space:]]*:[[:space:]]*"[AB]"' "$TASKS/$1.judge.json" | grep -o '[AB]"$' | tr -d '"' | head -1
}

finish() { # id taskfile branch
  local id=$1 f=$2 br=$3
  if [ "$(task_risk "$f")" = high ]; then
    fm_set "$f" status needs-approval; fm_set "$f" branch "$br"; tlog "$f" "waiting for /signoff ($br)"; return
  fi
  merge_branch "$id" "$f" "$br"
}

merge_branch() {
  local id=$1 f=$2 br=$3
  if git -C "$INT_WT" merge -q --no-ff "$br" -m "$id: $(fm_get "$f" title)" >/dev/null 2>&1; then
    fm_set "$f" status merged; tlog "$f" "merged into $INTEGRATION_BRANCH"
    drop_tree "$id-b" "task/$id-b"; drop_tree "$id-tests" "task/$id-tests"; drop_tree "$id" "task/$id"
  else
    git -C "$INT_WT" merge --abort 2>/dev/null
    fm_set "$f" status conflict; tlog "$f" "merge conflict; chief of staff will re-queue"
  fi
}

pause_task() { # taskfile id: every model in the chain was full; try again in 30 minutes
  rm -f "$TASKS/$2.paused"
  fm_set "$1" not_before "$(( $(date +%s) + PAUSE_MINUTES * 60 ))"; fm_set "$1" status queued
  tlog "$1" "all pools full; paused $PAUSE_MINUTES min"
}

process_task() {
  local id=$1 f="$TASKS/$1.md" type risk logic worker w wb="" alt m n=0 pids=() rungs pass=() pick
  [ -f "$f" ] || { echo "no task $id"; exit 1; }
  ensure_integration
  type=$(fm_get "$f" type); risk=$(task_risk "$f"); logic=$(fm_get "$f" logic)
  fm_set "$f" status building; fm_set "$f" pid $$; tlog "$f" "start (profile $PROFILE)"
  rm -f "$TASKS/$id.red" "$TASKS/$id.fail.md.prev" "$TASKS/$id.paused"
  w=$(fresh_tree "$id" "task/$id")
  make_pack "$f" "$w"
  worker=$(route_worker "$type")
  local note="$TASKS/$id.note.md"

  if [ "$(fm_get "$f" force)" = claude ]; then rungs="$CLAUDE_ESC"; else
    # ---- first rung: tests || worker(s), in parallel ----
    [ "$logic" = yes ] && { local tw; tw=$(fresh_tree "$id-tests" "task/$id-tests"); write_tests "$id" "$f" "$tw" "$worker" & pids+=($!); }
    attempt_worker "$id" "$f" "$w" "$worker" "$note" worker & pids+=($!)
    if [ "$risk" = high ] || case " $BEST_OF_2 " in *" $type "*) true ;; *) false ;; esac; then
      alt=$(route_alt "$type"); wb=$(fresh_tree "$id-b" "task/$id-b")
      attempt_worker "$id" "$f" "$wb" "$alt" "$note" workerB & pids+=($!)
    fi
    for p in "${pids[@]}"; do wait "$p"; done
    [ -f "$TASKS/$id.paused" ] && { pause_task "$f" "$id"; return; }
    [ "$(cat "$TASKS/$id.red" 2>/dev/null)" = weak ] && tlog "$f" "warning: tests pass on base code"
    fm_set "$f" status gating
    add_tests "$w" "$id"
    if run_gates "$w" "$id" "$f" "$id.gates.log"; then pass+=(A); logout "$id" gate-pass "$worker"
    else logout "$id" gate-fail "$worker"; fi
    if [ -n "$wb" ]; then add_tests "$wb" "$id"
      if run_gates "$wb" "$id" "$f" "$id.gatesB.log"; then pass+=(B); logout "$id" gate-pass "$alt"
      else logout "$id" gate-fail "$alt"; fi
    fi
    pick=""
    if [ "${#pass[@]}" = 2 ]; then
      if [ "$USE_JUDGE" = yes ] || [ "$risk" = high ]; then pick=$(judge "$id" "$f" "$w" "$wb"); pick=${pick:-A}
      else pick=A; fi
    elif [ "${#pass[@]}" = 1 ]; then pick=${pass[0]}; fi
    if [ -n "$wb" ]; then   # record who won the best-of-2, for stats.sh
      case "$pick" in
        A) logout "$id" b2win "$worker"; logout "$id" b2loss "$alt" ;;
        B) logout "$id" b2win "$alt"; logout "$id" b2loss "$worker" ;;
        *) logout "$id" b2loss "$worker"; logout "$id" b2loss "$alt" ;;
      esac
    fi
    if [ -n "$pick" ]; then
      fm_set "$f" status reviewing
      local vr
      if [ "$pick" = B ]; then verify "$id" "$wb" "$f" "$alt" "$id.gatesB.log"; vr=$?
        [ $vr = 0 ] && { finish "$id" "$f" "task/$id-b"; return; }
      else verify "$id" "$w" "$f" "$worker" "$id.gates.log"; vr=$?
        [ $vr = 0 ] && { finish "$id" "$f" "task/$id"; return; }
      fi
      [ $vr = 2 ] && { pause_task "$f" "$id"; return; }
    else
      tail -n 80 "$TASKS/$id.gates.log" >"$TASKS/$id.fail.md"
    fi
    tlog "$f" "first attempt failed ($worker)"
    rungs=$(route_ladder "$type")
  fi

  # ---- retry ladder ----
  for m in $rungs; do
    n=$((n+1))
    if [ "$m" = "$CLAUDE_ESC" ] && ! claude_ok; then
      fm_set "$f" status needs-claude; tlog "$f" "Claude daily cap reached; resumes tomorrow"; return
    fi
    is_goat "$m" && ! goat_ok && { tlog "$f" "skip $m (GOAT daily cap)"; continue; }
    fm_set "$f" status building; fm_set "$f" attempt "$n"
    w=$(fresh_tree "$id" "task/$id"); add_tests "$w" "$id"
    attempt_worker "$id" "$f" "$w" "$m" "$TASKS/$id.fail.md" "retry$n"
    [ -f "$TASKS/$id.paused" ] && { pause_task "$f" "$id"; return; }
    fm_set "$f" status gating
    if run_gates "$w" "$id" "$f" "$id.gates.log"; then
      logout "$id" gate-pass "$m"
      fm_set "$f" status reviewing
      verify "$id" "$w" "$f" "$m" "$id.gates.log"; local vr2=$?
      [ $vr2 = 0 ] && { finish "$id" "$f" "task/$id"; return; }
      [ $vr2 = 2 ] && { pause_task "$f" "$id"; return; }
    else
      logout "$id" gate-fail "$m"
      tail -n 80 "$TASKS/$id.gates.log" >"$TASKS/$id.fail.md"
    fi
    tlog "$f" "retry $n failed ($m)"
  done
  fm_set "$f" status stuck; tlog "$f" "ladder exhausted"
}

cmd_run() {
  lock scheduler || exit 0
  trap 'unlock scheduler' EXIT
  ensure_integration
  local f st id running=0 busy="" m dep ok nb tp
  for f in $(task_files); do
    st=$(fm_get "$f" status)
    if [ "$st" = needs-claude ] && claude_ok; then   # new day, cap reset: resume straight at Claude
      fm_set "$f" force claude; fm_set "$f" status queued; tlog "$f" "resuming with Claude"; continue; fi
    case "$st" in claimed|building|gating|reviewing)
      if pid_alive "$(fm_get "$f" pid)"; then running=$((running+1)); busy="$busy $(fm_get "$f" model)"
      else fm_set "$f" status queued; tlog "$f" "recovered after crash"; fi ;;
    esac
  done
  for f in $(task_files); do
    [ "$running" -ge "$MAX_PARALLEL" ] && break
    [ "$(fm_get "$f" status)" = queued ] || continue
    nb=$(fm_get "$f" not_before); [ -n "$nb" ] && [ "$(date +%s)" -lt "$nb" ] && continue
    id=$(fm_get "$f" id)
    case "$(fm_get "$f" type)" in bulk|long) [ "$OFFPEAK_ONLY" = yes ] && ! in_offpeak && continue ;; esac
    ok=1; for dep in $(fm_get "$f" after | tr ',' ' '); do
      [ "$(fm_get "$TASKS/$dep.md" status 2>/dev/null)" = merged ] || ok=0; done
    [ "$ok" = 1 ] || continue
    m=$(route_worker "$(fm_get "$f" type)")
    case " $busy " in *" $m "*) continue ;; esac
    fm_set "$f" status claimed; fm_set "$f" model "$m"
    tp=$(fm_get "$f" profile)
    PROFILE=${tp:-$REPO_PROFILE} nohup "$SELF" task "$id" >"$LOGS/$id.log" 2>&1 &
    fm_set "$f" pid $!
    running=$((running+1)); busy="$busy $m"
  done
}

cmd_batch() {
  ensure_integration
  local f id c pf ids=""; pf="$LOGS/batch-$(today).prompt"
  { cat "$PROMPTS/review1.md"; echo; echo "# Batch review: several small tasks. Judge each diff against its brief."; } >"$pf"
  for f in $(task_files); do
    [ "$(fm_get "$f" review)" = batch ] && [ "$(fm_get "$f" status)" = merged ] || continue
    id=$(fm_get "$f" id); c=$(git -C "$INT_WT" log --merges --grep "^$id:" -1 --format=%H)
    [ -n "$c" ] || continue
    { echo "## $id"; body "$f" | head -30; git -C "$INT_WT" diff "$c^1" "$c" | head -c 15000; } >>"$pf"
    ids="$ids $id"
  done
  [ -n "$ids" ] || { echo "nothing to batch-review"; return; }
  run_model batch review1 "$(route_t1 "$(route_worker bulk)")" none "$pf" "$LOGS/batch-$(today).json" "$INT_WT" 10m
  for id in $ids; do fm_set "$TASKS/$id.md" review batch-done; done
  echo "verdict: $(verdict "$LOGS/batch-$(today).json")  -> $LOGS/batch-$(today).json"
}

cmd_status() {
  if [ "${1:-}" = --json ]; then
    command -v jq >/dev/null || { echo "status --json needs jq"; exit 1; }
    local f id
    for f in $(task_files); do id=$(fm_get "$f" id)
      jq -cn --arg id "$id" --arg title "$(fm_get "$f" title)" --arg goal "$(fm_get "$f" goal)" \
        --arg status "$(fm_get "$f" status)" --arg type "$(fm_get "$f" type)" --arg risk "$(task_risk "$f")" \
        --arg attempt "$(fm_get "$f" attempt)" --arg review "$(fm_get "$f" review)" \
        --arg branch "$(fm_get "$f" branch)" --arg v1 "$(verdict "$TASKS/$id.review1.json")" \
        --arg v2 "$(verdict "$TASKS/$id.review2.json")" --arg last "$(awk '/^- [0-9]{4}-/' "$f" | tail -1 | cut -c3-)" \
        '{id:$id,title:$title,goal:$goal,status:$status,type:$type,risk:$risk,attempt:$attempt,review:$review,
          branch:$branch,review1:$v1,review2:$v2,last_log:$last}'
    done
    return
  fi
  echo "Profile: $PROFILE"
  printf '%-7s %-7s %-15s %-8s %-5s %-4s %s\n' ID GOAL STATUS TYPE RISK TRY TITLE
  for f in $(task_files); do
    printf '%-7s %-7s %-15s %-8s %-5s %-4s %s\n' "$(fm_get "$f" id)" "$(fm_get "$f" goal)" "$(fm_get "$f" status)" \
      "$(fm_get "$f" type)" "$(fm_get "$f" risk)" "$(fm_get "$f" attempt)" "$(fm_get "$f" title)"
  done
}

# A bounded digest of one task, so the orchestrator reads one small thing instead of raw logs.
cmd_show() {
  local id=$1 f="$TASKS/$1.md" br j
  [ -f "$f" ] || { echo "no task $id"; exit 1; }
  echo "# $id"; cat "$f" | head -c 6000; echo
  for j in review1 review2 judge uiqa; do
    [ -s "$TASKS/$id.$j.json" ] && { echo "## $j"; json_block "$TASKS/$id.$j.json" | head -c 2500; echo; }
  done
  [ -s "$TASKS/$id.fail.md" ] && { echo "## Last failure (tail)"; tail -n 40 "$TASKS/$id.fail.md"; }
  [ -s "$TASKS/$id.gates.log" ] && { echo "## Gates (tail)"; tail -n 25 "$TASKS/$id.gates.log"; }
  br=$(fm_get "$f" branch); [ -n "$br" ] || br="task/$id"
  git -C "$ROOT" show-ref --verify --quiet "refs/heads/$br" &&
    { echo "## Diffstat ($INTEGRATION_BRANCH...$br)"; git -C "$ROOT" diff --stat "$INTEGRATION_BRANCH...$br" | tail -n 30; }
  true
}

# Orchestrator actions. Each one leaves the task in a state the scheduler understands.
need_task() { [ -f "$TASKS/$1.md" ] || { echo "no task $1"; exit 1; }
  case "$(fm_get "$TASKS/$1.md" status)" in claimed|building|gating|reviewing)
    pid_alive "$(fm_get "$TASKS/$1.md" pid)" && { echo "$1 is running; leave it alone"; exit 1; } ;; esac; }
cmd_requeue() { local f="$TASKS/$1.md"; need_task "$1"
  [ -n "${2:-}" ] && echo "Hint from the orchestrator: $2" >"$TASKS/$1.note.md"
  fm_set "$f" attempt 0; fm_set "$f" force ""; fm_set "$f" not_before ""; fm_set "$f" status queued
  tlog "$f" "orchestrator: requeued. ${2:-}"; echo "$1 queued"; }
cmd_escalate() { local f="$TASKS/$1.md"; need_task "$1"
  [ -n "${2:-}" ] && echo "Hint from the orchestrator: $2" >"$TASKS/$1.note.md"
  [ -s "$TASKS/$1.note.md" ] && cat "$TASKS/$1.note.md" >>"$TASKS/$1.fail.md"
  fm_set "$f" force claude; fm_set "$f" not_before ""; fm_set "$f" status queued
  tlog "$f" "orchestrator: escalated to $CLAUDE_ESC. ${2:-}"; echo "$1 queued for $CLAUDE_ESC"; }
cmd_park() { local f="$TASKS/$1.md"; need_task "$1"
  fm_set "$f" status needs-you; tlog "$f" "orchestrator: needs you. ${2:-}"; echo "$1 parked for you"; }
cmd_drop() { local f="$TASKS/$1.md"; need_task "$1"
  fm_set "$f" status dropped; tlog "$f" "orchestrator: dropped. ${2:-}"
  drop_tree "$1-b" "task/$1-b"; drop_tree "$1-tests" "task/$1-tests"; drop_tree "$1" "task/$1"; echo "$1 dropped"; }

case "${1:-run}" in
  run) cmd_run ;;
  task) process_task "$2" ;;
  approve) ensure_integration; f="$TASKS/$2.md"
    [ "$(fm_get "$f" status)" = needs-approval ] || { echo "$2 is not waiting for approval"; exit 1; }
    merge_branch "$2" "$f" "$(fm_get "$f" branch)" ;;
  reject) f="$TASKS/$2.md"; echo "Sign-off (Claude) rejected the last attempt: ${3:-no reason given}" >"$TASKS/$2.note.md"
    fm_set "$f" status queued; tlog "$f" "rejected at signoff" ;;
  batch) cmd_batch ;;
  status) cmd_status "${2:-}" ;;
  show) cmd_show "${2:?usage: runner.sh show T-012}" ;;
  requeue) cmd_requeue "${2:?usage: runner.sh requeue T-012 \"hint\"}" "${3:-}" ;;
  escalate) cmd_escalate "${2:?usage: runner.sh escalate T-012 \"hint\"}" "${3:-}" ;;
  park) cmd_park "${2:?usage: runner.sh park T-012 \"why\"}" "${3:-}" ;;
  drop) cmd_drop "${2:?usage: runner.sh drop T-012 \"why\"}" "${3:-}" ;;
  *) sed -n '2,15p' "$0" ;;
esac
