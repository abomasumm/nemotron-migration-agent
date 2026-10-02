#!/usr/bin/env bash
# loop.sh: run the pipeline without cron. Start it in a tmux/screen window:
#   tmux new -s agents '.agents/loop.sh'
# Every LOOP_SLEEP seconds (profile-dependent): the scheduler starts queued tasks, then the orchestrator
# tick wakes Claude if a decision is waiting. Once a day after COS_HOUR: status note (and, with
# ORCHESTRATOR=cos, Muse triage).
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
COS_HOUR=${COS_HOUR:-8}; last=""
echo "$(now) loop started in $ROOT (orchestrator: $ORCHESTRATOR)"
if [ "$ORCHESTRATOR" != claude ]; then
  for g in "$AG"/goals/G-*.md; do
    [ -f "$g" ] || continue
    case "$(fm_get "$g" status)" in new|packed|wrapup)
      echo "warning: $(basename "$g" .md) is '$(fm_get "$g" status)' and nothing moves it in $ORCHESTRATOR mode;" \
           "run /plan or /signoff by hand, or restart with ORCHESTRATOR=claude" ;;
    esac
  done
fi
while true; do
  "$AG/runner.sh" run >>"$LOGS/cron.log" 2>&1
  if [ "$ORCHESTRATOR" = claude ]; then "$AG/orchestrate.sh" tick >>"$LOGS/cron.log" 2>&1
  else "$AG/cos.sh" conflicts >>"$LOGS/cron.log" 2>&1; fi
  if [ "$((10#$(date +%H)))" -ge "$COS_HOUR" ] && [ "$last" != "$(today)" ]; then
    "$AG/cos.sh" daily >>"$LOGS/cron.log" 2>&1; last=$(today); echo "$(now) daily status written"
  fi
  sleep "$LOOP_SLEEP"
done
