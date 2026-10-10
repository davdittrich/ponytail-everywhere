#!/usr/bin/env bash
# Smoke test (N5; needs bash, jq, node): no framework, no fixtures dir. Every config case
# runs against a scratch project dir under mktemp -d — this repo's own project
# config is never written to (review finding 2).
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/hooks/session-start.sh"
PLUGIN_DIR="$REPO_ROOT"
HOOKS="$REPO_ROOT/hooks/hooks.json"
README="$REPO_ROOT/README.md"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Tidiness net for an abrupt kill mid-case; explicit run_and_cleanup below is
# the normal path and does not depend on this trap.
trap '[ -n "${SCRATCH:-}" ] && rm -rf "$SCRATCH" 2>/dev/null; rm -rf "${CFG_DIR:-}" "${FAKE_ROOT:-}" 2>/dev/null' EXIT

# Hermetic Claude config dir: keeps a real upstream ponytail flag out of every case.
# gsd-core is linked in only so a host without gsd-tools on PATH still resolves it.
REAL_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CFG_DIR="$(mktemp -d)"
[ -d "$REAL_CFG/gsd-core" ] && ln -s "$REAL_CFG/gsd-core" "$CFG_DIR/gsd-core"
export CLAUDE_CONFIG_DIR="$CFG_DIR"
unset CLAUDE_PROJECT_DIR

# ctx: SubagentStart roles print a JSON envelope; print its additionalContext as text.
ctx() { printf '%s' "$1" | jq -er '.hookSpecificOutput.additionalContext'; }

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

# --- Case 1: level=lite -> build-as-asked line, distinct from full banner ---
mk_scratch '{"ponytail": {"enabled": true, "level": "lite"}}'
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT")"
run_and_cleanup
echo "$OUT" | grep -q 'Build what was asked\. Name the smaller option in one line\.' || fail "case1: lite banner missing build-as-asked line"
echo "$OUT" | grep -q '^1\. Does this need to exist at all' && fail "case1: lite banner still contains full rung list"
pass "case1: level=lite condensed banner"

# --- Case 2: level=full -> six-rung banner ---
mk_scratch '{"ponytail": {"enabled": true, "level": "full"}}'
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT")"
run_and_cleanup
echo "$OUT" | grep -q '^1\. Does this need to exist at all' || fail "case2: full banner missing six-rung list"
echo "$OUT" | grep -q 'level: full' || fail "case2: full banner missing level: full heading"
pass "case2: level=full six-rung banner"

# --- Case 3: level=ultra -> full banner + question-the-request line ---
mk_scratch '{"ponytail": {"enabled": true, "level": "ultra"}}'
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT")"
run_and_cleanup
echo "$OUT" | grep -q '^1\. Does this need to exist at all' || fail "case3: ultra banner missing six-rung list"
echo "$OUT" | grep -q 'Question the request: push back on any part the need does not justify\.' || fail "case3: ultra banner missing question-the-request line"
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
OUT="$(ctx "$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT" planner)")"
run_and_cleanup
echo "$OUT" | grep -q 'laziest viable task shape' || fail "case5: planner framing line missing"
echo "$OUT" | grep -q 'climb the ladder' && fail "case5: executor framing line leaked into planner banner"
pass "case5: ROLE=planner framing"

# --- Case 6: ROLE=executor -> executor framing line ---
mk_scratch '{"ponytail": {"enabled": true, "level": "full"}}'
OUT="$(ctx "$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT" executor)")"
run_and_cleanup
echo "$OUT" | grep -q 'climb the ladder' || fail "case6: executor framing line missing"
pass "case6: ROLE=executor framing"

# --- Case 7: ROLE=verifier -> verifier framing line ---
mk_scratch '{"ponytail": {"enabled": true, "level": "full"}}'
OUT="$(ctx "$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT" verifier)")"
run_and_cleanup
echo "$OUT" | grep -q 'flag unrequested abstractions' || fail "case7: verifier framing line missing"
echo "$OUT" | grep -q 'malformed or missing collaborator output' || fail "case7: malformed collaborator output contract missing"
echo "$OUT" | grep -q 'safe continuation preserves artifact integrity and all external contracts' || fail "case7: conditional non-blocking contract missing"
echo "$OUT" | grep -q 'When evidenced, required findings: unhandled edge cases, ignored return values, swallowed errors, invalid boundary inputs, lazy structure, and plan-transcription code' || fail "case7: evidenced required finding classes missing"
echo "$OUT" | grep -q 'Suggestions: evidence-backed performance, testing, intent, and minor-style concerns' || fail "case7: suggestion classes missing"
echo "$OUT" | grep -q 'Non-waivable blockers: security, trust-boundary, data-loss, race, accessibility, source/document divergence, constructor-divergence, ASVS, and TDD' || fail "case7: non-waivable blocker classes missing"
pass "case7: ROLE=verifier framing"

