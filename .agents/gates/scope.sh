#!/usr/bin/env bash
# scope.sh: fail if the change touches files outside the brief's `files:` list.
# Test files (TEST_GLOBS) are always allowed. .agents/ is never allowed.
set -uo pipefail
FILES=$(awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f&&/^files:/{sub(/^files:[ \t]*/,"");print;exit}' "$TASK_FILE")
[ -n "$FILES" ] || { echo "scope: brief has no files: list"; exit 1; }
set -f
bad=0
while read -r p; do
  [ -n "$p" ] || continue
  ok=0
  for g in $(echo "$FILES" | tr ',' ' ') $TEST_GLOBS; do
    # shellcheck disable=SC2053
    [[ $p == $g ]] && { ok=1; break; }
  done
  case "$p" in .agents/*|.worktrees/*|.claude/*|CLAUDE.md) ok=0 ;; esac
  [ $ok = 1 ] || { echo "scope: $p is outside the brief"; bad=1; }
done < <(git diff --name-only "$BASE"...HEAD)
[ $bad = 0 ] && echo "scope: ok"
exit $bad
