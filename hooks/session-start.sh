#!/usr/bin/env bash
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

bash "$PLUGIN_ROOT/hooks/capability-auto-install.sh" ponytail || true

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

case "$ROLE" in
  planner) FRAMING='Planning: pick the laziest viable task shape — fewest files, fewest new artifacts; drop tasks whose need is speculative.' ;;
  executor) FRAMING='Executing: climb the ladder before writing code — reuse before writing, stdlib before dependencies, shortest working diff.' ;;
  verifier) FRAMING='Verifying: flag unrequested abstractions, speculative flexibility, and interfaces with a single implementation.' ;;
  *) FRAMING='Prefer the laziest solution that actually works — deletion over addition, boring over clever.' ;;
esac

RUNGS='1. Does this need to exist at all? YAGNI
2. Already in this codebase? Reuse it
3. Stdlib does it? Use it
4. Native platform feature covers it? Use it
5. Already-installed dependency solves it? Use it — never add one for what a few lines can do
6. Can it be one line? One line
7. Only then: the minimum code that works
Stop at the first rung that holds.'

case "$LEVEL" in
  lite) BODY='YAGNI first, then reuse what is already here, then stdlib, then the shortest working diff.' ;;
  ultra) BODY="$RUNGS
Deletion over addition. If the explanation is longer than the code, delete the explanation." ;;
  *) BODY="$RUNGS" ;;
esac

NEVER_SIMPLIFY='Never simplify away: input validation at trust boundaries, error handling that prevents data loss, security controls, accessibility basics, or anything explicitly requested.'

printf 'PONYTAIL LADDER — advisory, not a gate (level: %s)\n%s\n%s\n%s\n' "$LEVEL" "$FRAMING" "$BODY" "$NEVER_SIMPLIFY"

exit 0
