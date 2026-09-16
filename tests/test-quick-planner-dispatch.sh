#!/usr/bin/env bash
# Reach proof for Ponytail's plan:pre -> planner contribution, native Quick
# dispatch (issue #5). Two independent claims, both required:
#   1. resolver — the capability publishes one byte-identical planner fragment.
#   2. host     — the installed gsd-core workflow tree has a landing site for
#                 it in both plan-phase.md and quick.md (positive control),
#                 pinned to the same evidence the #5 migration relied on.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAPABILITY_SOURCE="$REPO_ROOT/.gsd/capabilities/ponytail"
MANIFEST="$CAPABILITY_SOURCE/capability.json"
FRAGMENT="$CAPABILITY_SOURCE/fragments/planner-ladder.md"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

if command -v gsd-tools >/dev/null 2>&1; then
  GSD_COMMAND="$(command -v gsd-tools)"
  GSD_CJS=""
  GSD_ENTRY="$GSD_COMMAND"
elif [ -f "${GSD_TOOLS_CJS:-$HOME/.codex/gsd-core/bin/gsd-tools.cjs}" ]; then
  GSD_COMMAND=""
  GSD_CJS="${GSD_TOOLS_CJS:-$HOME/.codex/gsd-core/bin/gsd-tools.cjs}"
  GSD_ENTRY="$GSD_CJS"
