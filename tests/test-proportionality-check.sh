#!/usr/bin/env bash
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/hooks/proportionality-check.js"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH" 2>/dev/null' EXIT
mkdir -p "$SCRATCH/bin" "$SCRATCH/project/.planning"
printf '%s\n' '{"ponytail":{"enabled":true,"enforcement":"warn"}}' > "$SCRATCH/project/.planning/config.json"

cat > "$SCRATCH/bin/gsd-tools" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  ponytail.enabled) printf '%s\n' "${TEST_ENABLED:-true}" ;;
  ponytail.enforcement) printf '%s\n' "${TEST_ENFORCEMENT:-warn}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$SCRATCH/bin/gsd-tools"

cat > "$SCRATCH/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_LOG/gh"
[ -n "${GH_SLEEP:-}" ] && sleep "$GH_SLEEP"
[ "${GH_EXIT:-0}" -eq 0 ] || exit "$GH_EXIT"
if [ -n "${GH_RESPONSE:-}" ]; then printf '%s\n' "$GH_RESPONSE"; else printf '%s\n' '{"title":"bounded evidence"}'; fi
EOF
chmod +x "$SCRATCH/bin/gh"

cat > "$SCRATCH/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'call\n' >> "$TEST_LOG/claude"
[ -n "${CLAUDE_SLEEP:-}" ] && sleep "$CLAUDE_SLEEP"
[ "${CLAUDE_EXIT:-0}" -eq 0 ] || exit "$CLAUDE_EXIT"
if [ -n "${CLAUDE_RESPONSE:-}" ]; then printf '%s\n' "$CLAUDE_RESPONSE"; else printf '%s\n' '{"route":"quick","confidence":0.9,"reason":"bounded change"}'; fi
EOF
chmod +x "$SCRATCH/bin/claude"

for isolated in no-gh no-claude; do
  mkdir -p "$SCRATCH/bin-$isolated"
  ln -s "$(command -v bash)" "$SCRATCH/bin-$isolated/bash"
  ln -s "$(command -v node)" "$SCRATCH/bin-$isolated/node"
  ln -s "$SCRATCH/bin/gsd-tools" "$SCRATCH/bin-$isolated/gsd-tools"
done
ln -s "$SCRATCH/bin/claude" "$SCRATCH/bin-no-gh/claude"
ln -s "$SCRATCH/bin/gh" "$SCRATCH/bin-no-claude/gh"

run_hook() {
  local input="$1"
  OUT="$(printf '%s' "$input" | env \
    PATH="${RUN_PATH_OVERRIDE:-$SCRATCH/bin:$PATH}" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    TEST_ENABLED="${TEST_ENABLED:-true}" \
    TEST_ENFORCEMENT="${TEST_ENFORCEMENT:-warn}" \
    TEST_LOG="$SCRATCH" \
    GH_SLEEP="${GH_SLEEP:-}" GH_EXIT="${GH_EXIT:-0}" GH_RESPONSE="${GH_RESPONSE:-}" \
    CLAUDE_SLEEP="${CLAUDE_SLEEP:-}" CLAUDE_EXIT="${CLAUDE_EXIT:-0}" CLAUDE_RESPONSE="${CLAUDE_RESPONSE:-}" \
    node "$SCRIPT" 2>"$SCRATCH/stderr")"
  STATUS=$?
  ERR="$(cat "$SCRATCH/stderr")"
}

TARGET_MATCHER='^(gsd-new-project|gsd-new-milestone|gsd-manager|gsd-mvp-phase|gsd-discuss-phase)$'
node - "$REPO_ROOT/hooks/hooks.json" "$TARGET_MATCHER" <<'NODE' || fail "case1: exact UserPromptExpansion matcher missing"
const fs = require('fs');
const [file, expected] = process.argv.slice(2);
const hooks = JSON.parse(fs.readFileSync(file, 'utf8')).hooks.UserPromptExpansion;
if (!Array.isArray(hooks) || hooks.length !== 1 || hooks[0].matcher !== expected) process.exit(1);
NODE
run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"gsd-quick","command_args":"review issue","prompt":"review issue","cwd":"'"$SCRATCH/project"'"}'
[ "$STATUS" -eq 0 ] || fail "case1: non-target exited non-zero"
[ -z "$OUT$ERR" ] || fail "case1: non-target produced output"
pass "case1: exact allowlist and silent non-target"

