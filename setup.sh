#!/usr/bin/env bash
# setup.sh: install the agent pipeline into a git repo, or update an installed copy.
#   bash setup.sh /path/to/your/repo            first install (copies only what's missing)
#   bash setup.sh --update /path/to/your/repo   bring the repo's kit files up to this kit's version
#
# Kit-owned files (scripts, prompts, routing.sh, slash commands) are replaced on --update; any that you
# had edited are backed up first to .agents/.kit-backup/<time>/. Repo-owned files are never touched:
# .agents/local.sh (this repo's settings), .agents/gates/check.sh, AGENTS.md, NOTES.md, task and goal files.
set -uo pipefail
KIT=$(cd "$(dirname "$0")" && pwd)
UPDATE=no; [ "${1:-}" = --update ] && { UPDATE=yes; shift; }
REPO=$(cd "${1:-.}" && git rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo: ${1:-.}"; exit 1; }
case "$REPO" in *[[:space:]]*) echo "The kit's scripts don't support spaces in the repo path: $REPO
Move or clone the repo to a path without spaces (e.g. ~/code/<name>)."; exit 1 ;; esac
[ "$REPO" = "$KIT" ] && { echo "That's the kit itself. Give the path of the repo to install into."; exit 1; }
[ $UPDATE = yes ] && echo "Updating the kit in $REPO" || echo "Installing into $REPO"

# ---- dependency check ----
need=0
for c in git claude jq curl; do command -v "$c" >/dev/null || { echo "MISSING (required): $c"; need=1; }; done
command -v omp >/dev/null || command -v pi >/dev/null || { echo "MISSING (required): omp (Oh My Pi) or pi"; need=1; }
command -v timeout >/dev/null || command -v gtimeout >/dev/null || { echo "MISSING (required): timeout (macOS: brew install coreutils)"; need=1; }
[ "${BASH_VERSINFO[0]}" -ge 4 ] || echo "WARNING: bash ${BASH_VERSION} is old. macOS: brew install bash"
for c in gitleaks semgrep rg; do command -v "$c" >/dev/null || echo "optional, recommended: $c"; done
[ -n "${ANTHROPIC_API_KEY:-}" ] && echo "WARNING: ANTHROPIC_API_KEY is set. Unset it or Claude Code bills the API instead of your Pro plan."
[ $need = 1 ] && { echo "Install the missing tools, then re-run."; exit 1; }

