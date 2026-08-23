#!/usr/bin/env bash
# Contract proof for Ponytail's native plan-review contribution (issue #4).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAPABILITY_SOURCE="$REPO_ROOT/.gsd/capabilities/ponytail"
MANIFEST="$CAPABILITY_SOURCE/capability.json"
FRAGMENT="$CAPABILITY_SOURCE/fragments/checker-proportionality.md"
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
  if [ -n "$GSD_COMMAND" ]; then "$GSD_COMMAND" "$@"; else node "$GSD_CJS" "$@"; fi
}

[ -f "$FRAGMENT" ] || fail "checker proportionality fragment missing"

assert_static_contract() {
  jq -e '
    .version == "0.4.0" and
    (.config["ponytail.enforcement"].description | contains("Claude Code command-expansion decisions") and contains("plan-review checker severity outcomes")) and
    ([.contributions[] | select(
      .point == "plan:pre" and .into == "checker" and
      .produces == [] and .consumes == [] and
      .fragment.path == "fragments/checker-proportionality.md" and
      .when == "ponytail.enabled" and
      .configValues.enforcement == "ponytail.enforcement" and
      .onError == "skip"
    )] | length == 1)
  ' "$MANIFEST" >/dev/null || fail "checker contribution contract differs"
  for text in \
    'behavior identity is mechanism bytes plus invocation argv plus control-path semantics' \
    'byte-identical mechanisms with the same argv and control path need static identity proof plus one representative execution' \
    'different argv or control paths are distinct behaviors and each needs one execution' \
    'Do not shrink the product being verified to make the proof cheaper.' \
    'advisory -> info' \
    'warn -> warning' \
    'block -> blocker'; do
    grep -Fqx "$text" "$FRAGMENT" >/dev/null || fail "fragment missing exact contract: $text"
  done
  for text in \
    'violated property' \
    'evidence' \
    'fix_hint' \
    'non-binding' \
    'open-gsd/gsd-core#3771'; do
    grep -Fq "$text" "$FRAGMENT" >/dev/null || fail "fragment missing contract token: $text"
  done
}

write_config() {
  local project="$1" enabled="$2" enforcement="$3"
  jq -n --argjson enabled "$enabled" --arg enforcement "$enforcement" \
    '{runtime:"codex", ponytail:{enabled:$enabled, enforcement:$enforcement}}' \
    > "$project/.planning/config.json"
}

install_project() {
  local name="$1" enabled="$2" enforcement="$3"
  PROJECT="$SCRATCH/project-$name"
  GSD_HOME_DIR="$SCRATCH/gsd-home-$name"
  mkdir -p "$PROJECT/.planning" "$GSD_HOME_DIR"
  git -C "$PROJECT" init -q
  write_config "$PROJECT" "$enabled" "$enforcement"
  GSD_HOME="$GSD_HOME_DIR" gsd_tools capability install "$CAPABILITY_SOURCE" \
    --scope project --yes --cwd "$PROJECT" --raw >/dev/null
}

render_checker() {
  GSD_HOME="$2" gsd_tools loop render-hooks plan:pre --raw --cwd "$1"
}

assert_registry_contract() {
  local raw="$1" enforcement="$2"
  [ "$(printf '%s' "$raw" | jq -r '.point')" = "plan:pre" ] \
    || fail "render envelope point differs from plan:pre"
  [ "$(printf '%s' "$raw" | jq '[.activeHooks[] | select(.capId == "ponytail" and .kind == "contribution" and .into == "checker")] | length')" = 1 ] \
    || fail "expected exactly one active Ponytail checker contribution"
  local hook
  hook="$(printf '%s' "$raw" | jq -c '.activeHooks[] | select(.capId == "ponytail" and .kind == "contribution" and .into == "checker")')"
  [ "$(printf '%s' "$hook" | jq -r '.configValues.enforcement')" = "$enforcement" ] \
    || fail "resolved enforcement differs for $enforcement"
  printf '%s' "$hook" | jq -jr '.fragment.inline' > "$SCRATCH/rendered-$enforcement.md"
  cmp -s "$FRAGMENT" "$SCRATCH/rendered-$enforcement.md" \
    || fail "rendered checker fragment differs from source for $enforcement"
}

assert_static_contract
pass "schema declaration and static checker contract"

for enforcement in advisory warn block; do
  install_project "$enforcement" true "$enforcement"
  RAW="$(render_checker "$PROJECT" "$GSD_HOME_DIR")"
  assert_registry_contract "$RAW" "$enforcement"
done
pass "real registry exposes one byte-identical checker fragment for every public enforcement"

install_project disabled false warn
RAW="$(render_checker "$PROJECT" "$GSD_HOME_DIR")"
[ "$(printf '%s' "$RAW" | jq '[.activeHooks[] | select(.capId == "ponytail" and .kind == "contribution" and .into == "checker")] | length')" = 0 ] \
  || fail "disabled Ponytail exposed a checker contribution"
pass "disabled Ponytail is silent"

RESOLVER="$SCRATCH/resolver.sh"
SPY_LOG="$SCRATCH/spy.log"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\\n" "$*" >> "$SPY_LOG"' \
  > "$RESOLVER"
chmod +x "$RESOLVER"
cp -f "$RESOLVER" "$SCRATCH/resolver-copy.sh"
cmp -s "$RESOLVER" "$SCRATCH/resolver-copy.sh" || fail "same-behavior copies differ"
[ "$(sha256sum "$RESOLVER" | cut -d' ' -f1)" = "$(sha256sum "$SCRATCH/resolver-copy.sh" | cut -d' ' -f1)" ] \
  || fail "same-behavior copy hashes differ"
SPY_LOG="$SPY_LOG" "$RESOLVER" check --mode full
[ "$(cat "$SPY_LOG")" = 'check --mode full' ] || fail "same behavior did not execute one representative exactly once"
pass "static identity plus one representative execution covers equal behavior"

: > "$SPY_LOG"
SPY_LOG="$SPY_LOG" "$RESOLVER" check --mode lite
SPY_LOG="$SPY_LOG" "$SCRATCH/resolver-copy.sh" check --mode full
[ "$(cat "$SPY_LOG")" = $'check --mode lite\ncheck --mode full' ] \
  || fail "distinct argv tails were not each executed once in order"
pass "distinct argv behavior executes once per tail"

jq -e '.version == "0.4.0"' "$REPO_ROOT/.claude-plugin/plugin.json" >/dev/null \
  || fail "plugin version is not 0.4.0"
grep -Fq 'test-plan-review-contribution.sh' "$REPO_ROOT/.github/workflows/ci.yml" \
  || fail "CI does not run focused contribution test"
grep -Fq 'open-gsd/gsd-core#3771' "$REPO_ROOT/README.md" \
  || fail "README omits #3771 dispatch boundary"
grep -Fq 'open-gsd/gsd-core#3771' "$CAPABILITY_SOURCE/NOTES.md" \
  || fail "NOTES omits #3771 dispatch boundary"
grep -Fiq 're-consent' "$REPO_ROOT/README.md" \
  || fail "README omits re-consent consequence"
grep -Fiq 're-consent' "$CAPABILITY_SOURCE/NOTES.md" \
  || fail "NOTES omits re-consent consequence"
pass "metadata, CI, and honest reach documentation are synchronized"

printf '%s\n' 'ALL PASS'
