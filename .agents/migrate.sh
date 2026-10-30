#!/usr/bin/env bash
# migrate.sh: set up and start a migration.
#   migrate.sh init [--template]   detect the repo, ask what it can't detect, write MIGRATION.md and a first brief
#                                  (--template: no questions; detected parts filled in, the rest left for you)
#   migrate.sh init --prepare      detect, baseline and suggestions only: writes the questions with defaults as
#                                  JSON (.agents/logs/migration-questions.json), for the web app's form
#   migrate.sh init --answers F    write MIGRATION.md from a JSON file of answers ({"from": "...", "to": ...})
#   migrate.sh start [profile]     queue the brief as a migration goal (default profile: default)
#   migrate.sh status              modules pinned and migrated so far
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
FACTS="$LOGS/migration-facts.json"; MIG="$ROOT/MIGRATION.md"; BRIEF="$AG/migration-brief.md"
QUESTIONS="$LOGS/migration-questions.json"

jl() { jq -r "$1" "$FACTS"; }   # read a fact
bullets() { tr ';' '\n' | sed 's/^ *//; /^$/d; s/^/- /'; }

suggest() { # the helper model reads the facts and the code, and proposes defaults for the questions
  local pf="$LOGS/migrate-init.prompt" out="$LOGS/migrate-init.out" f
  { cat "$AG/prompts/migrate-init.md"; echo; echo "# Detected facts"; cat "$FACTS"; echo
    for f in $(jl '.modules[].path'); do echo "## $f"; head -n 60 "$ROOT/$f"; echo; done; } | head -c 40000 >"$pf"
  run_model init migrate-init "$(route_cos)" none "$pf" "$out" "$ROOT" 5m >/dev/null 2>&1 &&
    json_block "$out" | jq -e . >"$LOGS/migrate-suggest.json" 2>/dev/null || echo '{}' >"$LOGS/migrate-suggest.json"
}
sg() { jq -r "$1 // empty" "$LOGS/migrate-suggest.json" 2>/dev/null; }

# Detect, run the baseline, get suggestions, and write the questions with their defaults to QUESTIONS
# (the web app shows them as a form; the terminal asks them one by one).
prepare() {
  echo "Reading the repo..."
  python3 -I "$AG/detect.py" "$ROOT" >"$FACTS" || { echo "detection failed"; exit 1; }
  echo "  $(jl .language) ($(jl '.module_style // "-"')), $(jl '.modules|length') modules, test runner: $(jl '.test_runner // "none"')"
  echo "  modules without tests: $(jl '.untested|length') ($(jl '.untested|join(", ")'))"
  echo "Running the tests on the current code (the baseline must be green)..."
  local base=red
  ( cd "$ROOT" && MODE=all BASE=HEAD bash "$AG/gates/check.sh" ) </dev/null >"$LOGS/migration-baseline.log" 2>&1 && base=green
  echo "  baseline: $base (log: .agents/logs/migration-baseline.log)"
  echo "Asking $(short_model "$(route_cos)") for suggested answers..."
  suggest </dev/null
  # CommonJS modules require() each other; once one becomes .ts, its callers can only load it if the test
  # runner registers a TypeScript loader. Without one, module-by-module migration cannot stay green.
  local warn=""
  if [ "$(jl '.module_style // ""')" = CommonJS ] && [ -f "$ROOT/package.json" ] &&
     ! jq -r '.scripts.test // ""' "$ROOT/package.json" | grep -qE 'tsx|ts-node|--import|--require|ts-jest'; then
    warn="CommonJS modules require() each other. Once one module becomes .ts, the .js files that require it cannot load it unless the test runner registers a TypeScript loader, e.g. \"test\": \"NODE_OPTIONS='--import tsx' vitest run\" (needs tsx). Set that up and commit it before starting, or migrate every module in one task."
    echo "  WARNING: $warn"
  fi
  local from; from="$(jl .language)$( [ "$(jl '.module_style // ""')" != "" ] && echo " ($(jl .module_style))")"
  jq -n --arg base "$base" --arg warn "$warn" --slurpfile f "$FACTS" \
    --arg from "$from" \
    --arg to "$(sg .to | grep . || echo "TypeScript, strict mode, same module layout, change file extensions only")" \
    --arg scope "$(jl '.source_dirs|join("; ")')" \
    --arg keep "existing tests; package.json and lockfile; build and tool config" \
    --arg must "$(sg '.must_not_change|join("; ")' | grep . || echo "every exported function's results and error messages")" \
    --arg crit "$(sg '.critical|join("; ")')" \
    --arg done "no $(jl '.language' | sed 's/ .*//') source files left in scope; all tests and the typecheck pass" \
    --arg approach "$(sg '.approach|join("; ")' | grep . || echo "leaves first, one module per task")" '
    { baseline: $base, warnings: (if $warn == "" then [] else [$warn] end),
      summary: { language: $f[0].language, module_style: $f[0].module_style, modules: ($f[0].modules|length),
                 untested: $f[0].untested, test_runner: $f[0].test_runner, commands: $f[0].commands },
      questions: [
        {key: "from", text: "Migrating from", default: $from},
        {key: "to", text: "Migrating to (target and settings)", default: $to},
        {key: "scope", text: "Folders in scope", default: $scope},
        {key: "keep", text: "Never touch", default: $keep},
        {key: "must", text: "Behaviour that must not change", default: $must},
        {key: "crit", text: "Business-critical modules (extra review and sign-off)", default: $crit},
        {key: "deps", text: "Allowed to add dependencies? (yes/no)", default: "no"},
        {key: "api", text: "Allowed to change the public API (exported names, signatures)? (yes/no)", default: "no"},
        {key: "done", text: "Done when", default: $done},
        {key: "approach", text: "How should it be migrated (order, what must move together, boundaries to keep)?", default: $approach}
      ] }' >"$QUESTIONS"
}

