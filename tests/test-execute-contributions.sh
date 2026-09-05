#!/usr/bin/env bash
# Reach proof for Ponytail's execute-point contributions (issue #3).
#
# Two independent claims, both required:
#   1. resolver  — the capability publishes exactly one byte-identical fragment per execute point.
#   2. host      — the installed gsd-core workflow has no landing site for those fragments,
#                  so they reach the orchestrator's context and neither target agent.
# Claim 2 is asserted against a positive control (the planner landing site) so that a probe
# broken by upstream rewording fails loudly instead of reporting a false absence.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAPABILITY_SOURCE="$REPO_ROOT/.gsd/capabilities/ponytail"
MANIFEST="$CAPABILITY_SOURCE/capability.json"
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
  fail "gsd-tools 1.12.0 or later is required"
fi

gsd_tools() {
  if [ -n "$GSD_COMMAND" ]; then "$GSD_COMMAND" "$@"; else node "$GSD_CJS" "$@"; fi
}

# Both shipped layouts put workflows next to bin/ under one gsd-core root:
# npm `package/gsd-core/{bin,workflows}` and the Codex install `<home>/gsd-core/{bin,workflows}`.
GSD_ROOT="$(dirname "$(dirname "$(readlink -f "$GSD_ENTRY")")")"
WORKFLOWS="$GSD_ROOT/workflows"
EXECUTE_WORKFLOW="$WORKFLOWS/execute-phase.md"
PLAN_WORKFLOW="$WORKFLOWS/plan-phase.md"
[ -f "$EXECUTE_WORKFLOW" ] || fail "no execute-phase workflow under $WORKFLOWS"
[ -f "$PLAN_WORKFLOW" ] || fail "no plan-phase workflow under $WORKFLOWS"

# --- claim 1: static declaration -------------------------------------------------

assert_static_contract() {
  local point="$1" role="$2" fragment="$3"
  [ -f "$CAPABILITY_SOURCE/$fragment" ] || fail "$role fragment missing at $fragment"
  jq -e --arg point "$point" --arg role "$role" --arg fragment "$fragment" '
    [.contributions[] | select(
      .point == $point and .into == $role and
      .produces == [] and .consumes == [] and
      .fragment.path == $fragment and
      .when == "ponytail.enabled" and
      .configValues.level == "ponytail.level" and
      .onError == "skip"
    )] | length == 1
  ' "$MANIFEST" >/dev/null || fail "$point -> $role contribution contract differs"
}

assert_static_contract execute:wave:pre executor fragments/executor-ladder.md
assert_static_contract execute:wave:post verifier fragments/verifier-ladder.md
pass "execute-point contributions declare one role-tailored fragment each"

# --- claim 1: real resolver ------------------------------------------------------

install_project() {
  local name="$1" enabled="$2" level="$3"
  PROJECT="$SCRATCH/project-$name"
  GSD_HOME_DIR="$SCRATCH/gsd-home-$name"
  mkdir -p "$PROJECT/.planning" "$GSD_HOME_DIR"
  git -C "$PROJECT" init -q
  jq -n --argjson enabled "$enabled" --arg level "$level" \
    '{runtime:"codex", ponytail:{enabled:$enabled, level:$level}}' \
    > "$PROJECT/.planning/config.json"
  GSD_HOME="$GSD_HOME_DIR" gsd_tools capability install "$CAPABILITY_SOURCE" \
    --scope project --yes --cwd "$PROJECT" --raw >/dev/null
}

count_hooks() {
  GSD_HOME="$GSD_HOME_DIR" gsd_tools loop render-hooks "$1" --raw --cwd "$PROJECT" \
    | jq --arg role "$2" '[.activeHooks[] | select(.capId == "ponytail" and .kind == "contribution" and .into == $role)] | length'
}

