#!/usr/bin/env bash
# Vendored auto-install hook (vendored copy per plugin, not shared at
# runtime). Derived from the sota-numerics copy, which keeps its bundle under
# .gsd/capabilities/<id>; here the bundle files sit at the plugin root so that
# `gsd capability install <git url>` also works (URL import reads
# capability.json at the repo root). Only the bundle files are hashed and
# staged, never the rest of the checkout (.git, hooks, tests, symlinks).
#
# Detects bundle drift via a whole-directory hash and re-grants the
# capability at global ("user") scope on every SessionStart.
# Never aborts the session: no `set -e`.
set -u

CAP_ID="${1:-}"

# Defense in depth (ASVS V5): call sites only ever pass a hard-coded literal,
# but validate the id shape gsd-core itself enforces before it reaches any
# path construction.
[[ "$CAP_ID" =~ ^[a-z][a-z0-9-]*$ ]] || exit 0

# No home dir to install under; `set -u` would abort on the paths below.
[ -n "${GSD_HOME:-${HOME:-}}" ] || exit 0

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BUNDLE_SRC="$PLUGIN_ROOT"
[ -f "$BUNDLE_SRC/capability.json" ] || exit 0
BUNDLE_FILES=(capability.json fragments NOTES.md)

# Portable hash tool selection (macOS ships no sha256sum).
if command -v sha256sum >/dev/null 2>&1; then
  HASH_CMD=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
  HASH_CMD=(shasum -a 256)
else
  exit 0
fi

# Bundle hash: LC_ALL=C-sorted list of every path under the bundle files
# (files AND directories, so an added empty directory is caught) followed by
# one digest per sorted regular file. Per-file digests keep file boundaries:
# raw concatenation hashes identically when bytes move between files.
bundle_hash() {
  {
    (cd "$BUNDLE_SRC" && find "${BUNDLE_FILES[@]}" \( -type f -o -type d \) 2>/dev/null) | LC_ALL=C sort
    (cd "$BUNDLE_SRC" && find "${BUNDLE_FILES[@]}" -type f 2>/dev/null) | LC_ALL=C sort | while IFS= read -r _f; do (cd "$BUNDLE_SRC" && "${HASH_CMD[@]}" "$_f"); done
  } | "${HASH_CMD[@]}" | awk '{print $1}'
}

# One sidecar file per capability id so vendored copies in
# different plugins cannot race or stomp each other's cached hash. Never
# gsd-core's own .gsd-capabilities.json / ~/.gsd/consent.json -- those are
# gsd-core-owned schemas this script must not write into.
STATE_FILE="${GSD_HOME:-$HOME}/.gsd/capability-auto-install-$CAP_ID.hash"

OLD_HASH=""
[ -r "$STATE_FILE" ] && OLD_HASH="$(cat "$STATE_FILE" 2>/dev/null)"
NEW_HASH="$(bundle_hash)"

# Fast path: unchanged bundle exits silently, never spawns node.
[ "$NEW_HASH" = "$OLD_HASH" ] && exit 0

# gsd_tools() resolver, inlined verbatim from hooks/gsd-tools.sh rather than
# sourced -- keeping an inline copy here keeps this script dependency-free
# within its own plugin.
gsd_tools() {
  if [ -z "${_GSD_TOOLS_ARGS_SET+x}" ]; then
    _GSD_TOOLS_ARGS_SET=1
    local _root
    _root="$(git rev-parse --show-toplevel 2>/dev/null)"
    if [ -n "$_root" ] && [ -f "$_root/gsd-core/bin/gsd-tools.cjs" ]; then
      _GSD_TOOLS_ARGS=(node "$_root/gsd-core/bin/gsd-tools.cjs")
    elif command -v gsd-tools >/dev/null 2>&1; then
      _GSD_TOOLS_ARGS=(gsd-tools)
    elif [ -f "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/gsd-core/bin/gsd-tools.cjs" ]; then
      _GSD_TOOLS_ARGS=(node "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/gsd-core/bin/gsd-tools.cjs")
    else
      _GSD_TOOLS_ARGS=()
    fi
  fi
  [ "${#_GSD_TOOLS_ARGS[@]}" -gt 0 ] || return 127
  "${_GSD_TOOLS_ARGS[@]}" "$@"
}

# Stage the bundle files into a persistent clean directory; gsd-core records the
# install source, so it must outlive this run. Never install a partial bundle,
# never record the hash: a failed stage exits before either can happen.
BUNDLE_DIR="${GSD_HOME:-$HOME}/.gsd/capability-bundle-$CAP_ID"
if ! { rm -rf "$BUNDLE_DIR" && mkdir -p "$BUNDLE_DIR" && (cd "$BUNDLE_SRC" && cp -RL "${BUNDLE_FILES[@]}" "$BUNDLE_DIR"/); }; then
  echo "capability-auto-install: staging failed for $CAP_ID; not installed" >&2
  exit 0
fi

# Spec is always the absolute bundle dir -- a relative spec would resolve
# against the end user's cwd, not the plugin. Prose "user scope" maps to the
# CLI's literal --scope global value.
gsd_tools capability install "$BUNDLE_DIR" --scope global --yes >/dev/null 2>&1
INSTALL_STATUS=$?

if [ "$INSTALL_STATUS" -eq 0 ]; then
  printf 'Auto-installed capability: %s (user scope)\n' "$CAP_ID"
  mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
  printf '%s' "$NEW_HASH" > "$STATE_FILE" 2>/dev/null
elif [ "$INSTALL_STATUS" -eq 127 ]; then
  # Deliberate divergence from this repo's usual silent `|| true`
  # fail-open convention -- this path is unattended, so silence would leave
  # a capability permanently inactive with nobody the wiser. Do not "fix"
  # this back to silent. Do NOT write STATE_FILE, so the next session retries.
  echo "capability-auto-install: gsd-tools not found; $CAP_ID not installed" >&2
else
  # Same rationale as above -- install command ran and failed.
  echo "capability-auto-install: capability install failed for $CAP_ID (exit $INSTALL_STATUS)" >&2
fi

exit 0
