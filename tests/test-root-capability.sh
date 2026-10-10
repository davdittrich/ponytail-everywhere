#!/usr/bin/env bash
# URL import (`gsd capability install <git url>`) reads capability.json at the repo root,
# so the bundle must live there and survive a plain install of a repo copy.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

command -v gsd-tools >/dev/null 2>&1 || fail "gsd-tools 1.13.0 or later is required"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH" 2>/dev/null' EXIT

[ -f "$REPO_ROOT/capability.json" ] && [ -f "$REPO_ROOT/fragments/planner-ladder.md" ] \
  || fail "capability.json and fragments/ are not at the repo root"
[ ! -e "$REPO_ROOT/.gsd/capabilities/ponytail" ] || fail "bundle still present under .gsd/capabilities/ponytail"
pass "bundle sits at the repo root"

# A copy of the tracked tree stands in for the clone URL import makes.
COPY="$SCRATCH/copy"
mkdir -p "$COPY" "$SCRATCH/project/.planning" "$SCRATCH/home1" "$SCRATCH/home2"
(cd "$REPO_ROOT" && git ls-files --cached --others --exclude-standard -z | tar --null -T - -cf -) | tar -x -C "$COPY"
printf '%s\n' '{}' > "$SCRATCH/project/.planning/config.json"
git -C "$SCRATCH/project" init -q

(cd "$SCRATCH/project" && GSD_HOME="$SCRATCH/home1" gsd-tools capability install "$COPY" --scope project --yes >/dev/null 2>&1) \
  || fail "gsd-tools capability install of the repo copy failed"
ROUTED="$(cd "$SCRATCH/project" && GSD_HOME="$SCRATCH/home1" gsd-tools loop render-hooks plan:pre --raw 2>/dev/null \
  | jq -r '[.activeHooks[] | select(.capId == "ponytail") | .ref.agent // .into] | sort | join(",")')"
[ "$ROUTED" = "checker,planner" ] || fail "plan:pre renders [$ROUTED] for ponytail, expected checker,planner"
pass "repo-copy install routes planner and checker fragments at plan:pre"

# Auto-install hashes and stages only the bundle files: dev state must not trigger a re-grant.
run_auto() { (cd "$SCRATCH" && CLAUDE_PLUGIN_ROOT="$COPY" GSD_HOME="$SCRATCH/home2" bash "$COPY/hooks/capability-auto-install.sh" ponytail 2>&1); }
OUT="$(run_auto)"
echo "$OUT" | grep -q 'Auto-installed capability: ponytail' || fail "first auto-install did not grant the capability: $OUT"
[ -z "$(run_auto)" ] || fail "unchanged bundle re-granted"
mkdir -p "$COPY/.git" "$COPY/.serena"
echo x > "$COPY/.git/HEAD"; echo y > "$COPY/.serena/project.yml"; ln -s README.md "$COPY/stray-link"
[ -z "$(run_auto)" ] || fail "dev state outside the bundle triggered a re-grant"
echo '<!-- edit -->' >> "$COPY/fragments/executor-ladder.md"
run_auto | grep -q 'Auto-installed capability: ponytail' || fail "a fragment edit did not trigger a re-grant"
[ -f "$SCRATCH/home2/.gsd/capabilities/ponytail/capability.json" ] && [ ! -e "$SCRATCH/home2/.gsd/capabilities/ponytail/hooks" ] \
  || fail "global install is missing the bundle or staged the rest of the checkout"
pass "auto-install hashes and stages only the bundle files"

echo "ALL PASS"
