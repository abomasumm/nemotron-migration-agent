#!/usr/bin/env bash
# migration.sh: the rules that make a migration provable.
#   type: pin      only test files may change, and at least one must. check.sh already ran them on the
#                  unchanged source, so passing means they pin today's behaviour.
#   type: migrate  no test file may change or disappear: the pinned tests must stay green as they are.
# Other task types pass straight through.
set -uo pipefail
TYPE=$(awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f&&/^type:/{sub(/^type:[ \t]*/,"");print;exit}' "$TASK_FILE")
case "$TYPE" in pin|migrate) ;; *) exit 0 ;; esac
is_test() { local g; set -f; for g in $TEST_GLOBS; do
  # shellcheck disable=SC2053
  [[ $1 == $g ]] && { set +f; return 0; }; done; set +f; return 1; }
bad=0 tests=0
while IFS=$'\t' read -r st p; do
  [ -n "$p" ] || continue
  if is_test "$p"; then
    tests=$((tests+1))
    [ "$TYPE" = migrate ] && { echo "migration: $p is a test file ($st); migrate tasks must leave tests as they are"; bad=1; }
  else
    [ "$TYPE" = pin ] && { echo "migration: $p is not a test file; pin tasks may only add tests"; bad=1; }
  fi
done < <(git diff --name-status --no-renames "$BASE"...HEAD)
[ "$TYPE" = pin ] && [ $tests = 0 ] && { echo "migration: pin task added no tests"; bad=1; }
[ $bad = 0 ] && echo "migration: ok ($TYPE)"
exit $bad
