#!/usr/bin/env bash
# check.sh: tests, lint, types, build. Runs inside a task worktree.
# EDIT THIS for each repo's stack. Exit non-zero on any failure.
# MODE=tests runs only the test suite (used for the "tests must fail first" check).
set -uo pipefail
GATES=$(cd "$(dirname "$0")" && pwd)
MAIN=$(git worktree list --porcelain | head -1 | cut -d' ' -f2)   # your main checkout
MODE=${MODE:-all}; BASE=${BASE:-agents}
export PYTHONDONTWRITEBYTECODE=1
fail=0
run() { echo "\$ $*"; "$@" || fail=1; }

# ---- Node / TypeScript ----
if [ -f package.json ]; then
  if git diff --quiet "$BASE"...HEAD -- package.json package-lock.json 2>/dev/null && [ -d "$MAIN/node_modules" ]; then
    [ -e node_modules ] || ln -s "$MAIN/node_modules" node_modules      # reuse deps: fast
  else
    run npm ci --prefer-offline --no-audit --no-fund                      # deps changed: real install
  fi
  run npm run --if-present test
  if [ "$MODE" != tests ]; then
    run npm run --if-present lint
    run npm run --if-present typecheck
    run npm run --if-present build
  fi
fi

# ---- Python ----
if [ -f pyproject.toml ] || [ -f requirements.txt ]; then
  PY=python3; [ -x "$MAIN/.venv/bin/python" ] && PY="$MAIN/.venv/bin/python"
  export PYTHONPATH="$PWD/src:$PWD${PYTHONPATH:+:$PYTHONPATH}"   # test THIS worktree's code
  echo "\$ pytest"; "$PY" -m pytest -q -x; rc=$?; [ $rc = 0 ] || [ $rc = 5 ] || fail=1   # 5 = no tests
  if [ "$MODE" != tests ]; then
    command -v ruff >/dev/null && run ruff check .
  fi
fi

# ---- Data project: optional sample run with schema/row/null asserts ----
if [ "$MODE" != tests ] && [ -x "$GATES/data.sh" ]; then run "$GATES/data.sh"; fi

exit $fail
