#!/usr/bin/env bash
# stats.sh [days]: how each model is actually doing in YOUR repo (default: last 30 days).
# Use this, not leaderboards, to adjust routing.sh after a couple of weeks.
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
days=${1:-30}
since=$(date -d "-$days days" +%F 2>/dev/null || date -v-"$days"d +%F)
[ -s "$LOGS/runs.csv" ] || { echo "no runs yet"; exit 0; }
echo "Since $since"
awk -F, -v s="$since" '
  $1 < s { next }
  $4=="gate-pass" { gp[$5]++; seen[$5]=1; next }
  $4=="gate-fail" { gf[$5]++; seen[$5]=1; next }
  $4=="b2win"     { bw[$5]++; seen[$5]=1; next }
  $4=="b2loss"    { bl[$5]++; seen[$5]=1; next }
  $4=="flaky"     { fk[$5]++; seen[$5]=1; next }
  { n[$5]++; t[$5]+=$7; if ($6!=0) e[$5]++; seen[$5]=1 }
  END {
    printf "%-46s %6s %7s %7s %10s %10s %6s\n", "model", "calls", "errors", "avg s", "gates pass", "b2 wins", "flaky"
    for (m in seen) {
      g = gp[m]+gf[m]; b = bw[m]+bl[m]
      printf "%-46s %6d %6.0f%% %7.0f %10s %10s %6d\n", m, n[m], (n[m]?100*e[m]/n[m]:0), (n[m]?t[m]/n[m]:0),
        (g? sprintf("%d/%d", gp[m], g) : "-"), (b? sprintf("%d/%d", bw[m], b) : "-"), fk[m]
    }
  }' "$LOGS/runs.csv" | { read -r h; echo "$h"; sort; }
echo
echo "gates pass: attempts by this model that passed tests, scope and security."
echo "b2 wins: best-of-2 contests this model won (judge pick, or the only one that passed)."
echo "errors: calls that exited non-zero (timeouts, API errors, rate limits)."