# --- Case 7a: reviewer and verifier route independently through verifier framing ---
jq -e '([.hooks.SubagentStart[] | select(.matcher == "gsd-code-reviewer") | .hooks[] | select(.command == "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh\" verifier")] | length == 1) and ([.hooks.SubagentStart[] | select(.matcher == "gsd-verifier") | .hooks[] | select(.command == "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh\" verifier")] | length == 1)' "$HOOKS" >/dev/null || fail "case7a: reviewer/verifier SubagentStart routing mismatch"
grep -Fq 'Claude-only' "$README" || fail "case7a: README Claude-only boundary missing"
grep -Fq 'https://github.com/davdittrich/ponytail-everywhere/issues/3' "$README" || fail "case7a: README runtime-neutral follow-up missing"
grep -Fq 'unhandled edge cases' "$README" || fail "case7a: README required finding classes missing"
grep -Fq 'evidence-backed performance' "$README" || fail "case7a: README suggestion classes missing"
grep -Fq 'When evidenced, required findings' "$README" || fail "case7a: README evidence condition missing"
grep -Fq 'source/document divergence' "$README" || fail "case7a: README source/document divergence missing"
jq -e '.version == "0.9.1"' "$REPO_ROOT/.claude-plugin/plugin.json" >/dev/null || fail "case7a: plugin version is not 0.9.1"
jq -e '.version == "0.9.1"' "$REPO_ROOT/capability.json" >/dev/null || fail "case7a: capability version is not 0.9.1"
pass "case7a: reviewer/verifier routing, README, and version contracts"

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
ln -s "$REAL_CFG/gsd-core/bin/gsd-tools.cjs" "$SPACE_HOME/gsd-core/bin/gsd-tools.cjs"
mk_scratch '{"ponytail": {"enabled": false, "level": "full"}}'
OUT="$(CLAUDE_CONFIG_DIR="$SPACE_HOME" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT")"
STATUS=$?
run_and_cleanup
rm -rf "${SPACE_HOME%/*}"
[ -z "$OUT" ] || fail "case11: enabled=false via space-path CLAUDE_CONFIG_DIR produced output (CR-01 word-split regression)"
[ "$STATUS" -eq 0 ] || fail "case11: enabled=false via space-path CLAUDE_CONFIG_DIR exited non-zero"
pass "case11: CLAUDE_CONFIG_DIR containing a space resolves correctly (CR-01 regression)"

# --- Case 12: roles emit a valid SubagentStart envelope; the no-arg run stays plain text ---
mk_scratch '{"ponytail": {"enabled": true, "level": "full"}}'
for role in planner executor verifier; do
  RAW="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT" $role)"
  printf '%s' "$RAW" | jq -e '.hookSpecificOutput.hookEventName == "SubagentStart" and (.hookSpecificOutput.additionalContext | startswith("PONYTAIL LADDER"))' >/dev/null || fail "case12: $role did not emit a SubagentStart envelope"
done
RAW="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT")"
printf '%s' "$RAW" | jq -e . >/dev/null 2>&1 && fail "case12: SessionStart output became JSON"
run_and_cleanup
pass "case12: SubagentStart envelope, SessionStart plain text"

# --- Case 13: auto-install runs at SessionStart only ---
FAKE_ROOT="$(mktemp -d)"
mkdir -p "$FAKE_ROOT/hooks"
cp "$REPO_ROOT/hooks/session-start.sh" "$REPO_ROOT/hooks/gsd-tools.sh" "$FAKE_ROOT/hooks/"
printf '#!/usr/bin/env bash\ntouch "%s/installed"\n' "$FAKE_ROOT" > "$FAKE_ROOT/hooks/capability-auto-install.sh"
mk_scratch '{"ponytail": {"enabled": true, "level": "full"}}'
CLAUDE_PLUGIN_ROOT="$FAKE_ROOT" bash "$FAKE_ROOT/hooks/session-start.sh" executor >/dev/null
[ ! -e "$FAKE_ROOT/installed" ] || fail "case13: role run invoked auto-install"
CLAUDE_PLUGIN_ROOT="$FAKE_ROOT" bash "$FAKE_ROOT/hooks/session-start.sh" >/dev/null
[ -e "$FAKE_ROOT/installed" ] || fail "case13: SessionStart skipped auto-install"
run_and_cleanup
rm -rf "$FAKE_ROOT"
pass "case13: auto-install only at SessionStart"

# --- Case 14: active upstream ponytail owns the ladder; verifier keeps the gsd contract ---
mk_scratch '{"ponytail": {"enabled": true, "level": "full"}}'
printf 'full' > "$CFG_DIR/.ponytail-active"
for role in "" planner executor; do
  OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT" $role)"
  [ -z "$OUT" ] || fail "case14: upstream active, ${role:-generic} still printed a banner"
