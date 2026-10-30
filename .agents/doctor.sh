#!/usr/bin/env bash
# doctor.sh: check the whole setup from the repo root.
#   .agents/doctor.sh            tools, repo, Token Factory key and models, pi config
#   .agents/doctor.sh --models   also send "reply ready" to every model in routing.sh (uses a few credits)
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
fails=0
ok()   { echo "  ok    $*"; }
warn() { echo "  warn  $*"; }
bad()  { echo "  FAIL  $*"; fails=$((fails+1)); }

echo "Tools"
for c in git pi jq curl python3; do command -v "$c" >/dev/null && ok "$c" || bad "$c not found"; done
for c in gitleaks semgrep; do command -v "$c" >/dev/null && ok "$c" || warn "$c not installed (that security check is skipped)"; done

echo "Orchestrator"
ok "model $ORCH_MODEL (light $ORCH_LIGHT_MODEL), $ORCH_DAILY_CAP wakes/day, gap ${ORCH_MIN_GAP_MIN}m, auto sign-off $ORCH_AUTO_SIGNOFF"
[ -s "$AG/prompts/orchestrator.md" ] && ok "prompts/orchestrator.md" || bad "prompts/orchestrator.md missing"
[ -x "$AG/orchestrate.sh" ] && ok "orchestrate.sh" || bad "orchestrate.sh missing or not executable"

echo "Kit"
if [ -f "$AG/KIT_VERSION" ]; then
  read -r kv kp <"$AG/KIT_VERSION"
  kh=$(git -C "${kp:-/nonexistent}" rev-parse --short HEAD 2>/dev/null)
  if [ -z "$kh" ]; then warn "kit $kv; kit repo not found at ${kp:-?} (can't check for updates)"
  elif [ "${kv%-dirty}" = "$kh" ]; then ok "kit $kv (current)"
  else warn "kit $kv; the kit is now at $kh. Update: bash $kp/setup.sh --update $ROOT"; fi
else warn "no .agents/KIT_VERSION (installed by hand, or this is the kit itself)"; fi
[ -f "$AG/local.sh" ] && ok "local.sh (this repo's settings)" || warn "no .agents/local.sh (setup.sh creates it)"

echo "Repo"
ok "profile: $PROFILE (parallel $MAX_PARALLEL, best-of-2: ${BEST_OF_2:-risky only}, judge: $USE_JUDGE)"
git -C "$ROOT" show-ref --verify --quiet "refs/heads/$MAIN_BRANCH" && ok "main branch: $MAIN_BRANCH" || bad "MAIN_BRANCH=$MAIN_BRANCH does not exist (set it in local.sh)"
[ -s "$ROOT/AGENTS.md" ] && ok "AGENTS.md" || warn "AGENTS.md missing"
[ -s "$ROOT/REPO_MAP.md" ] && ok "REPO_MAP.md" || warn "REPO_MAP.md missing (run: .agents/cos.sh map)"
[ -x "$AG/gates/check.sh" ] && ok "gates/check.sh" || bad "gates/check.sh missing or not executable"
git -C "$ROOT" check-ignore -q "$AG/secrets.sh" && ok "secrets.sh is git-ignored" || bad "add .agents/secrets.sh to .gitignore"

echo "Token Factory"
if [ -z "${NEBIUS_API_KEY:-}" ]; then bad "NEBIUS_API_KEY is empty (put it in .agents/secrets.sh)"
else
  code=$(curl -s -o "$LOGS/doctor.tf.json" -w '%{http_code}' --max-time 15 "$TF_URL/models" \
    -H "Authorization: Bearer $NEBIUS_API_KEY") || code=000
  case "$code" in
    200) ok "reachable at $TF_URL, key accepted"
         while read -r m; do
           id=${m#"$TF"/}; id=${id%:*}
           jq -e --arg id "$id" '.data[] | select(.id == $id)' "$LOGS/doctor.tf.json" >/dev/null &&
             ok "model $id" || bad "model $id is not offered by Token Factory (fix routing.sh or local.sh)"
         done < <(all_models | sort -u) ;;
    401|403) bad "Token Factory rejected the key (HTTP $code)" ;;
    000) bad "Token Factory not reachable at $TF_URL" ;;
    *) bad "HTTP $code from $TF_URL/models" ;;
  esac
fi

echo "pi (config in ${PI_CODING_AGENT_DIR#"$ROOT"/})"
[ -s "$PI_CODING_AGENT_DIR/models.json" ] && ok "models.json" || bad "$PI_CODING_AGENT_DIR/models.json missing"
pi $PI_FLAGS --list-models "$TF" >"$LOGS/doctor.models" 2>&1
while read -r m; do
  id=${m#"$TF"/}; id=${id%:*}
  grep -qF "$id" "$LOGS/doctor.models" && ok "pi sees $id" || bad "pi doesn't see $id (add it to models.json)"
done < <(all_models | sort -u)

if [ "${1:-}" = --models ]; then
  echo "Model smoke test (each should reply 'ready')"
  echo "Reply with the single word: ready" >"$LOGS/doctor.prompt"
  while read -r m; do
    [ -n "$m" ] || continue
    if run_model doctor smoke "$m" none "$LOGS/doctor.prompt" "$LOGS/doctor.out" "$ROOT" 120s &&
       grep -qi ready "$LOGS/doctor.out"; then ok "$m"
    else bad "$m: $(cat "$LOGS/doctor.out.err" "$LOGS/doctor.out" 2>/dev/null | head -c 160 | tr '\n' ' ')"; fi
  done < <(all_models | sort -u)
fi

echo; [ $fails = 0 ] && echo "All required checks passed." || { echo "$fails check(s) failed."; exit 1; }
