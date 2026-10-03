#!/usr/bin/env bash
# orchestrate.sh: Claude as the orchestrator, woken only when a decision is needed.
#   orchestrate.sh goal "text" [profile]   queue a milestone goal (Claude plans it on the next tick)
#   orchestrate.sh tick                    cheap checks; wakes Claude if events are waiting (loop.sh/cron)
#   orchestrate.sh events                  list waiting events without waking anyone
#   orchestrate.sh brief                   print what Claude would be given (also used by /orchestrate)
#   orchestrate.sh wake                    wake Claude now, ignoring the gap (still respects the daily cap)
#   orchestrate.sh goals                   list goals and their status
#   orchestrate.sh planned G-001           used by Claude after writing a goal's task files
#   orchestrate.sh done G-001 "summary"    used by Claude to close a milestone after wrap-up
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
GOALS="$AG/goals"; OD="$AG/orch"; mkdir -p "$GOALS" "$OD"
OLOG="$LOGS/orchestrator.log"
olog() { echo "$(now) $*" >>"$OLOG"; }

goal_files() { local f; for f in "$GOALS"/G-*.md; do [[ $(basename "$f") =~ ^G-[0-9]+\.md$ ]] && echo "$f"; done | sort; }
goal_text() { body "$1" | sed -n '/^## Goal/,/^## /p' | sed '1d;/^## /d'; }
goal_tasks() { local f; for f in $(task_files); do [ "$(fm_get "$f" goal)" = "$1" ] && echo "$f"; done; }
orch_calls_today() { local n; n=$(grep "^$(today)," "$LOGS/runs.csv" 2>/dev/null | grep -c ',orchestrator,'); echo "${n:-0}"; }

cmd_goal() {
  [ -n "${1:-}" ] || { echo 'usage: orchestrate.sh goal "milestone goal" [default|risky|fast]'; exit 1; }
  git -C "$ROOT" ls-files --error-unmatch "$AG/runner.sh" >/dev/null 2>&1 || {
    echo "Commit the kit first, so the agents branch starts from it:"
    echo "  git add .agents .claude CLAUDE.md AGENTS.md NOTES.md .gitignore && git commit -m \"agent pipeline\""; exit 1; }
  [ "$ORCHESTRATOR" = claude ] || {
    echo "ORCHESTRATOR=$ORCHESTRATOR: nothing would plan this goal. Run /plan in Claude Code instead,"
    echo "or restart the loop with ORCHESTRATOR=claude."; exit 1; }
  local n id f
  n=$(goal_files | sed 's/.*G-0*//; s/\.md$//' | sort -n | tail -1); id=$(printf 'G-%03d' $(( ${n:-0} + 1 )))
  f="$GOALS/$id.md"
  printf -- '---\nid: %s\ntitle: %s\nstatus: new\nprofile: %s\ncreated: %s\n---\n## Goal\n%s\n\n## Log\n' \
    "$id" "$(printf '%s' "$1" | tr '\n' ' ' | cut -c1-80)" "${2:-}" "$(now)" "$1" >"$f"
  echo "queued $id. The next tick packs context (Muse) and wakes Claude to plan it."
}

cmd_goals() {
  local f; printf '%-7s %-10s %-6s %s\n' GOAL STATUS TASKS TITLE
  for f in $(goal_files); do
    printf '%-7s %-10s %-6s %s\n' "$(fm_get "$f" id)" "$(fm_get "$f" status)" \
      "$(goal_tasks "$(fm_get "$f" id)" | grep -c .)" "$(fm_get "$f" title)"
  done
}

cmd_planned() {
  local f="$GOALS/${1:?usage: orchestrate.sh planned G-001}.md"
  [ -f "$f" ] || { echo "no goal $1"; exit 1; }
  [ -n "$(goal_tasks "$1")" ] || { echo "no task file has 'goal: $1' yet; write the tasks first"; exit 1; }
  fm_set "$f" status planned; tlog "$f" "planned: $(goal_tasks "$1" | xargs -n1 basename | sed 's/\.md$//' | tr '\n' ' ')"
  echo "$1 planned; the runner picks its tasks up on the next run."
}

