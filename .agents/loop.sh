#!/usr/bin/env bash
# loop.sh: run the pipeline. Start it in a tmux/screen window:
#   tmux new -s agents '.agents/loop.sh'
# Every LOOP_SLEEP seconds (profile-dependent): the scheduler starts queued tasks, then the orchestrator
# tick wakes the orchestrator if a decision is waiting. Once a day after COS_HOUR: status note.
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
COS_HOUR=${COS_HOUR:-8}; last=""
echo "$(now) loop started in $ROOT (orchestrator: $ORCH_MODEL)"
while true; do
  "$AG/runner.sh" run >>"$LOGS/cron.log" 2>&1
  "$AG/orchestrate.sh" tick >>"$LOGS/cron.log" 2>&1
  if [ "$((10#$(date +%H)))" -ge "$COS_HOUR" ] && [ "$last" != "$(today)" ]; then
    "$AG/cos.sh" daily >>"$LOGS/cron.log" 2>&1; last=$(today); echo "$(now) daily status written"
  fi
  sleep "$LOOP_SLEEP"
done
