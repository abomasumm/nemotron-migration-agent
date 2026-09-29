#!/usr/bin/env bash
# doctor.sh: check the whole setup from the repo root.
#   .agents/doctor.sh            tools, repo, 9router, Claude login basics
#   .agents/doctor.sh --models   also send "reply ready" to every model in routing.sh (uses a little quota)
#   .agents/doctor.sh --claude   also send tiny prompts through the claude CLI: the retry model, and the
#                                orchestrator model with its pinned tool flags (checks the flags parse)
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
fails=0
ok()   { echo "  ok    $*"; }
warn() { echo "  warn  $*"; }
bad()  { echo "  FAIL  $*"; fails=$((fails+1)); }

echo "Tools"
for c in git "$( [ "$HARNESS" = omp ] && echo omp || echo pi )" claude jq curl; do command -v "$c" >/dev/null && ok "$c" || bad "$c not found"; done
ok "harness: $HARNESS"
for c in gitleaks semgrep; do command -v "$c" >/dev/null && ok "$c" || warn "$c not installed (that security check is skipped)"; done
[ -z "${ANTHROPIC_API_KEY:-}" ] && ok "ANTHROPIC_API_KEY is not set" || bad "ANTHROPIC_API_KEY is set: Claude Code would bill the API instead of Pro"

echo "Orchestrator"
ok "mode: $ORCHESTRATOR (model $ORCH_MODEL, light $ORCH_LIGHT_MODEL, $CLAUDE_ORCH_DAILY_CAP wakes/day, gap ${ORCH_MIN_GAP_MIN}m, auto sign-off $ORCH_AUTO_SIGNOFF)"
[ -s "$AG/prompts/orchestrator.md" ] && ok "prompts/orchestrator.md" || bad "prompts/orchestrator.md missing"
[ -x "$AG/orchestrate.sh" ] && ok "orchestrate.sh" || bad "orchestrate.sh missing or not executable"
[ -s "$ROOT/.claude/commands/orchestrate.md" ] && ok "/orchestrate command" || warn "/orchestrate command missing (.claude/commands/orchestrate.md)"
if [ "$ORCHESTRATOR" = claude ]; then
  grep -qs 'orchestrate.sh tick' "$AG/loop.sh" && ok "loop.sh runs the orchestrator tick" || warn "loop.sh doesn't run orchestrate.sh tick"
  crontab -l 2>/dev/null | grep -q runner.sh && ! crontab -l 2>/dev/null | grep -q 'orchestrate.sh tick' &&
    warn "cron runs runner.sh but not orchestrate.sh tick (see setup.sh output)"
fi

echo "Repo"
ok "profile: $PROFILE (parallel $MAX_PARALLEL, best-of-2: ${BEST_OF_2:-risky only}, judge: $USE_JUDGE)"
git -C "$ROOT" show-ref --verify --quiet "refs/heads/$MAIN_BRANCH" && ok "main branch: $MAIN_BRANCH" || bad "MAIN_BRANCH=$MAIN_BRANCH does not exist (edit routing.sh)"
[ -s "$ROOT/AGENTS.md" ] && ok "AGENTS.md" || warn "AGENTS.md missing"
[ -s "$ROOT/REPO_MAP.md" ] && ok "REPO_MAP.md" || warn "REPO_MAP.md missing (run: .agents/cos.sh map)"
[ -x "$AG/gates/check.sh" ] && ok "gates/check.sh" || bad "gates/check.sh missing or not executable"
[ "$ALLOW_TRAINING" = yes ] && warn "ALLOW_TRAINING=yes: Muse Contributor may see this repo's code" || ok "ALLOW_TRAINING=no"
[ "$GO" != "$GOAT" ] && ok "GO and GOAT prefixes differ" || bad "GO and GOAT prefixes are identical"

echo "9router"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$ROUTER_URL/models" \
  -H "Authorization: Bearer ${NINEROUTER_API_KEY:-}") || code=000
case "$code" in
  200) ok "reachable at $ROUTER_URL" ;;
  401|403) bad "reachable but rejected the key (export NINEROUTER_API_KEY=...)" ;;
  000) bad "not reachable at $ROUTER_URL (is 9router running?)" ;;
  *) warn "HTTP $code from $ROUTER_URL/models" ;;
esac
case "$ROUTER_URL" in http://127.0.0.1*|http://localhost*) ok "9router is local only" ;; *) warn "9router is not on localhost" ;; esac

echo "Harness ($HARNESS)"
if [ "$HARNESS" = omp ]; then
  omp models "$ROUTER" >"$LOGS/doctor.models" 2>&1 && grep -q . "$LOGS/doctor.models" &&
    ok "omp sees provider $ROUTER" || bad "omp models $ROUTER shows nothing (check ~/.omp/agent/models.yml)"
else
  pi --list-models "$ROUTER" >"$LOGS/doctor.models" 2>&1 && [ -s "$LOGS/doctor.models" ] &&
    ok "pi sees provider $ROUTER" || bad "pi --list-models $ROUTER shows nothing"
fi

if [ "${1:-}" = --models ]; then
  echo "Model smoke test (each should reply 'ready')"
  echo "Reply with the single word: ready" >"$LOGS/doctor.prompt"
  while read -r m; do
    [ -n "$m" ] || continue
    training_ok "$m" || { warn "skip $m (may train on prompts; ALLOW_TRAINING=no)"; continue; }
    if run_model doctor smoke "$m" none "$LOGS/doctor.prompt" "$LOGS/doctor.out" "$ROOT" 90s &&
       grep -qi ready "$LOGS/doctor.out"; then ok "$m"
    else bad "$m: $(cat "$LOGS/doctor.out.err" "$LOGS/doctor.out" 2>/dev/null | head -c 160 | tr '\n' ' ')"; fi
  done < <(all_models | sort -u)
fi

if [ "${1:-}" = --claude ]; then
  echo "Claude (uses a tiny bit of your Pro quota)"
  out=$(env -u ANTHROPIC_API_KEY "$TIMEOUT" 120 claude -p --model "$(echo "${CLAUDE_ESC#CLAUDE_}" | tr "[:upper:]" "[:lower:]")" "Reply with the single word: ready" 2>&1)
  echo "$out" | grep -qi ready && ok "claude -p works on your login" || bad "claude -p failed: $(echo "$out" | head -c 200)"
  out=$(cd "$ROOT" && env -u ANTHROPIC_API_KEY "$TIMEOUT" 120 claude -p "Reply with the single word: ready" --model "$ORCH_MODEL" \
    --allowedTools "$ORCH_ALLOWED_TOOLS" --disallowedTools "$ORCH_DISALLOWED_TOOLS" 2>&1)
  echo "$out" | grep -qi ready && ok "orchestrator call ($ORCH_MODEL, pinned tools) works" ||
    bad "orchestrator call failed (check ORCH_ALLOWED_TOOLS syntax): $(echo "$out" | head -c 200)"
fi

echo; [ $fails = 0 ] && echo "All required checks passed." || { echo "$fails check(s) failed."; exit 1; }