cmd_done() {
  local f="$GOALS/${1:?usage: orchestrate.sh done G-001 \"summary\"}.md"
  [ -f "$f" ] || { echo "no goal $1"; exit 1; }
  fm_set "$f" status "done"; tlog "$f" "done. ${2:-}"; olog "$1 done: ${2:-}"
  echo "$1 closed. The owner merges $INTEGRATION_BRANCH into $MAIN_BRANCH."
}

# ---------- deterministic housekeeping (no model, or cheap models only) ----------
housekeeping() {
  local f id st g open
  # Merge conflicts: the base moved; just redo the task on the new base.
  "$AG/cos.sh" conflicts
  # Stuck too often after orchestrator triage: stop spending Claude on it.
  for f in $(task_files); do
    [ "$(fm_get "$f" status)" = stuck ] || continue
    [ "${ORCH_MAX_TRIAGE:-2}" -gt 0 ] && [ "$(fm_get "$f" orch_triage)" -ge "$ORCH_MAX_TRIAGE" ] 2>/dev/null &&
      { fm_set "$f" status needs-you; tlog "$f" "stuck after $ORCH_MAX_TRIAGE orchestrator triages: needs you"; }
  done
  # One goal at a time gets a context pack (context.md is shared), then waits for Claude to plan it.
  local waiting=0
  for g in $(goal_files); do [ "$(fm_get "$g" status)" = packed ] && waiting=1; done
  if [ $waiting = 0 ]; then
    for g in $(goal_files); do
      [ "$(fm_get "$g" status)" = new ] || continue
      if "$AG/cos.sh" pack "$(goal_text "$g")" >>"$OLOG" 2>&1; then tlog "$g" "context packed"
      else rm -f "$AG/context.md"; tlog "$g" "context pack failed; Claude plans from REPO_MAP.md"; fi
      fm_set "$g" status packed
      break
    done
  fi
  # A planned goal whose tasks are all merged or dropped is ready to wrap up. Run the cheap
  # end-of-milestone batch review first so Claude only reads its verdict.
  for g in $(goal_files); do
    [ "$(fm_get "$g" status)" = planned ] || continue
    id=$(fm_get "$g" id); open=0
    [ -n "$(goal_tasks "$id")" ] || continue
    for f in $(goal_tasks "$id"); do st=$(fm_get "$f" status); case "$st" in merged|dropped) ;; *) open=1 ;; esac; done
    [ $open = 0 ] || continue
    local bo; bo=$("$AG/runner.sh" batch 2>&1); echo "$bo" >>"$OLOG"
    fm_set "$g" status wrapup; tlog "$g" "all tasks merged; batch review: $(echo "$bo" | tail -n 1)"
  done
}

# ---------- events: one line each, "<kind> <id>" ----------
cmd_events() {
  local f
  for f in $(goal_files); do case "$(fm_get "$f" status)" in
    packed) echo "plan $(fm_get "$f" id)" ;;
    wrapup) echo "wrapup $(fm_get "$f" id)" ;;
  esac; done
  for f in $(task_files); do case "$(fm_get "$f" status)" in
    stuck) echo "triage $(fm_get "$f" id)" ;;
    needs-approval) [ "$ORCH_AUTO_SIGNOFF" = yes ] && echo "signoff $(fm_get "$f" id)" ;;
  esac; done
  true
}