run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"gsd-new-milestone","command_args":"review https://github.com/acme/widgets/issues/7","prompt":"review this issue only","cwd":"'"$SCRATCH/project"'"}'
[ "$STATUS" -eq 0 ] || fail "case2: small review exited non-zero"
node -e 'const v=JSON.parse(process.argv[1]); if(v.decision!=="block" || !/direct/.test(v.reason) || !["direct","quick","phase","milestone"].every(x=>v.reason.includes(x))) process.exit(1)' "$OUT" || fail "case2: default warn did not block with direct recommendation and route choices"
[ -z "$ERR" ] || fail "case2: small review wrote stderr"
pass "case2: default warn blocks clear direct mismatch"

run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"gsd-new-milestone","command_args":"plan a new project roadmap","prompt":"create a new project roadmap spanning several phases","cwd":"'"$SCRATCH/project"'"}'
[ "$STATUS" -eq 0 ] || fail "case3: milestone request exited non-zero"
if [ -n "$OUT" ]; then
  node -e 'const v=JSON.parse(process.argv[1]); if(v.decision==="block") process.exit(1)' "$OUT" || fail "case3: milestone request was blocked"
fi
[ -z "$ERR" ] || fail "case3: milestone request wrote stderr"
pass "case3: proportionate milestone request proceeds"

TEST_ENABLED=false run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"gsd-new-milestone","command_args":"review issue","prompt":"review issue","cwd":"'"$SCRATCH/project"'"}'
[ "$STATUS" -eq 0 ] || fail "case4: disabled hook exited non-zero"
[ -z "$OUT$ERR" ] || fail "case4: disabled hook produced output"
pass "case4: ponytail.enabled=false is silent"

: > "$SCRATCH/claude"
for request in \
  'create a new milestone spanning several phases' \
  'review this pull request' \
  'make a bounded atomic fix' \
  'continue the existing phase implementation'; do
  run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"gsd-new-milestone","command_args":"'"$request"'","prompt":"'"$request"'","cwd":"'"$SCRATCH/project"'"}'
  [ "$STATUS" -eq 0 ] || fail "case5: deterministic route exited non-zero"
done
[ ! -s "$SCRATCH/claude" ] || fail "case5: deterministic route invoked Claude"
pass "case5: all deterministic routes avoid Claude"

: > "$SCRATCH/claude"
CLAUDE_RESPONSE='{"route":"quick","confidence":0.9,"reason":"bounded change"}' run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"gsd-new-milestone","command_args":"help with widgets","prompt":"help with widgets","cwd":"'"$SCRATCH/project"'"}'
[ "$STATUS" -eq 0 ] || fail "case6: ambiguous classifier exited non-zero"
[ "$(wc -l < "$SCRATCH/claude")" -eq 1 ] || fail "case6: ambiguous request did not invoke Claude exactly once"
node -e 'const v=JSON.parse(process.argv[1]); if(v.decision!=="block" || !/quick/.test(v.reason)) process.exit(1)' "$OUT" || fail "case6: valid classifier route was not enforced"
pass "case6: ambiguity invokes Claude once and accepts valid schema"

