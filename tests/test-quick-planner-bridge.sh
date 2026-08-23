#!/usr/bin/env bash
# Disposable-project integration and exact internal-call checks for issue #2.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAPABILITY_SOURCE="$REPO_ROOT/.gsd/capabilities/ponytail"
BRIDGE_REL=".gsd/capabilities/ponytail/skills/quick-planner"
RENDERER="$CAPABILITY_SOURCE/skills/quick-planner/render.cjs"
PLANNER_FRAGMENT="$CAPABILITY_SOURCE/fragments/planner-ladder.md"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

if command -v gsd-tools >/dev/null 2>&1; then
  GSD_COMMAND="$(command -v gsd-tools)"
  GSD_CJS=""
elif [ -f "${GSD_TOOLS_CJS:-/home/dd/.codex/gsd-core/bin/gsd-tools.cjs}" ]; then
  GSD_COMMAND=""
  GSD_CJS="${GSD_TOOLS_CJS:-/home/dd/.codex/gsd-core/bin/gsd-tools.cjs}"
else
  fail "gsd-tools 1.11.0 is required"
fi

gsd_tools() {
  if [ -n "$GSD_COMMAND" ]; then
    "$GSD_COMMAND" "$@"
  else
    node "$GSD_CJS" "$@"
  fi
}

TOOLS_BIN="$SCRATCH/bin"
mkdir -p "$TOOLS_BIN"
if [ -n "$GSD_COMMAND" ]; then
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$GSD_COMMAND" > "$TOOLS_BIN/gsd-tools"
else
  printf '#!/usr/bin/env bash\nexec node "%s" "$@"\n' "$GSD_CJS" > "$TOOLS_BIN/gsd-tools"
fi
chmod +x "$TOOLS_BIN/gsd-tools"

write_config() {
  local project="$1" enabled="$2" level="$3"
  jq -n \
    --argjson enabled "$enabled" \
    --arg level "$level" \
    --arg bridge "$BRIDGE_REL" \
    '{runtime:"codex", ponytail:{enabled:$enabled, level:$level}, agent_skills:{"gsd-planner":["skills/existing", $bridge]}}' \
    > "$project/.planning/config.json"
}

install_project() {
  local name="$1" source="$2"
  PROJECT="$SCRATCH/project-$name"
  GSD_STATE="$SCRATCH/gsd-home-$name"
  mkdir -p "$PROJECT/.planning" "$PROJECT/skills/existing" "$GSD_STATE"
  git -C "$PROJECT" init -q
  printf '%s\n' '# Existing planner skill' > "$PROJECT/skills/existing/SKILL.md"
  write_config "$PROJECT" true full
  GSD_HOME="$GSD_STATE" PATH="$TOOLS_BIN:$PATH" \
    gsd_tools capability install "$source" --scope project --yes --cwd "$PROJECT" --raw \
    >/dev/null
}

run_bridge() {
  local project="$1" state="$2"
  (
    cd "$project"
    GSD_HOME="$state" PATH="$TOOLS_BIN:$PATH" \
      gsd-tools loop render-hooks plan:pre --raw 2>/dev/null \
      | node "$project/$BRIDGE_REL/render.cjs"
  )
}

planner_block() {
  local project="$1" state="$2"
  GSD_HOME="$state" PATH="$TOOLS_BIN:$PATH" \
    gsd_tools query agent-skills gsd-planner --raw --cwd "$project"
}

init_quick() {
  local project="$1" state="$2" flag="${3:-}"
  if [ -n "$flag" ]; then
    GSD_HOME="$state" PATH="$TOOLS_BIN:$PATH" \
      gsd_tools query init.quick bridge-check "$flag" --raw --cwd "$project" >/dev/null
  else
    GSD_HOME="$state" PATH="$TOOLS_BIN:$PATH" \
      gsd_tools query init.quick bridge-check --raw --cwd "$project" >/dev/null
  fi
}

[ -f "$RENDERER" ] || fail "bridge renderer missing"
[ -f "$PLANNER_FRAGMENT" ] || fail "planner ladder fragment missing"

assert_current_scope_contract() {
  local text

  for text in \
    'Historical context may guide discovery but cannot authorize concrete mutable scope without a current task-relevant observation.' \
    'Explicit user-fixed scope and immutable inputs remain concrete without a precondition.' \
    'When mutable scope has not been observed, keep it conditional and make the current read-only observation the first action before mutation.' \
    'When plan-time evidence may drift before execution, use one concrete read-only task-local <precondition> immediately before mutation.' \
    'Do not add a precondition for facts produced by the task or intra-plan ordering already represented by depends_on.' \
    'A live merge index and an API resource version or migration state are domain-neutral examples, not command prescriptions.'; do
    grep -Fq "$text" "$PLANNER_FRAGMENT" \
      || fail "planner fragment missing current-scope contract: $text"
  done
}

assert_current_scope_contract
pass "planner fragment preserves current-observation scope fixtures"

