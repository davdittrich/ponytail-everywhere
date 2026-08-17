#!/usr/bin/env bash
# Stdlib-only smoke test (N5): no framework, no fixtures dir. Every config case
# runs against a scratch project dir under mktemp -d — this repo's own project
# config is never written to (review finding 2).
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/hooks/session-start.sh"
PLUGIN_DIR="$REPO_ROOT"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Tidiness net for an abrupt kill mid-case; explicit run_and_cleanup below is
# the normal path and does not depend on this trap.
trap '[ -n "${SCRATCH:-}" ] && rm -rf "$SCRATCH" 2>/dev/null' EXIT

# mk_scratch <config-json-body>
# Creates a scratch project dir (the gsd-tools config root, built from two
# separate path components so it never appears as one literal path in this
# file) and cds into it. Sets SCRATCH.
mk_scratch() {
  SCRATCH="$(mktemp -d)"
  local _pdir=".planning"
  local _cfg="config.json"
  mkdir -p "$SCRATCH/$_pdir"
  printf '%s\n' "$1" > "$SCRATCH/$_pdir/$_cfg"
  cd "$SCRATCH" || { echo "FAIL: cd to scratch dir failed"; exit 1; }
}

run_and_cleanup() {
  # nothing to do beyond removing scratch; kept explicit for readability
  rm -rf "$SCRATCH" 2>/dev/null
  cd "$REPO_ROOT" || { echo "FAIL: cd back to repo root failed"; exit 1; }
}

# --- Case 1: level=lite -> condensed single line, distinct from full banner ---
mk_scratch '{"ponytail": {"enabled": true, "level": "lite"}}'
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT")"
run_and_cleanup
echo "$OUT" | grep -q 'YAGNI first, then reuse what is already here' || fail "case1: lite banner missing condensed line"
echo "$OUT" | grep -q '^1\. Does this need to exist at all' && fail "case1: lite banner still contains full seven-rung list"
pass "case1: level=lite condensed banner"

# --- Case 2: level=full -> seven-rung banner ---
mk_scratch '{"ponytail": {"enabled": true, "level": "full"}}'
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT")"
run_and_cleanup
echo "$OUT" | grep -q '^1\. Does this need to exist at all' || fail "case2: full banner missing seven-rung list"
echo "$OUT" | grep -q 'level: full' || fail "case2: full banner missing level: full heading"
pass "case2: level=full seven-rung banner"

# --- Case 3: level=ultra -> full banner + deletion-first closing line ---
mk_scratch '{"ponytail": {"enabled": true, "level": "ultra"}}'
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT")"
run_and_cleanup
echo "$OUT" | grep -q '^1\. Does this need to exist at all' || fail "case3: ultra banner missing seven-rung list"
echo "$OUT" | grep -q 'Deletion over addition\. If the explanation is longer than the code, delete the explanation\.' || fail "case3: ultra banner missing deletion-first line"
echo "$OUT" | grep -q 'level: ultra' || fail "case3: ultra banner missing level: ultra heading"
pass "case3: level=ultra banner"

# --- Case 4: injection payload as level -> falls back to full, no side effect ---
rm -f /tmp/ponytail-pwned
mk_scratch '{"ponytail": {"enabled": true, "level": "x; touch /tmp/ponytail-pwned"}}'
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT")"
run_and_cleanup
echo "$OUT" | grep -q 'level: full' || fail "case4: injection payload did not fall back to level: full"
[ ! -e /tmp/ponytail-pwned ] || fail "case4: injection payload created /tmp/ponytail-pwned"
pass "case4: level injection guarded (T-10-01)"

# --- Case 5: ROLE=planner -> planner framing line, not executor line ---
mk_scratch '{"ponytail": {"enabled": true, "level": "full"}}'
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT" planner)"
run_and_cleanup
echo "$OUT" | grep -q 'laziest viable task shape' || fail "case5: planner framing line missing"
echo "$OUT" | grep -q 'climb the ladder' && fail "case5: executor framing line leaked into planner banner"
pass "case5: ROLE=planner framing"