cmd_brief() {
  local ev kind id f
  ev=$(cmd_events)
  echo "# Orchestrator brief $(now)"
  echo "Integration branch: $INTEGRATION_BRANCH. Main branch: $MAIN_BRANCH (never merge into it)."
  echo "Profile: $PROFILE. Orchestrator wakes today: $(orch_calls_today)/$CLAUDE_ORCH_DAILY_CAP."
  echo "Claude retries today: $(count_today "$CLAUDE_ESC")/$CLAUDE_DAILY_CAP. GOAT calls today: $(goat_today)/$GOAT_DAILY_RUN_CAP."
  echo; echo "## Events to resolve"
  [ -n "$ev" ] && echo "$ev" | sed 's/^/- /' || echo "- none"
  echo; echo "## All tasks"; echo '```'; "$AG/runner.sh" status; echo '```'
  echo; echo "## Goals"; echo '```'; cmd_goals; echo '```'
  while read -r kind id; do
    [ -n "${kind:-}" ] || continue
    echo; echo "---"; echo "## Event: $kind $id"
    case "$kind" in
      plan)   f="$GOALS/$id.md"; cat "$f"
              if [ -s "$AG/context.md" ]; then echo; echo "### Context pack (.agents/context.md)"; head -c 12000 "$AG/context.md"
              else echo "(no context pack; read REPO_MAP.md)"; fi ;;
      wrapup) f="$GOALS/$id.md"; cat "$f"; echo; echo "### Tasks in this goal"
              for f in $(goal_tasks "$id"); do echo "- $(fm_get "$f" id) $(fm_get "$f" status) $(fm_get "$f" review): $(fm_get "$f" title)"; done
              # The goal log says what the batch review did: "nothing to batch-review" (every task had its
              # own review) or "verdict: X -> file". Show that file, not whatever batch ran last.
              local bj; bj=$(grep -o 'batch review: verdict: .* -> .*\.json' "$GOALS/$id.md" | tail -1 | sed 's/.* -> //')
              echo; echo "### Batch review"
              if [ -n "$bj" ] && [ -s "$bj" ]; then json_block "$bj" | head -c 4000
              else grep -o 'batch review: .*' "$GOALS/$id.md" | tail -1 || echo "(not recorded)"; fi ;;
      triage|signoff) "$AG/runner.sh" show "$id" | head -c 9000 ;;
    esac
  done <<<"$ev"
  echo
}

