#!/usr/bin/env bash
# cos.sh: cheap-model helper jobs (route_cos in routing.sh).
#   cos.sh pack "goal"   context summary for planning     -> .agents/context.md (orchestrate.sh runs this)
#   cos.sh map           refresh REPO_MAP.md
#   cos.sh status        write STATUS.md
#   cos.sh conflicts     re-queue merge conflicts (no model; orchestrate.sh tick runs it)
#   cos.sh daily         status note (loop.sh runs it once a day)
# Stuck tasks go to the orchestrator (orchestrate.sh), not to these jobs.
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
P="$AG/prompts"
cos_model() { route_cos; }

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
  awk -F, -v d="$(today)" -v m="$(date +%Y-%m)" '$4 ~ /^(gate-|b2|flaky)/ {next} { if(index($1,m)==1){mo[$5]++; if($6!=0) fl[$5]++}
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

cmd_conflicts() {   # base moved underneath these: just redo them on the new base
  local f
  for f in $(task_files); do
    [ "$(fm_get "$f" status)" = conflict ] || continue
    echo "The integration branch changed; re-implement on the current code." >"$TASKS/$(fm_get "$f" id).note.md"
    fm_set "$f" status queued; tlog "$f" "requeued after merge conflict"
  done
}

case "${1:-}" in
  pack) cmd_pack "${2:-}" ;;
  map) cmd_map ;;
  status) cmd_status ;;
  conflicts) cmd_conflicts ;;
  daily) cmd_conflicts; cmd_status ;;
  *) sed -n '2,9p' "$0" ;;
esac
