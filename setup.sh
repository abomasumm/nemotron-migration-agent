#!/usr/bin/env bash
# setup.sh: install the agent pipeline into a git repo.
#   bash setup.sh /path/to/your/repo
set -uo pipefail
KIT=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "${1:-.}" && git rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo: ${1:-.}"; exit 1; }
echo "Installing into $REPO"

# ---- dependency check ----
need=0
for c in git claude jq curl; do command -v "$c" >/dev/null || { echo "MISSING (required): $c"; need=1; }; done
command -v omp >/dev/null || command -v pi >/dev/null || { echo "MISSING (required): omp (Oh My Pi) or pi"; need=1; }
command -v timeout >/dev/null || command -v gtimeout >/dev/null || { echo "MISSING (required): timeout (macOS: brew install coreutils)"; need=1; }
[ "${BASH_VERSINFO[0]}" -ge 4 ] || echo "WARNING: bash ${BASH_VERSION} is old. macOS: brew install bash"
for c in gitleaks semgrep rg; do command -v "$c" >/dev/null || echo "optional, recommended: $c"; done
[ -n "${ANTHROPIC_API_KEY:-}" ] && echo "WARNING: ANTHROPIC_API_KEY is set. Unset it or Claude Code bills the API instead of your Pro plan."
[ $need = 1 ] && { echo "Install the missing tools, then re-run."; exit 1; }

# ---- copy files (never overwrite your edits) ----
mkdir -p "$REPO/.agents" "$REPO/.claude/commands"
cp -Rn "$KIT/.agents/." "$REPO/.agents/" 2>/dev/null
cp -n "$KIT/.claude/commands/"*.md "$REPO/.claude/commands/" 2>/dev/null
chmod +x "$REPO/.agents/"*.sh "$REPO/.agents/gates/"*.sh
[ -f "$REPO/AGENTS.md" ] || cp "$KIT/AGENTS.md.template" "$REPO/AGENTS.md"
[ -f "$REPO/NOTES.md" ] || printf '# NOTES.md: one-line lessons, newest last\n' >"$REPO/NOTES.md"
if ! grep -q "Agent pipeline (orchestrator rules)" "$REPO/CLAUDE.md" 2>/dev/null; then
  { echo; cat "$KIT/CLAUDE.md.snippet"; } >>"$REPO/CLAUDE.md"
fi

# ---- gitignore runtime files ----
# Task files are live state the runner rewrites constantly, so they stay out of git.
for l in ".worktrees/" ".agents/logs/" ".agents/locks/" ".agents/tasks/*" "!.agents/tasks/TEMPLATE.md" \
         ".agents/goals/" ".agents/orch/" ".agents/context.md" ".agents/STATUS.md" "node_modules" \
         "__pycache__/" ".pytest_cache/" "*.pyc" ".DS_Store"; do
  grep -qxF "$l" "$REPO/.gitignore" 2>/dev/null || echo "$l" >>"$REPO/.gitignore"
done

cat <<EOF

Done. Next:
  1. Edit .agents/routing.sh: HARNESS (omp or pi), ROUTER / GO / GOAT names (check: omp models 9router),
     MAIN_BRANCH and ALLOW_TRAINING for this repo.
  2. Edit .agents/gates/check.sh for this repo's test/lint/build commands. Fill in AGENTS.md.
  3. Check everything:  .agents/doctor.sh && .agents/doctor.sh --models && .agents/doctor.sh --claude
  4. Commit the kit:  git add .agents .claude CLAUDE.md AGENTS.md NOTES.md .gitignore && git commit -m "agent pipeline"
  5. Automate with the loop in tmux (not cron: on macOS cron can't read Claude's Keychain login):
       cd $REPO && tmux new -s agents 'caffeinate -is .agents/loop.sh'
  6. Start a milestone:  .agents/orchestrate.sh goal "what you want built"
EOF