# Exact internal call and selector: fixed argv, first matching contribution once.
SPY_BIN="$SCRATCH/spy-bin"
SPY_LOG="$SCRATCH/spy-argv.json"
mkdir -p "$SPY_BIN"
printf '%s\n' \
  '#!/usr/bin/env node' \
  "require('node:fs').writeFileSync(process.env.SPY_LOG, JSON.stringify(process.argv.slice(2)));" \
  "process.stdout.write(process.env.SPY_JSON || '');" \
  > "$SPY_BIN/gsd-tools"
chmod +x "$SPY_BIN/gsd-tools"

run_spy_renderer() {
  PATH="$SPY_BIN:$PATH" SPY_LOG="$SPY_LOG" SPY_JSON="$1" \
    gsd-tools loop render-hooks plan:pre --raw 2>/dev/null | node "$RENDERER"
}

SPY_JSON='{"activeHooks":[{"capId":"other","kind":"contribution","into":"planner","fragment":{"inline":"WRONG"}},{"capId":"ponytail","kind":"contribution","into":"planner","fragment":{"inline":"RIGHT"}},{"capId":"ponytail","kind":"contribution","into":"planner","fragment":{"inline":"DUPLICATE"}}]}'
OUT="$(run_spy_renderer "$SPY_JSON")"
[ "$(cat "$SPY_LOG")" = '["loop","render-hooks","plan:pre","--raw"]' ] || fail "renderer argv changed"
[ "$OUT" = "RIGHT" ] || fail "renderer did not select exactly one Ponytail planner contribution"
pass "fixed hook query argv and exactly-once selector"

OUT="$(run_spy_renderer 'not-json')"
[ -z "$OUT" ] || fail "invalid hook JSON was not silent"
OUT="$(run_spy_renderer '{"activeHooks":[]}')"
[ -z "$OUT" ] || fail "absent hook was not silent"
OUT="$(run_spy_renderer '{"activeHooks":[],"capabilities":{"ponytail":{"active":false,"reason":"runtime incompatible"}}}')"
[ -z "$OUT" ] || fail "runtime-incompatible hook state was not silent"
pass "invalid, absent, and runtime-incompatible hook data fail silent"

# Real project-scope capability install: no runtime-specific global skill root.
install_project normal "$CAPABILITY_SOURCE"
EXPECTED_BLOCK='<agent_skills>
Read these user-configured skills:
- @skills/existing/SKILL.md
- @.gsd/capabilities/ponytail/skills/quick-planner/SKILL.md
</agent_skills>'
for flag in "" --validate --full; do
  init_quick "$PROJECT" "$GSD_STATE" "$flag"
  BLOCK="$(planner_block "$PROJECT" "$GSD_STATE")"
  [ "$BLOCK" = "$EXPECTED_BLOCK" ] || fail "ordered planner skill block differs for ${flag:-standard} Quick"
  OUT="$(run_bridge "$PROJECT" "$GSD_STATE")"
  [ "$(printf '%s\n' "$OUT" | grep -c 'Ponytail lazy-ladder discipline for planning')" -eq 1 ] \
    || fail "Ponytail ladder not delivered exactly once for ${flag:-standard} Quick"
done
pass "standard, validate, and full Quick share one ordered bridge block"

for level in lite full ultra; do
  write_config "$PROJECT" true "$level"
  RAW="$(GSD_HOME="$GSD_STATE" PATH="$TOOLS_BIN:$PATH" gsd_tools loop render-hooks plan:pre --raw --cwd "$PROJECT")"
  [ "$(printf '%s' "$RAW" | jq -r '.activeHooks[] | select(.capId == "ponytail" and .kind == "contribution" and .into == "planner") | .configValues.level')" = "$level" ] \
    || fail "$level did not resolve through capability configValues"
  EXPECTED="$(printf '%s' "$RAW" | jq -r '.activeHooks[] | select(.capId == "ponytail" and .kind == "contribution" and .into == "planner") | .fragment.inline')"
  [ "$(run_bridge "$PROJECT" "$GSD_STATE")" = "$EXPECTED" ] \
    || fail "$level bridge output differs from authoritative capability fragment"
done
pass "lite, full, and ultra reuse the authoritative contribution"

write_config "$PROJECT" false full
[ -z "$(run_bridge "$PROJECT" "$GSD_STATE")" ] || fail "ponytail.enabled=false produced ladder"
pass "disabled capability is silent"

ABSENT_SOURCE="$SCRATCH/absent-source"
cp -rf "$CAPABILITY_SOURCE" "$ABSENT_SOURCE"
jq '.contributions |= map(select(.point != "plan:pre" or .into != "planner"))' \
  "$ABSENT_SOURCE/capability.json" > "$ABSENT_SOURCE/capability.json.tmp"
mv -f "$ABSENT_SOURCE/capability.json.tmp" "$ABSENT_SOURCE/capability.json"
install_project absent "$ABSENT_SOURCE"
[ -z "$(run_bridge "$PROJECT" "$GSD_STATE")" ] || fail "absent planner contribution produced ladder"
pass "absent planner contribution is silent"

printf '%s\n' 'ALL PASS'