# answer <n> -> the answer to question n (1-based): from the answers file, the default (--template), or the terminal
answer() { local key text def a
  key=$(jq -r ".questions[$1-1].key" "$QUESTIONS"); text=$(jq -r ".questions[$1-1].text" "$QUESTIONS")
  def=$(jq -r ".questions[$1-1].default" "$QUESTIONS")
  case "$MODE_" in
    answers) a=$(jq -r --arg k "$key" '.[$k] // empty' "$ANSWERS"); echo "${a:-$def}" ;;
    template) echo "${def:-TODO}" ;;
    *) printf '\n%s. %s:\n  [%s]\n> ' "$1" "$text" "$def" >/dev/tty; IFS= read -r a </dev/tty; echo "${a:-$def}" ;;
  esac; }

cmd_init() {
  MODE_=ask; ANSWERS=""
  case "${1:-}" in
    --template) MODE_=template ;;
    --prepare) prepare; echo "questions: $QUESTIONS"; return ;;
    --answers) MODE_=answers; ANSWERS=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
               [ -s "$ANSWERS" ] || { echo "no answers file: $2"; exit 1; } ;;
  esac
  [ "$MODE_" != ask ] || [ -t 0 ] || { echo "No terminal for questions; writing the template instead."; MODE_=template; }
  # The app prepares first (so it can show the form), then sends the answers: reuse that preparation.
  [ "$MODE_" = answers ] && [ -s "$QUESTIONS" ] && [ -s "$FACTS" ] || prepare
  local base from to scope keep must crit deps api done approach cmds
  base=$(jq -r .baseline "$QUESTIONS")
  [ "$MODE_" = ask ] && { echo; echo "A few questions. Press Enter to accept the suggestion in brackets; separate list items with ';'."; }
  from=$(answer 1); to=$(answer 2); scope=$(answer 3); keep=$(answer 4); must=$(answer 5)
  crit=$(answer 6); deps=$(answer 7); api=$(answer 8); done=$(answer 9); approach=$(answer 10)
  cmds=$(jq -r '.commands|to_entries|map("\(.key): `\(.value)`")|join("; ")' "$FACTS")

  {
    echo "# Migration plan"
    echo "<!-- Written by .agents/migrate.sh init on $(now). Edit freely: the planner and every worker read this file. -->"
    echo; echo "## Migration"
    echo "- From: $from"; echo "- To: $to"
    echo; echo "## Scope"; echo "In scope:"; echo "$scope" | bullets
    echo "Never touch:"; echo "$keep" | bullets
    echo; echo "## Behaviour that must not change"; echo "$must" | bullets
    echo; echo "## Rules"
    echo "- New dependencies allowed: $deps"; echo "- Public API changes allowed: $api"
    echo "- Tests: existing tests are never edited. Untested modules get characterization tests first (pin tasks)."
    echo "- One module per migrate task, in the dependency order below."
    echo; echo "## Approach"; echo "$approach" | bullets
    echo; echo "## Done when"; echo "$done" | bullets
    echo; echo "## Commands"; echo "$cmds" | bullets
    echo "- Baseline on $(today): $base"
    echo; echo "## Modules (dependency order: migrate from the top)"
    echo "| Module | Lines | Imports | Imported by | Tests | Risk |"; echo "|---|---|---|---|---|---|"
    jq -r --arg crit "$crit" '.modules[] | .path as $p | "| `\(.path)` | \(.lines) | \(.imports|map(split("/")|last)|join(", ")) | \(.imported_by|length) | \(if (.tests|length)>0 then (.tests|join(", ")) else "none" end) | \((.risks + (if ($crit|contains($p)) then ["critical"] else [] end))|join(", ")) |"' "$FACTS"
    [ "$(jl '.cycles|length')" != 0 ] && { echo; echo "Import cycles (migrate these together): $(jl '.cycles|join(", ")')"; }
    echo; echo "## Existing tests (what they already cover)"
    jq -r '.test_titles | to_entries[] | "- `\(.key)`: \(.value|join("; "))"' "$FACTS" | grep . || echo "- (none)"
    jq -r '.warnings[]? | "\n## Warning\n- " + .' "$QUESTIONS"
    echo; echo "## Notes from the setup model ($(short_model "$(route_cos)"))"
    sg '.notes[]?' | sed 's/^/- /' | grep . || echo "- (none)"
  } >"$MIG"
  [ "$MODE_" = template ] && sed -i.bak 's/^- To: TODO$/- To: TODO (e.g. TypeScript, strict mode)/' "$MIG" && rm -f "$MIG.bak"

  {
    echo "Migrate $(echo "$scope" | sed 's/;/,/g') from $from to $to, as described in MIGRATION.md, without changing behaviour."
    echo; echo "First pin the current behaviour that no existing test covers (modules without tests: $(jl '.untested|join(", ")'); see the existing test names in MIGRATION.md) with characterization tests."
    echo "Then migrate following the approach in MIGRATION.md, in dependency order: $(jl '[.modules[].path]|join(" -> ")')."
    echo; echo "Acceptance:"
    echo "- Every existing test passes unchanged, and every new characterization test passes before and after."
    echo "$must" | bullets
    echo "$done" | bullets
  } >"$BRIEF"

  echo; echo "Wrote MIGRATION.md and .agents/migration-brief.md."
  [ "$base" = green ] || echo "WARNING: the tests fail on the current code. Fix them first: a migration can only be proven against a green baseline."
  echo "$cmds" | grep -q typecheck || echo "Note: no typecheck script found. Add one (e.g. \"typecheck\": \"tsc --noEmit\") so migrated code is type-checked."
  echo "Next: read MIGRATION.md, edit anything wrong, commit it, then:  .agents/migrate.sh start"
}

