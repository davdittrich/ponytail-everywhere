#!/usr/bin/env bash
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/hooks/proportionality-check.js"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH" 2>/dev/null' EXIT
mkdir -p "$SCRATCH/bin" "$SCRATCH/project/.planning"

cat > "$SCRATCH/bin/gsd-tools" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  ponytail.enabled) printf '%s\n' "${TEST_ENABLED:-true}" ;;
  ponytail.enforcement) printf '%s\n' "${TEST_ENFORCEMENT:-warn}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$SCRATCH/bin/gsd-tools"

run_hook() {
  local input="$1"
  OUT="$(printf '%s' "$input" | env \
    PATH="$SCRATCH/bin:$PATH" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    TEST_ENABLED="${TEST_ENABLED:-true}" \
    TEST_ENFORCEMENT="${TEST_ENFORCEMENT:-warn}" \
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

echo "ALL PASS"