# ---- copy kit files ----
# Repo-owned paths, relative to the repo: never overwritten, only created when missing.
repo_owned() { case "$1" in
  .agents/tasks/TEMPLATE.md) return 1 ;;
  .agents/local.sh|.agents/gates/check.sh|.agents/tasks/*|.agents/logs/*) return 0 ;;
  *) return 1 ;;
esac; }
STAMP=$(date +%Y%m%d-%H%M%S); BACKUP="$REPO/.agents/.kit-backup/$STAMP"
added=""; updated=""; edited=""
# Atomic replace (copy, then rename), so a running loop.sh keeps reading the old file until it restarts.
put() { mkdir -p "$(dirname "$2")"; cp "$1" "$2.kit-tmp.$$" && mv "$2.kit-tmp.$$" "$2"; }
install_file() { # kit-relative path
  local rel=$1 src="$KIT/$1" dst="$REPO/$1"
  if repo_owned "$rel"; then [ -e "$dst" ] || { put "$src" "$dst"; added="$added $rel"; }; return; fi
  if [ ! -e "$dst" ]; then put "$src" "$dst"; added="$added $rel"
  elif ! cmp -s "$src" "$dst" && [ $UPDATE = yes ]; then
    # Was this copy edited in the repo? Compare with the kit version it was installed from.
    local was; was=$(cut -d' ' -f1 "$REPO/.agents/KIT_VERSION" 2>/dev/null | sed 's/-dirty$//')
    if [ -z "$was" ] || ! git -C "$KIT" show "$was:$rel" 2>/dev/null | cmp -s - "$dst"; then
      mkdir -p "$BACKUP/$(dirname "$rel")"; cp "$dst" "$BACKUP/$rel"; edited="$edited $rel"
    fi
    put "$src" "$dst"; updated="$updated $rel"
  fi
}
while IFS= read -r rel; do install_file "$rel"
done < <(cd "$KIT" && find .agents .claude/commands -type f ! -name .DS_Store ! -path '.agents/logs/*' \
           ! -path '.agents/.kit-backup/*' ! -name 'KIT_VERSION' ! -name 'local.sh' | sort)
chmod +x "$REPO/.agents/"*.sh "$REPO/.agents/gates/"*.sh
[ -f "$REPO/.agents/local.sh" ] || { cp "$KIT/.agents/local.sh.example" "$REPO/.agents/local.sh"; added="$added .agents/local.sh"; }
[ -f "$REPO/AGENTS.md" ] || cp "$KIT/AGENTS.md.template" "$REPO/AGENTS.md"
[ -f "$REPO/NOTES.md" ] || printf '# NOTES.md: one-line lessons, newest last\n' >"$REPO/NOTES.md"
if ! grep -q "Agent pipeline (orchestrator rules)" "$REPO/CLAUDE.md" 2>/dev/null; then
  { echo; cat "$KIT/CLAUDE.md.snippet"; } >>"$REPO/CLAUDE.md"
fi

# ---- record the kit version (doctor.sh warns when the kit has moved on) ----
ver=$(git -C "$KIT" rev-parse --short HEAD 2>/dev/null || echo unknown)
[ -n "$(git -C "$KIT" status --porcelain -- .agents .claude setup.sh 2>/dev/null)" ] && ver="$ver-dirty"
echo "$ver $KIT" >"$REPO/.agents/KIT_VERSION"

# ---- gitignore runtime files ----
# Task files are live state the runner rewrites constantly, so they stay out of git.
for l in ".worktrees/" ".agents/logs/" ".agents/locks/" ".agents/tasks/*" "!.agents/tasks/TEMPLATE.md" \
         ".agents/goals/" ".agents/orch/" ".agents/context.md" ".agents/STATUS.md" ".agents/.kit-backup/" \
         "node_modules" "__pycache__/" ".pytest_cache/" "*.pyc" ".DS_Store"; do
  grep -qxF "$l" "$REPO/.gitignore" 2>/dev/null || echo "$l" >>"$REPO/.gitignore"
done

list() { for x in $1; do echo "    $x"; done; }
if [ $UPDATE = yes ]; then
  echo; echo "Kit version $ver."
  [ -n "$updated" ] && { echo "  Updated:"; list "$updated"; } || echo "  Already up to date."
  [ -n "$added" ] && { echo "  Added:"; list "$added"; }
  if [ -n "$edited" ]; then
    echo "  These had edits in this repo, now replaced (your versions are in ${BACKUP#"$REPO"/}):"; list "$edited"
    echo "  Move any repo-specific settings from them into .agents/local.sh."
  fi
  cat <<EOF

Next:
  1. .agents/doctor.sh
  2. Commit:  git add .agents .claude .gitignore && git commit -m "Update agent pipeline kit to $ver"
  3. If the loop is running, restart it so it uses the new scripts:
       tmux kill-session -t agents; tmux new -s agents 'caffeinate -is .agents/loop.sh'
EOF
  exit 0
fi

cat <<EOF

Done. Next:
  1. Put this repo's settings in .agents/local.sh (PROFILE, ALLOW_TRAINING, MAIN_BRANCH, caps).
     Check the 9router model names once per machine: omp models 9router
  2. Edit .agents/gates/check.sh for this repo's test/lint/build commands. Fill in AGENTS.md.
  3. Check everything:  .agents/doctor.sh && .agents/doctor.sh --models && .agents/doctor.sh --claude
  4. Commit the kit BEFORE the first goal (the agents branch starts from what's committed):
       git add .agents .claude CLAUDE.md AGENTS.md NOTES.md .gitignore && git commit -m "agent pipeline"
  5. Automate with the loop in tmux (not cron: on macOS cron can't read Claude's Keychain login):
       cd $REPO && tmux new -s agents 'caffeinate -is .agents/loop.sh'
  6. Start a milestone:  .agents/orchestrate.sh goal "what you want built"
Later, to pick up kit fixes:  bash $KIT/setup.sh --update $REPO
EOF
