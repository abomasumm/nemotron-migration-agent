#!/usr/bin/env bash
# cos.sh: cheap-model helper jobs (Muse Spark 1.3; DeepSeek if ALLOW_TRAINING=no).
#   cos.sh pack "goal"   context summary for planning     -> .agents/context.md (orchestrate.sh runs this)
#   cos.sh map           refresh REPO_MAP.md
#   cos.sh status        write STATUS.md
#   cos.sh triage        re-queue merge conflicts; with ORCHESTRATOR=cos also triage stuck tasks
#   cos.sh daily         status + triage (run from cron once a day)
# With ORCHESTRATOR=claude (the default) stuck tasks go to Claude via orchestrate.sh, not to Muse.
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
P="$AG/prompts"
cos_model() { goat_or "$(route_cos)" "$M_DS"; }

cmd_pack() {
  [ -n "${1:-}" ] || { echo 'usage: cos.sh pack "milestone goal"'; exit 1; }
  local pf="$LOGS/pack.prompt" out="$LOGS/pack.out"
  { cat "$P/cos-pack.md"; echo; echo "# Milestone goal"; echo "$1"; echo
    [ -f "$ROOT/REPO_MAP.md" ] && { echo "# Repo map"; cat "$ROOT/REPO_MAP.md"; }
    [ -f "$ROOT/NOTES.md" ] && { echo "# Known pitfalls"; tail -n 40 "$ROOT/NOTES.md"; }; } >"$pf"
  run_model pack cos-pack "$(cos_model)" "$READ_TOOLS" "$pf" "$out" "$(ro_tree)" 15m &&
    { { echo "<!-- goal: $1 | $(now) -->"; cat "$out"; } >"$AG/context.md"; echo "wrote .agents/context.md"; } ||
    { echo "pack failed, see $out.err"; exit 1; }
}

cmd_map() {
  local out="$LOGS/map.out"
  run_model map mapper "$(route_mapper)" "$READ_TOOLS" "$P/mapper.md" "$out" "$(ro_tree)" 15m && [ -s "$out" ] &&
    { cp "$out" "$ROOT/REPO_MAP.md"; echo "wrote REPO_MAP.md (review it before trusting it)"; } ||
    { echo "map failed, see $out.err"; exit 1; }
}

usage_table() {
  echo "| model | runs today | runs this month | failures this month |"; echo "|---|---|---|---|"
  awk -F, -v d="$(today)" -v m="$(date +%Y-%m)" '$4 ~ /^(gate-|b2)/ {next} { if(index($1,m)==1){mo[$5]++; if($6!=0) fl[$5]++}
    if($1==d) td[$5]++ } END{ for(k in mo) printf "| %s | %d | %d | %d |\n", k, td[k], mo[k], fl[k] }' \
    "$LOGS/runs.csv" 2>/dev/null | sort
}

cmd_status() {
  local pf="$LOGS/status.prompt" out="$LOGS/status.out" f
  { cat "$P/cos-status.md"; echo; echo "# Tasks"; "$AG/runner.sh" status; echo
    echo "# Logs of unfinished tasks"
    for f in $(task_files); do
      [ "$(fm_get "$f" status)" = merged ] && continue
      echo "## $(fm_get "$f" id)"; awk '/^- [0-9]{4}-/' "$f" | tail -5; done
    echo; echo "# Usage"; usage_table; } >"$pf"
  run_model status cos-status "$(cos_model)" none "$pf" "$out" "$ROOT" 5m
  { echo "# Status $(now)"; echo; cat "$out"; echo; echo "## Tasks"; echo '```'; "$AG/runner.sh" status; echo '```'
    echo; echo "## Usage"; usage_table; } >"$AG/STATUS.md"
  echo "wrote .agents/STATUS.md"
}

replace_body() { # taskfile newbodyfile
  local tmp; tmp=$(mktemp)
  awk 'NR==1&&$0=="---"{f=1;print;next} f&&$0=="---"{print;exit} {print}' "$1" >"$tmp"
  cat "$2" >>"$tmp"; mv "$tmp" "$1"
}

cmd_triage() {
  local f id st pf out json action reason
  command -v jq >/dev/null || { echo "triage needs jq"; exit 1; }
  for f in $(task_files); do
    st=$(fm_get "$f" status); id=$(fm_get "$f" id)
    if [ "$st" = conflict ]; then   # base moved underneath it: just redo it on the new base
      echo "The integration branch changed; re-implement on the current code." >"$TASKS/$id.note.md"
      fm_set "$f" status queued; tlog "$f" "requeued after merge conflict"; continue
    fi
    [ "$st" = stuck ] || continue
    [ "$ORCHESTRATOR" = claude ] && continue   # Claude triages these (orchestrate.sh)
    if [ "$(fm_get "$f" triaged)" = yes ]; then fm_set "$f" status needs-you; tlog "$f" "stuck twice: needs you"; continue; fi
    pf="$LOGS/$id.triage.prompt"; out="$LOGS/$id.triage.out"
    { cat "$P/cos-triage.md"; echo; echo "# Task"; cat "$f"; echo; echo "# Last failure"
      tail -n 80 "$TASKS/$id.fail.md" 2>/dev/null; } >"$pf"
    run_model "$id" cos-triage "$(cos_model)" none "$pf" "$out" "$ROOT" 5m
    json=$(json_block "$out"); action=$(echo "$json" | jq -r '.action // "human"' 2>/dev/null || echo human)
    reason=$(echo "$json" | jq -r '.reason // ""' 2>/dev/null)
    fm_set "$f" triaged yes; fm_set "$f" attempt 0
    case "$action" in
      rewrite) echo "$json" | jq -r '.brief' >"$LOGS/$id.newbody" && [ -s "$LOGS/$id.newbody" ] &&
                 { replace_body "$f" "$LOGS/$id.newbody"; fm_set "$f" status queued; } || fm_set "$f" status needs-you ;;
      requeue) echo "Hint from triage: $reason" >"$TASKS/$id.note.md"; fm_set "$f" status queued ;;
      claude)  fm_set "$f" force claude; fm_set "$f" status queued ;;
      *)       fm_set "$f" status needs-you ;;
    esac
    tlog "$f" "triage: $action. $reason"
  done
}

case "${1:-}" in
  pack) cmd_pack "${2:-}" ;;
  map) cmd_map ;;
  status) cmd_status ;;
  triage) cmd_triage ;;
  daily) cmd_triage; cmd_status ;;
  *) sed -n '2,8p' "$0" ;;
esac
