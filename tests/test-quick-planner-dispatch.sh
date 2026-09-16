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
  [.contributions[] | select(
    .point == "plan:pre" and .into == "planner" and
    .produces == [] and .consumes == [] and
    .fragment.path == "fragments/planner-ladder.md" and
    .when == "ponytail.enabled" and
    .configValues.level == "ponytail.level" and
    .onError == "skip"
  )] | length == 1
' "$MANIFEST" >/dev/null || fail "plan:pre -> planner contribution contract differs"
pass "planner contribution declares fragment, gate, and level configValue"

for text in \
  'Historical context may guide discovery but cannot authorize concrete mutable scope without a current task-relevant observation.' \
  'Explicit user-fixed scope and immutable inputs remain concrete without a precondition.' \
  'When plan-time evidence may drift before execution, use one concrete read-only task-local <precondition> immediately before mutation.' \
  'Do not add a precondition for facts produced by the task or intra-plan ordering already represented by depends_on.'; do
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

DISPATCH='into[[:space:]]*===?[[:space:]]*["'"'"'$]'
grep -Eq "$DISPATCH" "$PLAN_WORKFLOW" \
  || fail "landing-site probe matched no role selection in the plan workflow; upstream reworded it and this probe is now blind"
grep -Eq "$DISPATCH" "$QUICK_WORKFLOW" \
  || fail "landing-site probe matched no role selection in the quick workflow; native Quick dispatch (#5, gsd-core b848b23) may have regressed"
pass "planner landing site present in both plan-phase.md and quick.md"

grep -Fq 'render-hooks plan:pre' "$QUICK_WORKFLOW" \
  || fail "quick workflow no longer renders plan:pre hooks"
grep -Fq 'fragment.inline' "$QUICK_WORKFLOW" \
  || fail "quick workflow no longer injects fragment.inline verbatim"
pass "quick workflow dispatches plan:pre contributions the same way plan-phase.md does"

printf '%s\n' 'ALL PASS'
