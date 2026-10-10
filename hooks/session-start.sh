#!/usr/bin/env bash
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# SessionStart runs with no role argument; SubagentStart passes planner|executor|verifier.
[ -n "${1:-}" ] || bash "$PLUGIN_ROOT/hooks/capability-auto-install.sh" ponytail || true

if [ -f "$PLUGIN_ROOT/hooks/gsd-tools.sh" ]; then
  . "$PLUGIN_ROOT/hooks/gsd-tools.sh"
  ENABLED="$(gsd_tools config-get ponytail.enabled --default true 2>/dev/null)"; ENABLED_STATUS=$?
  if [ "$ENABLED_STATUS" -eq 127 ]; then
    ENABLED=true
  elif [ "$ENABLED_STATUS" -ne 0 ]; then
    echo "ponytail: gsd_tools config-get ponytail.enabled failed (exit $ENABLED_STATUS); disabling advisory banner" >&2
    ENABLED=false
  fi
  LEVEL="$(gsd_tools config-get ponytail.level --default full 2>/dev/null)"; LEVEL_STATUS=$?
  if [ "$LEVEL_STATUS" -ne 0 ]; then
    [ "$LEVEL_STATUS" -eq 127 ] || echo "ponytail: gsd_tools config-get ponytail.level failed (exit $LEVEL_STATUS); using default" >&2
    LEVEL=full
  fi
else
  ENABLED=true
  LEVEL=full
fi
ENABLED="$(printf '%s' "$ENABLED" | tr -d '"')"
LEVEL="$(printf '%s' "$LEVEL" | tr -d '"')"

if [ "$ENABLED" != "true" ]; then
  exit 0
fi

case "$LEVEL" in
  lite|full|ultra) ;;
  *) LEVEL=full ;;
esac

ROLE="${1:-}"
case "$ROLE" in
  planner|executor|verifier) ;;
  *) ROLE=generic ;;
esac

# Upstream ponytail (DietrichGebert/ponytail) already injects the ladder while its mode flag
# exists; the same flag path its runtime reads, per project when CLAUDE_PROJECT_DIR is set.
UPSTREAM_FLAG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.ponytail-active"
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  PROJECT_KEY="$(node -p 'require("crypto").createHash("sha256").update(require("path").normalize(process.argv[1])).digest("hex")' "$CLAUDE_PROJECT_DIR" 2>/dev/null)"
  UPSTREAM_FLAG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ponytail-modes/$PROJECT_KEY"
fi
UPSTREAM=false
if [ -n "${PROJECT_KEY-x}" ] && [ -f "$UPSTREAM_FLAG" ]; then
  UPSTREAM_MODE="$(tr -d '[:space:]' < "$UPSTREAM_FLAG")"
  [ -n "$UPSTREAM_MODE" ] && [ "$UPSTREAM_MODE" != off ] && UPSTREAM=true
fi

COLLAB='Treat malformed or missing collaborator output as a failure and report it. Format, style, and quality failures are non-blocking only when safe continuation preserves artifact integrity and all external contracts. When evidenced, required findings: unhandled edge cases, ignored return values, swallowed errors, invalid boundary inputs, lazy structure, and plan-transcription code. Suggestions: evidence-backed performance, testing, intent, and minor-style concerns. Non-waivable blockers: security, trust-boundary, data-loss, race, accessibility, source/document divergence, constructor-divergence, ASVS, and TDD. End with Not checked: what you did not read or run.'

case "$ROLE" in
  planner) FRAMING='Planning: pick the laziest viable task shape — fewest files, fewest new artifacts; drop tasks whose need is speculative. Plan a task for every caller, test, fixture, config and export the change must reach.' ;;
  executor) FRAMING='Executing: climb the ladder before writing code — reuse before writing, stdlib before dependencies, shortest working diff. Before writing, list every caller, test, fixture, config and export the change must reach; be lazy about the solution, never about the change. Mark a known-limit shortcut with a comment `shortcut: <limit>, <when to upgrade>`. New logic gets one small test. Bug fix: grep every caller, fix the root cause once. End the reply with what you skipped or did not check, and any risk.' ;;
  verifier) FRAMING='Verifying collaborator output: flag unrequested abstractions, speculative flexibility, and interfaces with a single implementation.' ;;
  *) FRAMING='Prefer the laziest solution that actually works — deletion over addition, boring over clever.' ;;
esac

RUNGS='1. Does this need to exist at all? YAGNI. Name any skipped feature in one line; a vague request gets the smallest version that does the core job
2. Already in this codebase? Reuse it, the way the surrounding code does
3. Stdlib or native platform feature? Use it, unless the project has its own: a house component beats a native widget
4. Already-installed dependency solves it? Use it; add one only when a few lines cannot
5. Can it be one line? One line
6. Only then: the minimum code that works
Stop at the first rung that holds.'

case "$LEVEL" in
  lite) BODY='Build what was asked. Name the smaller option in one line.' ;;
  ultra) BODY="$RUNGS
Question the request: push back on any part the need does not justify." ;;
  *) BODY="$RUNGS" ;;
esac

FLOORS='Floors, always kept: input validation at trust boundaries, error handling that prevents data loss, security controls, accessibility basics, anything explicitly requested. Moved or merged code keeps its error handling and validation.'

if [ "$UPSTREAM" = true ]; then
  # Ladder already delivered upstream; only the gsd-specific verifier contract remains.
  [ "$ROLE" = verifier ] || exit 0
  TEXT="$COLLAB"
elif [ "$ROLE" = verifier ]; then
  TEXT="$(printf 'PONYTAIL LADDER — ladder findings are advisory (level: %s)\n%s %s\n%s\n%s\n' "$LEVEL" "$FRAMING" "$COLLAB" "$BODY" "$FLOORS")"
else
  TEXT="$(printf 'PONYTAIL LADDER — advisory, not a gate (level: %s)\n%s\n%s\n%s\n' "$LEVEL" "$FRAMING" "$BODY" "$FLOORS")"
fi

if [ "$ROLE" = generic ]; then
  printf '%s\n' "$TEXT"
else
  # SubagentStart reads context only from hookSpecificOutput.additionalContext.
  node -e 'process.stdout.write(JSON.stringify({hookSpecificOutput:{hookEventName:"SubagentStart",additionalContext:process.argv[1]}}))' "$TEXT" 2>/dev/null
fi

exit 0