done
OUT="$(ctx "$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT" verifier)")"
echo "$OUT" | grep -q 'Non-waivable blockers' || fail "case14: verifier lost the collaborator contract"
echo "$OUT" | grep -q 'Does this need to exist at all' && fail "case14: verifier still carries the ladder"
echo "$OUT" | grep -q 'Not checked' || fail "case14: verifier banner missing Not checked line"
printf 'off' > "$CFG_DIR/.ponytail-active"
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT")"
echo "$OUT" | grep -q 'level: full' || fail "case14: an off flag silenced the banner"
rm -f "$CFG_DIR/.ponytail-active"
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT")"
echo "$OUT" | grep -q 'level: full' || fail "case14: banner missing once the upstream flag is gone"
PROJ="$SCRATCH/proj"
mkdir -p "$CFG_DIR/ponytail-modes"
printf 'ultra' > "$CFG_DIR/ponytail-modes/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
OUT="$(CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT")"
[ -z "$OUT" ] || fail "case14: per-project upstream flag ignored"
OUT="$(CLAUDE_PROJECT_DIR="$SCRATCH/other" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT")"
echo "$OUT" | grep -q 'level: full' || fail "case14: another project's upstream flag silenced this project"
run_and_cleanup
pass "case14: upstream flag skips the ladder, shared and per-project"

# --- Case 15: shared rule lines reach every role ---
mk_scratch '{"ponytail": {"enabled": true, "level": "full"}}'
for role in planner executor; do
  OUT="$(ctx "$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT" $role)")"
  echo "$OUT" | grep -q 'every caller, test, fixture, config and export' || fail "case15: $role missing touch-point rule"
  echo "$OUT" | grep -q 'Moved or merged code keeps its error handling and validation' || fail "case15: $role missing moved-code floor"
done
OUT="$(ctx "$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT" executor)")"
echo "$OUT" | grep -Fq 'shortcut: <limit>, <when to upgrade>' || fail "case15: executor missing shortcut comment rule"
echo "$OUT" | grep -q 'house component beats a native widget' || fail "case15: ladder missing house-component clause"
run_and_cleanup
pass "case15: touch-point, floors, shortcut and house-component rules"

# --- Case 16: fragments carry the same rules as the banner (they reach agents through gsd dispatch) ---
FRAG="$REPO_ROOT/fragments"
for f in planner executor verifier; do
  grep -Fq 'Floors, always kept:' "$FRAG/$f-ladder.md" || fail "case16: $f fragment missing floors line"
  grep -Fq 'Moved or merged code keeps its error handling and validation' "$FRAG/$f-ladder.md" || fail "case16: $f fragment missing moved-code floor"
done
for f in planner executor; do
  grep -Fq 'ultra also questions the request' "$FRAG/$f-ladder.md" || fail "case16: $f fragment ultra level not question-the-request"
  grep -Fq 'lite builds what was asked' "$FRAG/$f-ladder.md" || fail "case16: $f fragment lite level mismatch"
done
grep -Fq 'ultra also questions requested parts' "$FRAG/verifier-ladder.md" || fail "case16: verifier fragment ultra level mismatch"
grep -Fq 'lite flags only the most obvious' "$FRAG/verifier-ladder.md" || fail "case16: verifier fragment lite level mismatch"
for f in planner executor; do
  grep -Fq 'every caller, test, fixture, config and export' "$FRAG/$f-ladder.md" || fail "case16: $f fragment missing touch-point rule"
done
grep -Fq 'shortcut: <limit>, <when to upgrade>' "$FRAG/executor-ladder.md" || fail "case16: executor fragment missing shortcut rule"
grep -Fq 'zero gates' "$FRAG/verifier-ladder.md" && fail "case16: verifier fragment still says zero gates"
grep -Fq 'keep their severity' "$FRAG/verifier-ladder.md" || fail "case16: verifier fragment does not defer collaborator blockers"
grep -rEq 'Never simplify|/home/dd' "$FRAG" "$REPO_ROOT/tests" "$REPO_ROOT/hooks" --exclude=test-session-start.sh && fail "case16: stale wording or hardcoded home path remains"
pass "case16: fragments match banner rules"

# --- Case 17: HOME and CLAUDE_CONFIG_DIR unset under set -u -> no unbound-variable abort (gh-12) ---
for PROJ in "" "$PLUGIN_DIR"; do # "" -> line 47 flag path; set -> line 50 per-project path
  ENV_ERR="$(env -u HOME -u CLAUDE_CONFIG_DIR CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$SCRIPT" executor 2>&1 >/dev/null)"
  STATUS=$?
  [ "$STATUS" -eq 0 ] || fail "case17: HOME-unset run (project='$PROJ') exited $STATUS: $ENV_ERR"
  echo "$ENV_ERR" | grep -q 'unbound variable' && fail "case17: HOME-unset run (project='$PROJ') hit unbound variable: $ENV_ERR"
done
pass "case17: HOME and CLAUDE_CONFIG_DIR unset, no abort with or without CLAUDE_PROJECT_DIR"

echo "ALL PASS"
exit 0