assert_enabled_fragment() {
  local point="$1" role="$2" fragment="$3" level="$4" raw hook
  raw="$(GSD_HOME="$GSD_HOME_DIR" gsd_tools loop render-hooks "$point" --raw --cwd "$PROJECT")"
  [ "$(printf '%s' "$raw" | jq -r '.point')" = "$point" ] || fail "render envelope point differs from $point"
  [ "$(printf '%s' "$raw" | jq --arg role "$role" '[.activeHooks[] | select(.capId == "ponytail" and .kind == "contribution" and .into == $role)] | length')" = 1 ] \
    || fail "expected exactly one active Ponytail $role contribution at $point"
  hook="$(printf '%s' "$raw" | jq -c --arg role "$role" '.activeHooks[] | select(.capId == "ponytail" and .kind == "contribution" and .into == $role)')"
  [ "$(printf '%s' "$hook" | jq -r '.configValues.level')" = "$level" ] \
    || fail "resolved level differs for $point at $level"
  printf '%s' "$hook" | jq -jr '.fragment.inline' > "$SCRATCH/rendered-$role-$level.md"
  cmp -s "$CAPABILITY_SOURCE/$fragment" "$SCRATCH/rendered-$role-$level.md" \
    || fail "rendered $role fragment differs from source at $level"
}

for level in lite full ultra; do
  install_project "$level" true "$level"
  assert_enabled_fragment execute:wave:pre executor fragments/executor-ladder.md "$level"
  assert_enabled_fragment execute:wave:post verifier fragments/verifier-ladder.md "$level"
done
pass "real registry exposes one byte-identical execute fragment per point for every public level"

install_project disabled false full
[ "$(count_hooks execute:wave:pre executor)" = 0 ] || fail "disabled Ponytail exposed an executor contribution"
[ "$(count_hooks execute:wave:post verifier)" = 0 ] || fail "disabled Ponytail exposed a verifier contribution"
pass "disabled Ponytail is silent at both execute points"

# --- claim 2: host reach ---------------------------------------------------------

DISPATCH='inject every `kind == "contribution"` fragment'
[ "$(grep -Fc "$DISPATCH" "$EXECUTE_WORKFLOW")" -ge 2 ] \
  || fail "host execute workflow lacks generic contribution dispatch at both wave points; gsd-core 1.12.0 or later is required"
pass "host dispatches contributions at execute:wave:pre and execute:wave:post"

# The execute workflow delegates to step files, so probe the whole tree, not the entry file.
EXECUTE_TREE=("$EXECUTE_WORKFLOW" "$WORKFLOWS/execute-plan.md" "$WORKFLOWS/execute-phase")
# Any quote style and both equality spellings, so a reworded landing site is still caught.
ROLE_SELECT='into[[:space:]]*===?[[:space:]]*["'"'"']'

# Positive control: this is how upstream spells role selection where a landing site does exist.
grep -Eq "$ROLE_SELECT" "$PLAN_WORKFLOW" \
  || fail "landing-site probe matched no role selection in the plan workflow; upstream reworded it and this probe is now blind"
pass "landing-site probe detects the planner landing site"

HIT="$(grep -Ern "$ROLE_SELECT" "${EXECUTE_TREE[@]}" 2>/dev/null || true)"
[ -z "$HIT" ] \
  || fail "execute workflow tree now selects a contribution role: $HIT — re-verify reach, then update NOTES.md and README.md in the same change"

# Second, syntax-independent predicate: any landing site must consume the wave hook envelope.
# Today each variable is referenced only where it is assigned (and, for wave:post, read).
for pair in "WAVE_PRE_HOOKS_JSON 1" "WAVE_POST_HOOKS_JSON 2"; do
  set -- $pair
  [ "$(grep -Fc "$1" "$EXECUTE_WORKFLOW")" = "$2" ] \
    || fail "$1 reference count in the execute workflow changed — a landing site may now consume it; re-verify reach, then update NOTES.md and README.md in the same change"
done
pass "no executor or verifier landing site: both execute contributions remain undelivered"

# --- documentation must match the evidence ---------------------------------------

NOTES="$CAPABILITY_SOURCE/NOTES.md"
for text in 'reach neither target agent' 'open-gsd/gsd-core#XXXX'; do
  grep -Fq "$text" "$NOTES" || fail "NOTES omits undelivered-reach contract: $text"
  grep -Fq "$text" "$REPO_ROOT/README.md" || fail "README omits undelivered-reach contract: $text"
done
grep -Fq 'test-execute-contributions.sh' "$REPO_ROOT/.github/workflows/ci.yml" \
  || fail "CI does not run the execute-point reach test"
grep -Eq '@opengsd/gsd-core@1\.(1[2-9]|[2-9][0-9])\.' "$REPO_ROOT/.github/workflows/ci.yml" \
  || fail "CI does not install a gsd-core with execute-point contribution dispatch"
pass "documentation and CI match the observed reach"

printf '%s\n' 'ALL PASS'