: > "$SCRATCH/gh"
CLAUDE_RESPONSE='{"route":"milestone","confidence":0.8,"reason":"broad"}' run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"gsd-new-milestone","command_args":"consider https://github.com/acme/widgets/issues/7 https://github.com/acme/widgets/pull/8 https://github.com/acme/widgets/pull/8#pullrequestreview-9 https://github.com/acme/widgets/issues/7#issuecomment-10","prompt":"consider linked context","cwd":"'"$SCRATCH/project"'"}'
[ "$STATUS" -eq 0 ] || fail "case7: GitHub evidence request exited non-zero"
[ "$(wc -l < "$SCRATCH/gh")" -eq 4 ] || fail "case7: expected four GitHub lookups"
grep -qx 'api --method GET repos/acme/widgets/issues/7' "$SCRATCH/gh" || fail "case7: issue lookup was not GET"
grep -qx 'api --method GET repos/acme/widgets/pulls/8' "$SCRATCH/gh" || fail "case7: pull lookup was not GET"
grep -qx 'api --method GET repos/acme/widgets/pulls/8/reviews/9' "$SCRATCH/gh" || fail "case7: review lookup was not GET"
grep -qx 'api --method GET repos/acme/widgets/issues/comments/10' "$SCRATCH/gh" || fail "case7: issue-comment lookup was not GET"
pass "case7: recognized GitHub evidence uses GET endpoints"

TEST_ENFORCEMENT=advisory run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"gsd-new-milestone","command_args":"review this issue","prompt":"review this issue","cwd":"'"$SCRATCH/project"'"}'
node -e 'const v=JSON.parse(process.argv[1]); if(v.decision || !/direct/.test(v.additionalContext)) process.exit(1)' "$OUT" || fail "case8: advisory mismatch did not allow with context"
TEST_ENFORCEMENT=warn run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"gsd-new-milestone","command_args":"review this issue","prompt":"review this issue","cwd":"'"$SCRATCH/project"'"}'
node -e 'if(JSON.parse(process.argv[1]).decision!=="block") process.exit(1)' "$OUT" || fail "case8: warn mismatch did not block"
TEST_ENFORCEMENT=block run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"gsd-new-milestone","command_args":"review this issue","prompt":"review this issue","cwd":"'"$SCRATCH/project"'"}'
node -e 'const v=JSON.parse(process.argv[1]); if(v.decision!=="block" || !v.reason.includes("[ponytail:milestone]")) process.exit(1)' "$OUT" || fail "case8: block mismatch did not name override"
TEST_ENFORCEMENT=block run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"gsd-new-milestone","command_args":"create a new milestone spanning several phases","prompt":"create a new milestone spanning several phases","cwd":"'"$SCRATCH/project"'"}'
[ -z "$OUT$ERR" ] || fail "case8: block mode blocked proportionate work"
pass "case8: enforcement matrix"

TEST_ENFORCEMENT=block run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"gsd-new-milestone","command_args":"review this issue [ponytail:milestone]","prompt":"review this issue [ponytail:milestone]","cwd":"'"$SCRATCH/project"'"}'
[ -z "$OUT$ERR" ] || fail "case9: one-shot marker did not permit submission"
TEST_ENFORCEMENT=block run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"gsd-new-milestone","command_args":"review this issue","prompt":"review this issue","cwd":"'"$SCRATCH/project"'"}'
node -e 'if(JSON.parse(process.argv[1]).decision!=="block") process.exit(1)' "$OUT" || fail "case9: unmarked follow-up inherited override"
pass "case9: milestone marker is one-shot"

for command in gsd-new-project gsd-new-milestone gsd-manager gsd-mvp-phase gsd-discuss-phase; do
  run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"'"$command"'","command_args":"review this issue","prompt":"review this issue","cwd":"'"$SCRATCH/project"'"}'
  node -e 'if(JSON.parse(process.argv[1]).decision!=="block") process.exit(1)' "$OUT" || fail "case10: $command was not gated"
done
pass "case10: all five target commands enter decision path"