# ---------- waking Claude ----------
cmd_wake() { # [force]
  lock orchestrator || { echo "orchestrator already running"; return 0; }
  _wake "$@"; local r=$?; unlock orchestrator; return $r
}
_wake() {
  local force=${1:-} ev sig last model kinds pf out rc t0 bu id tf n
  ev=$(cmd_events)
  [ -n "$ev" ] || { echo "no events"; return 0; }
  bu=$(cat "$OD/backoff_until" 2>/dev/null || echo 0)
  [ "$(date +%s)" -lt "${bu:-0}" ] && { echo "backing off after a Claude usage limit"; return 0; }
  if [ "$(orch_calls_today)" -ge "$CLAUDE_ORCH_DAILY_CAP" ]; then
    [ "$(cat "$OD/cap_noted" 2>/dev/null)" = "$(today)" ] ||
      { olog "daily orchestrator cap ($CLAUDE_ORCH_DAILY_CAP) reached; events wait until tomorrow"; today >"$OD/cap_noted"; }
    echo "orchestrator cap reached"; return 0
  fi
  # The date is part of the signature, so an event Claude left unresolved gets one more look per day.
  # Goal creation times are in it too, so a new goal that reuses a deleted goal's id still counts as new.
  sig=$(printf '%s\n%s\n%s' "$(today)" "$ev" "$(for id in $(echo "$ev" | awk '$1=="plan"||$1=="wrapup"{print $2}'); do
          fm_get "$GOALS/$id.md" created; done)" | cksum | cut -d' ' -f1); last=$(cat "$OD/last_sig" 2>/dev/null)
  if [ "$force" != force ]; then
    # Same unresolved events as the last successful wake: Claude already saw them. Don't pay twice.
    [ "$sig" = "$last" ] && { echo "events unchanged since last wake"; return 0; }
    # Planning skips the gap, unless the last wake failed (then wait, don't retry every tick).
    if ! echo "$ev" | grep -q '^plan ' || [ -f "$OD/last_failed" ]; then
      local lw; lw=$(cat "$OD/last_wake" 2>/dev/null || echo 0)
      [ $(( $(date +%s) - lw )) -lt $(( ORCH_MIN_GAP_MIN * 60 )) ] && { echo "within ORCH_MIN_GAP_MIN; batching"; return 0; }
    fi
  fi
  # Count triage attempts so a task can't loop through Claude forever.
  for id in $(echo "$ev" | awk '$1=="triage"{print $2}'); do
    tf="$TASKS/$id.md"; n=$(fm_get "$tf" orch_triage); fm_set "$tf" orch_triage $(( ${n:-0} + 1 ))
  done
  kinds=$(echo "$ev" | awk '{print $1}' | sort -u | tr '\n' ' ')
  case " $kinds " in *" plan "*|*" triage "*|*" signoff "*) model=$ORCH_MODEL ;; *) model=$ORCH_LIGHT_MODEL ;; esac
  pf="$OD/wake.prompt"; out="$OD/wake-$(date +%Y%m%d-%H%M%S).out"
  { cat "$AG/prompts/orchestrator.md"; echo; cmd_brief; } >"$pf"
  olog "wake ($model): $(echo "$ev" | tr '\n' ';')"
  date +%s >"$OD/last_wake"; t0=$(date +%s)
  # Official Claude Code CLI on your Pro login, in the main checkout, with a pinned tool list.
  # Anything not in ORCH_ALLOWED_TOOLS is refused in print mode, so it can't edit code or merge.
  ( cd "$ROOT" && env -u ANTHROPIC_API_KEY "$TIMEOUT" "$ORCH_TIMEOUT" claude \
      -p "You are the pipeline orchestrator. Follow the instructions and brief provided on stdin." \
      --model "$model" --allowedTools "$ORCH_ALLOWED_TOOLS" --disallowedTools "$ORCH_DISALLOWED_TOOLS" \
      <"$pf" ) >"$out" 2>"$out.err"
  rc=$?
  if [ $rc -ne 0 ] && grep -qiE "$CLAUDE_LIMIT_PATTERN" "$out" "$out.err" 2>/dev/null; then
    # Refused by the usage limit: not counted against CLAUDE_ORCH_DAILY_CAP.
    logrun orch orchestrator-limit "ORCH_$(echo "$model" | tr '[:lower:]' '[:upper:]')" "$rc" "$(( $(date +%s)-t0 ))"
    echo $(( $(date +%s) + ORCH_BACKOFF_MIN * 60 )) >"$OD/backoff_until"
    olog "Claude usage limit hit; no wakes for $ORCH_BACKOFF_MIN min"; return 0
  fi
  logrun orch orchestrator "ORCH_$(echo "$model" | tr '[:lower:]' '[:upper:]')" "$rc" "$(( $(date +%s)-t0 ))"
  if [ $rc -eq 0 ]; then echo "$sig" >"$OD/last_sig"; rm -f "$OD/last_failed"
  else touch "$OD/last_failed"; olog "wake failed (rc $rc), see $out.err"; fi
  { echo "--- $(now) reply:"; tail -n 40 "$out"; } >>"$OLOG"
  # Anything Claude left unresolved is still an event; the signature check stops a same-state rewake.
  echo "wake done (rc $rc); reply in $out"
}

cmd_tick() {
  [ "$ORCHESTRATOR" = claude ] || { echo "ORCHESTRATOR=$ORCHESTRATOR: nothing to do"; return 0; }
  housekeeping
  cmd_wake
}

case "${1:-}" in
  goal) cmd_goal "${2:-}" "${3:-}" ;;
  goals) cmd_goals ;;
  tick) cmd_tick ;;
  events) cmd_events ;;
  planned) cmd_planned "${2:-}" ;;
  brief) cmd_brief ;;
  wake) housekeeping; cmd_wake force ;;
  done) cmd_done "${2:-}" "${3:-}" ;;
  *) sed -n '2,11p' "$0" ;;
esac
