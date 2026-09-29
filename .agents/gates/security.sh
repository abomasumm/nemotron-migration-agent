#!/usr/bin/env bash
# security.sh: secrets, risky code patterns, vulnerable new dependencies. All free tools.
set -uo pipefail
fail=0
if command -v gitleaks >/dev/null; then
  if gitleaks git --help >/dev/null 2>&1; then gitleaks git --no-banner --log-opts="$BASE..HEAD" . || fail=1
  else gitleaks detect --no-banner --log-opts="$BASE..HEAD" || fail=1; fi
else echo "security: gitleaks not installed, skipped"; fi

if command -v semgrep >/dev/null; then
  semgrep scan --config p/default --metrics off --error --quiet \
    --baseline-commit "$(git merge-base "$BASE" HEAD)" || fail=1
fi

changed=$(git diff --name-only "$BASE"...HEAD)
if echo "$changed" | grep -qE '(^|/)package(-lock)?\.json$' && command -v npm >/dev/null; then
  npm audit --audit-level=high --omit=dev || fail=1
fi
if echo "$changed" | grep -qE '(^|/)(requirements[^/]*\.txt|pyproject\.toml|uv\.lock|poetry\.lock)$' && command -v pip-audit >/dev/null; then
  pip-audit || fail=1
fi
[ $fail = 0 ] && echo "security: ok"
exit $fail