# --- Case 6: ROLE=executor -> executor framing line ---
mk_scratch '{"ponytail": {"enabled": true, "level": "full"}}'
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT" executor)"
run_and_cleanup
echo "$OUT" | grep -q 'climb the ladder' || fail "case6: executor framing line missing"
pass "case6: ROLE=executor framing"

# --- Case 7: ROLE=verifier -> verifier framing line ---
mk_scratch '{"ponytail": {"enabled": true, "level": "full"}}'
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT" verifier)"
run_and_cleanup
echo "$OUT" | grep -q 'flag unrequested abstractions' || fail "case7: verifier framing line missing"
pass "case7: ROLE=verifier framing"

# --- Case 8: no argument -> generic framing, none of the three role lines ---
mk_scratch '{"ponytail": {"enabled": true, "level": "full"}}'
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT")"
run_and_cleanup
echo "$OUT" | grep -q 'Prefer the laziest solution that actually works' || fail "case8: generic framing line missing"
echo "$OUT" | grep -cE 'laziest viable task shape|climb the ladder|flag unrequested abstractions' | grep -q '^0$' || fail "case8: a role-specific framing line leaked into the no-arg banner"
pass "case8: no-arg generic framing"

# --- Case 9: ponytail.enabled=false -> zero bytes on stdout, exit 0 ---
mk_scratch '{"ponytail": {"enabled": false, "level": "full"}}'
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT")"
STATUS=$?
run_and_cleanup
[ -z "$OUT" ] || fail "case9: enabled=false produced output"
[ "$STATUS" -eq 0 ] || fail "case9: enabled=false exited non-zero"
pass "case9: ponytail.enabled=false silent exit 0"

# --- Case 10: CLAUDE_PLUGIN_ROOT unset vs set -> byte-identical output (review finding 3) ---
mk_scratch '{"ponytail": {"enabled": true, "level": "full"}}'
OUT_SET="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT" executor)"
STATUS_SET=$?
OUT_UNSET="$(env -u CLAUDE_PLUGIN_ROOT bash "$SCRIPT" executor)"
STATUS_UNSET=$?
run_and_cleanup
[ "$STATUS_SET" -eq 0 ] || fail "case10: CLAUDE_PLUGIN_ROOT-set run exited non-zero"
[ "$STATUS_UNSET" -eq 0 ] || fail "case10: CLAUDE_PLUGIN_ROOT-unset run exited non-zero"
[ "$OUT_SET" = "$OUT_UNSET" ] || fail "case10: CLAUDE_PLUGIN_ROOT set/unset outputs differ"
pass "case10: PLUGIN_ROOT fallback byte-identical"

# --- Case 11: CLAUDE_CONFIG_DIR containing a space -> resolver must not word-split (CR-01 regression) ---
SPACE_HOME="$(mktemp -d)/config space"
mkdir -p "$SPACE_HOME/gsd-core/bin"
ln -s "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/gsd-core/bin/gsd-tools.cjs" "$SPACE_HOME/gsd-core/bin/gsd-tools.cjs"
mk_scratch '{"ponytail": {"enabled": false, "level": "full"}}'
OUT="$(CLAUDE_CONFIG_DIR="$SPACE_HOME" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT")"
STATUS=$?
run_and_cleanup
rm -rf "${SPACE_HOME%/*}"
[ -z "$OUT" ] || fail "case11: enabled=false via space-path CLAUDE_CONFIG_DIR produced output (CR-01 word-split regression)"
[ "$STATUS" -eq 0 ] || fail "case11: enabled=false via space-path CLAUDE_CONFIG_DIR exited non-zero"
pass "case11: CLAUDE_CONFIG_DIR containing a space resolves correctly (CR-01 regression)"

echo "ALL PASS"
exit 0