elif [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/gsd-core/bin/gsd-tools.cjs" ]; then
  # Matches hooks/gsd-tools.sh's own runtime resolution order.
  GSD_COMMAND=""
  GSD_CJS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/gsd-core/bin/gsd-tools.cjs"
  GSD_ENTRY="$GSD_CJS"
else
  fail "gsd-tools 1.13.0 or later is required"
fi

gsd_tools() {
  if [ -n "$GSD_COMMAND" ]; then "$GSD_COMMAND" "$@"; else node "$GSD_CJS" "$@"; fi
}

GSD_ROOT="$(dirname "$(dirname "$(readlink -f "$GSD_ENTRY")")")"
WORKFLOWS="$GSD_ROOT/workflows"
PLAN_WORKFLOW="$WORKFLOWS/plan-phase.md"
QUICK_WORKFLOW="$WORKFLOWS/quick.md"
[ -f "$PLAN_WORKFLOW" ] || fail "no plan-phase workflow under $WORKFLOWS"
[ -f "$QUICK_WORKFLOW" ] || fail "no quick workflow under $WORKFLOWS"

# --- claim 1: static declaration --------------------------------------------------

[ -f "$FRAGMENT" ] || fail "planner fragment missing"
jq -e '
  .engines.gsd == ">=1.13.0" and
  (.skills | index("quick-planner")) == null and
  ([.contributions[] | select(
    .point == "plan:pre" and .into == "planner" and
    .produces == [] and .consumes == [] and
    .fragment.path == "fragments/planner-ladder.md" and
    .when == "ponytail.enabled" and
    .configValues.level == "ponytail.level" and
    .onError == "skip"
  )] | length == 1)
' "$MANIFEST" >/dev/null || fail "plan:pre -> planner contribution contract differs, engines.gsd floor regressed, or the interim bridge skill returned"
pass "planner contribution declares fragment, gate, and level configValue; engines.gsd floor and skills list are current"

jq -e '.version == "0.7.0"' "$MANIFEST" >/dev/null || fail "capability version is not 0.7.0"
jq -e '.version == "0.7.0"' "$REPO_ROOT/.claude-plugin/plugin.json" >/dev/null || fail "plugin version is not 0.7.0"
grep -Fq 'test-quick-planner-dispatch.sh' "$REPO_ROOT/.github/workflows/ci.yml" \
  || fail "CI does not run this dispatch reach test"
pass "capability/plugin versions and CI wiring are current"

for text in \
  'Historical context may guide discovery but cannot authorize concrete mutable scope without a current task-relevant observation.' \
  'Explicit user-fixed scope and immutable inputs remain concrete without a precondition.' \
  'When mutable scope has not been observed, keep it conditional and make the current read-only observation the first action before mutation.' \
  'When plan-time evidence may drift before execution, use one concrete read-only task-local <precondition> immediately before mutation.' \
  'Do not add a precondition for facts produced by the task or intra-plan ordering already represented by depends_on.' \
  'A live merge index and an API resource version or migration state are domain-neutral examples, not command prescriptions.'; do
  grep -Fqx "$text" "$FRAGMENT" || fail "planner fragment missing current-scope contract: $text"
done
pass "planner fragment preserves current-observation scope contract"

# --- claim 1: real resolver ---------------------------------------------------

write_config() {
  jq -n --argjson enabled "$1" --arg level "$2" \
    '{runtime:"codex", ponytail:{enabled:$enabled, level:$level}}' \
    > "$PROJECT/.planning/config.json"
}

install_project() {
  local name="$1" source="$2"
  PROJECT="$SCRATCH/project-$name"
  GSD_HOME_DIR="$SCRATCH/gsd-home-$name"
  mkdir -p "$PROJECT/.planning" "$GSD_HOME_DIR"
  git -C "$PROJECT" init -q
  write_config true full
  GSD_HOME="$GSD_HOME_DIR" gsd_tools capability install "$source" \
    --scope project --yes --cwd "$PROJECT" --raw >/dev/null
}

install_project main "$CAPABILITY_SOURCE"

count_planner_hooks() {
  GSD_HOME="$GSD_HOME_DIR" gsd_tools loop render-hooks plan:pre --raw --cwd "$PROJECT" \
    | jq '[.activeHooks[]? | select(.capId == "ponytail" and .kind == "contribution" and .into == "planner")] | length'
}

for level in lite full ultra; do
  write_config true "$level"
  raw="$(GSD_HOME="$GSD_HOME_DIR" gsd_tools loop render-hooks plan:pre --raw --cwd "$PROJECT")"
  [ "$(printf '%s' "$raw" | jq -r '.point')" = "plan:pre" ] || fail "render envelope point differs from plan:pre"
  [ "$(printf '%s' "$raw" | jq '[.activeHooks[]? | select(.capId == "ponytail" and .kind == "contribution" and .into == "planner")] | length')" = 1 ] \
    || fail "expected exactly one active Ponytail planner contribution at $level"
  hook="$(printf '%s' "$raw" | jq -c '.activeHooks[]? | select(.capId == "ponytail" and .kind == "contribution" and .into == "planner")')"
  [ "$(printf '%s' "$hook" | jq -r '.configValues.level')" = "$level" ] \
    || fail "resolved level differs for $level"
  printf '%s' "$hook" | jq -jr '.fragment.inline' | cmp -s "$FRAGMENT" - \
    || fail "rendered planner fragment differs from source at $level"
done
pass "real registry exposes one byte-identical planner fragment for lite, full, ultra"

write_config false full
[ "$(count_planner_hooks)" = 0 ] || fail "ponytail.enabled=false exposed a planner contribution"
pass "disabled Ponytail is silent"

ABSENT_SOURCE="$SCRATCH/absent-source"
cp -r "$CAPABILITY_SOURCE" "$ABSENT_SOURCE"
jq '.contributions |= map(select(.point != "plan:pre" or .into != "planner"))' \
  "$ABSENT_SOURCE/capability.json" > "$ABSENT_SOURCE/capability.json.tmp"
mv "$ABSENT_SOURCE/capability.json.tmp" "$ABSENT_SOURCE/capability.json"
install_project absent "$ABSENT_SOURCE"
write_config true full
[ "$(count_planner_hooks)" = 0 ] || fail "absent planner contribution produced a hook"
pass "absent planner contribution is silent"

# --- claim 2: host reach, both plan-phase and quick ---------------------------

# Anchored to "planner" specifically, not any role, so a landing site for a
# different role (e.g. "executor") cannot satisfy this as a false positive.
DISPATCH_PLANNER='into[[:space:]]*===?[[:space:]]*["'"'"']planner["'"'"']'

grep -Eq "$DISPATCH_PLANNER" "$PLAN_WORKFLOW" \
  || fail "landing-site probe matched no planner role selection in the plan workflow; upstream reworded it and this probe is now blind"
pass "planner landing site present in plan-phase.md"

# Scoped to the planner-spawn step itself (Step 5), not a bare whole-file
# grep, and requires both the into==planner selection and configValues
# forwarding within that step's window.
assert_planner_dispatch_in_quick_step5() {
  awk -v anchor='Step 5: Spawn planner' -v role="$DISPATCH_PLANNER" '
    index($0, anchor) { at = NR }
    at && NR > at && NR <= at + 20 {
      if ($0 ~ role) role_hit = 1
      if (index($0, "configValues")) cfg_hit = 1
      if (index($0, "fragment.inline")) fragment_hit = 1
    }
    END { exit((role_hit && cfg_hit && fragment_hit) ? 0 : 1) }
  ' "$QUICK_WORKFLOW" \
    || fail "quick workflow's planner-spawn step (Step 5) no longer selects into==\"planner\", forwards configValues, or injects fragment.inline; native Quick dispatch (#5, gsd-core b848b23) may have regressed"
}
assert_planner_dispatch_in_quick_step5
pass "quick workflow's planner-spawn step selects into==\"planner\" and forwards fragment.inline plus configValues"

printf '%s\n' 'ALL PASS'