cmd_start() {
  [ -s "$MIG" ] && [ -s "$BRIEF" ] || { echo "Run .agents/migrate.sh init first."; exit 1; }
  grep -q 'TODO' "$MIG" && { echo "MIGRATION.md still has TODO entries; fill them in first."; exit 1; }
  git -C "$ROOT" ls-files --error-unmatch "$MIG" >/dev/null 2>&1 && git -C "$ROOT" diff --quiet -- "$MIG" ||
    { echo "Commit MIGRATION.md first (workers branch from what's committed):  git add MIGRATION.md && git commit -m \"migration plan\""; exit 1; }
  "$AG/orchestrate.sh" goal "$(cat "$BRIEF")" "${1:-}" migration
}

cmd_status() {
  local f t st pin=0 pinned=0 mig=0 migrated=0
  for f in $(task_files); do
    t=$(fm_get "$f" type); st=$(fm_get "$f" status)
    case "$t" in pin) pin=$((pin+1)); [ "$st" = merged ] && pinned=$((pinned+1)) ;;
                 migrate) mig=$((mig+1)); [ "$st" = merged ] && migrated=$((migrated+1)) ;; esac
  done
  echo "Pinned: $pinned/$pin modules. Migrated: $migrated/$mig modules."
  "$AG/runner.sh" status
}

case "${1:-}" in
  init) cmd_init "${2:-}" "${3:-}" ;;
  start) cmd_start "${2:-}" ;;
  status) cmd_status ;;
  *) sed -n '2,7p' "$0" ;;
esac