CONFIG_HASH="$(sha256sum "$SCRATCH/project/.planning/config.json" | cut -d' ' -f1)"
for mode in advisory warn block; do
  RUN_PATH_OVERRIDE="$SCRATCH/bin-no-claude" TEST_ENFORCEMENT="$mode" run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"gsd-new-milestone","command_args":"help with widgets","prompt":"help with widgets","cwd":"'"$SCRATCH/project"'"}'
  [ "$STATUS" -eq 0 ] || fail "case11: missing Claude exited non-zero in $mode"
  node -e 'const v=JSON.parse(process.argv[1]); if(v.decision || !v.additionalContext) process.exit(1)' "$OUT" || fail "case11: missing Claude did not fail open in $mode"
done

for response in 'not-json' '{"route":"bogus","confidence":0.8,"reason":"bad"}' '{"route":"quick","confidence":"high","reason":"bad"}' '{"route":"quick","confidence":0.2,"reason":"insufficient evidence"}'; do
  CLAUDE_RESPONSE="$response" run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"gsd-new-milestone","command_args":"help with widgets","prompt":"help with widgets","cwd":"'"$SCRATCH/project"'"}'
  node -e 'const v=JSON.parse(process.argv[1]); if(v.decision || !v.additionalContext) process.exit(1)' "$OUT" || fail "case11: invalid classifier output did not fail open"
done

CLAUDE_EXIT=2 run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"gsd-new-milestone","command_args":"help with widgets","prompt":"help with widgets","cwd":"'"$SCRATCH/project"'"}'
node -e 'const v=JSON.parse(process.argv[1]); if(v.decision || !v.additionalContext) process.exit(1)' "$OUT" || fail "case11: Claude error did not fail open"

RUN_PATH_OVERRIDE="$SCRATCH/bin-no-gh" run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"gsd-new-milestone","command_args":"consider https://github.com/acme/widgets/issues/7","prompt":"consider linked context","cwd":"'"$SCRATCH/project"'"}'
node -e 'const v=JSON.parse(process.argv[1]); if(v.decision || !v.additionalContext) process.exit(1)' "$OUT" || fail "case11: missing gh did not fail open"

GH_EXIT=2 run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"gsd-new-milestone","command_args":"consider https://github.com/acme/widgets/issues/7","prompt":"consider linked context","cwd":"'"$SCRATCH/project"'"}'
node -e 'const v=JSON.parse(process.argv[1]); if(v.decision || !v.additionalContext) process.exit(1)' "$OUT" || fail "case11: gh error did not fail open"

START="$(date +%s)"
GH_SLEEP=4 run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"gsd-new-milestone","command_args":"consider https://github.com/acme/widgets/issues/7","prompt":"consider linked context","cwd":"'"$SCRATCH/project"'"}'
ELAPSED=$(( $(date +%s) - START ))
[ "$ELAPSED" -ge 2 ] && [ "$ELAPSED" -le 3 ] || fail "case11: gh timeout was not three seconds"
node -e 'const v=JSON.parse(process.argv[1]); if(v.decision || !v.additionalContext) process.exit(1)' "$OUT" || fail "case11: gh timeout did not fail open"

START="$(date +%s)"
CLAUDE_SLEEP=4 run_hook '{"hook_event_name":"UserPromptExpansion","command_name":"gsd-new-milestone","command_args":"help with widgets","prompt":"help with widgets","cwd":"'"$SCRATCH/project"'"}'
ELAPSED=$(( $(date +%s) - START ))
[ "$ELAPSED" -ge 2 ] && [ "$ELAPSED" -le 3 ] || fail "case11: Claude timeout was not finite"
node -e 'const v=JSON.parse(process.argv[1]); if(v.decision || !v.additionalContext) process.exit(1)' "$OUT" || fail "case11: Claude timeout did not fail open"

[ "$CONFIG_HASH" = "$(sha256sum "$SCRATCH/project/.planning/config.json" | cut -d' ' -f1)" ] || fail "case11: hook changed project config"
[ "$(find "$SCRATCH/project" -type f | wc -l)" -eq 1 ] || fail "case11: hook created project artifacts"
pass "case11: failures fail open and project tree stays unchanged"

echo "ALL PASS"
