#!/usr/bin/env bash
# Vendored auto-install hook (vendored copy per plugin, not shared at
# runtime); needs hooks/gsd-tools.sh beside it. Derived from the sota-numerics
# copy, which keeps its bundle under
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

# Fast path: unchanged bundle exits silently, never spawns node. The sidecar
# only records what the global mirror held when written, so also require the
# mirror's manifest (a deleted mirror must be repaired).
[ "$NEW_HASH" = "$OLD_HASH" ] && [ -f "${GSD_HOME:-$HOME}/.gsd/capabilities/$CAP_ID/capability.json" ] && exit 0

# Fail closed: a git that cannot answer is not "safe" (`command -v` alone
# misses a git on PATH that exits non-zero).
if ! command -v git >/dev/null 2>&1 || ! git --version >/dev/null 2>&1; then
  echo "capability-auto-install: git is unusable, so $CAP_ID bundle provenance cannot be verified; refusing to install it at global scope" >&2
  exit 0
fi

# Global install publishes machine-wide, so only already-published bytes may
# be installed: this plugin is developed in a worktree the host loads. No
# refusal writes STATE_FILE, so a later session retries once published.
# Ownership, not enclosure: only a repository that *tracks* the bundle speaks
# for its bytes. A plugin-cache copy sits in no repository and is not guarded.
# Derived from sota-numerics; the rows are enumerated above case 9 in
# tests/test-capability-auto-install.sh.
#
# TRACKED is 0 when the repository tracks any BUNDLE_FILES entry (apply the
# publication checks), 1 when it answered and tracks none, 128 when git did
# not answer -- never read as "untracked". Not `--error-unmatch`: with several
# pathspecs it exits 1 when any one is unmatched, so a partly tracked bundle
# would skip the checks.
#
# unverifiable_repo() decides the 128 case: `--git-dir` succeeding means a
# repository exists and did not answer; otherwise walk the ancestors -- an
# uninspectable .git is assumed a repository, one holding a HEAD is one git
# declined, an inspectable .git without HEAD is walked past.
unverifiable_repo() {
  git -C "$BUNDLE_SRC" rev-parse --git-dir >/dev/null 2>&1 && return 0
  local _d="$BUNDLE_SRC" _g _prev
  while :; do
    _g="$_d/.git"
    if [ -e "$_g" ] &&
       ! { [ -d "$_g" ] && [ -r "$_g" ] && [ -x "$_g" ] && [ ! -e "$_g/HEAD" ]; }; then
      return 0
    fi
    # Stop when dirname stops moving, not at "/": a relative path converges on
    # "." and would hang.
    _prev="$_d"
    _d="$(dirname "$_d")"
    [ "$_d" = "$_prev" ] && return 1
  done
}

TRACKED=0
if ! _LS="$(git -C "$BUNDLE_SRC" ls-files -- "${BUNDLE_FILES[@]}" 2>/dev/null)"; then
  TRACKED=128
elif [ -z "$_LS" ]; then
  TRACKED=1
fi
if [ "$TRACKED" -eq 0 ]; then
  # gsd-core rejects symlinks, and a committed link passes every check below
  # (git compares the link, not its target). BUNDLE_FILES carry no trailing
  # slash, so find also reports a symlinked top-level path itself (case 23).
  _LINKS="$(find "${BUNDLE_FILES[@]/#/$BUNDLE_SRC/}" -type l -print -quit 2>/dev/null)"
  if [ -n "$_LINKS" ]; then
    echo "capability-auto-install: the $CAP_ID bundle contains a symlink, which gsd-core rejects; refusing to install it at global scope" >&2
    exit 0
  fi
  # `status` reads the index, which `update-index --assume-unchanged` and
  # `--skip-worktree` silence. `ls-files -v` tags a plain entry H; anything
  # else was told not to be checked (sparse checkout sets skip-worktree too).
  # Capture the status before the output: piping into `grep` takes grep's
  # status and hides a failed `ls-files`.
  if ! INDEX_TAGS="$(git -C "$BUNDLE_SRC" ls-files -v -- "${BUNDLE_FILES[@]}" 2>/dev/null)"; then
    echo "capability-auto-install: git could not list the index entries for the $CAP_ID bundle, so whether the index hides edits cannot be determined; refusing to install it at global scope" >&2
    exit 0
  fi
  if printf '%s\n' "$INDEX_TAGS" | grep -q '^[^H]'; then
    echo "capability-auto-install: the index marks $CAP_ID bundle entries assume-unchanged or skip-worktree, so git will not report edits to them; refusing to install it at global scope" >&2
    exit 0
  fi
  # Each option states what this question needs, not what repo config gives:
  # --untracked-files=all (showUntrackedFiles=no), --ignored (ignore rules),
  # --ignore-submodules=none (submodule.<n>.ignore), fsmonitor off. A clean
  # filter is closed separately, by the attribute check below (case 40).
  # Read the exit status before the output: empty output from a failed
  # `status` looks like a clean tree.
  if ! DIRTY="$(git -c core.fsmonitor= -C "$BUNDLE_SRC" status --porcelain --ignored \
                    --untracked-files=all --ignore-submodules=none -- "${BUNDLE_FILES[@]}" 2>/dev/null)"; then
    echo "capability-auto-install: git could not report the state of the $CAP_ID bundle, so its contents cannot be verified; refusing to install it at global scope" >&2
    exit 0
  fi
  if [ -n "$DIRTY" ]; then
    echo "capability-auto-install: $CAP_ID bundle has uncommitted or ignored files; refusing to install it at global scope" >&2
    exit 0
  fi
  # A `filter` attribute selects a clean filter, which can map an edited
  # worktree file back onto its committed blob: `status` and the index are then
  # honestly clean while the staged copy carries the edit (case 40). The driver
  # lives in local config, so the bytes cannot be compared through git; any
  # bundle file that selects a filter is refused, wherever the attribute comes
  # from (a global core.attributesFile included).
  #
  # check-attr prints path, attribute, value as NUL-separated triples. tr swaps
  # "\n" for \001 and NUL for "\n" first, so a newline inside a path cannot
  # shift the triples (case 42). Only "unspecified" and "unset" (`-filter`, the
  # repository-local way out of a global rule, case 43) select no filter.
  # pipefail: a failed stage refuses instead of reading as "no filter" (case 41).
  if ! FILTERED="$(set -o pipefail
                   git -C "$BUNDLE_SRC" ls-files -z -- "${BUNDLE_FILES[@]}" 2>/dev/null |
                   git -C "$BUNDLE_SRC" check-attr -z --stdin filter 2>/dev/null |
                   tr '\n\0' '\001\n' |
                   awk 'NR % 3 == 0 && $0 != "unspecified" && $0 != "unset"')" ||
     [ -n "$FILTERED" ]; then
    echo "capability-auto-install: a git filter attribute applies to the $CAP_ID bundle (or attributes could not be read), which can hide edits from git (set -filter in .git/info/attributes to opt out); refusing to install it at global scope" >&2
    exit 0
  fi
  # origin/HEAD and origin/main are local refs: passing proves HEAD is an
  # ancestor of the last fetched tip, not that a server holds it now (a round
  # trip per SessionStart would put the capability behind network and
  # credentials). Fail closed: an unresolvable upstream proves nothing.
  PUBLISHED="$(git -C "$BUNDLE_SRC" rev-parse --verify --quiet origin/HEAD ||
               git -C "$BUNDLE_SRC" rev-parse --verify --quiet origin/main)"
  if [ -z "$PUBLISHED" ]; then
    echo "capability-auto-install: $CAP_ID bundle has no origin/HEAD or origin/main to prove it is published; refusing to install it at global scope" >&2
    exit 0
  fi
  if ! git -C "$BUNDLE_SRC" merge-base --is-ancestor HEAD "$PUBLISHED" 2>/dev/null; then
    echo "capability-auto-install: $CAP_ID bundle HEAD is not published (not an ancestor of $PUBLISHED); refusing to install it at global scope" >&2
    exit 0
  fi
elif [ "$TRACKED" -ne 1 ] && unverifiable_repo; then
  echo "capability-auto-install: git cannot read the repository holding the $CAP_ID bundle, so its provenance cannot be verified; refusing to install it at global scope" >&2
  exit 0
fi

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
#
# Consent: --yes only for a declarative bundle. gsd-core counts hooks, commands, mcpServers
# and reviewer as executable surfaces (src/capability-trust.cts hasExecutable); those need
# the user's own consent, never an unattended SessionStart grant. Unparseable manifest =
# executable (fail closed). </dev/null: a prompt must never block session start.
_YES=()
node -e '
  const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const arr = (v) => Array.isArray(v) && v.length > 0;
  const obj = (v) => v !== null && typeof v === "object" && !Array.isArray(v) && Object.keys(v).length > 0;
  process.exit(arr(m.hooks) || arr(m.commands) || arr(m.mcpServers) || obj(m.mcpServers) || obj(m.reviewer) ? 1 : 0);
' "$BUNDLE_DIR/capability.json" >/dev/null 2>&1 && _YES=(--yes)

# A directory copy and a JSON write behind one `node` start: seconds. 60 is a
# loose bound for a cold start on a loaded or network-mounted home; the
# invocation and the message both read it.
INSTALL_TIMEOUT=60

# -k 5: SIGKILL a child that ignores SIGTERM. `timeout` is coreutils; macOS has
# `gtimeout` only with coreutils, and with neither _TIMEOUT is empty and the
# install runs unbounded. -k is GNU: probe it, else use a bare bound.
_TIMEOUT=()
for _t in timeout gtimeout; do
  command -v "$_t" >/dev/null 2>&1 || continue
  if "$_t" -k 1 1 true >/dev/null 2>&1; then _TIMEOUT=("$_t" -k 5 "$INSTALL_TIMEOUT")
  else _TIMEOUT=("$_t" "$INSTALL_TIMEOUT"); fi
  break
done

# gsd_tools is a shell function from hooks/gsd-tools.sh, so the timed child is
# `bash -c` and sources it there: nothing outside the timeout runs before the
# install decision. A plugin copy without the helper leaves it undefined: exit
# 127, no sidecar, retried next session. PLUGIN_ROOT, the bundle dir and flags
# arrive as argv, never interpolated. The "${_TIMEOUT[@]+...}" form is
# deliberate: a bare empty array aborts under `set -u` on bash 3.2 (macOS).
_INSTALL_CHILD='[ -f "$1/hooks/gsd-tools.sh" ] && . "$1/hooks/gsd-tools.sh"; gsd_tools capability install "${@:2}"'
"${_TIMEOUT[@]+"${_TIMEOUT[@]}"}" bash -c "$_INSTALL_CHILD" _ \
  "$PLUGIN_ROOT" "$BUNDLE_DIR" --scope global "${_YES[@]+"${_YES[@]}"}" </dev/null >/dev/null 2>&1
INSTALL_STATUS=$?

# Without --yes gsd-core discloses the executable surfaces and stops. No hash
# write: re-reminded each session.
if [ "${#_YES[@]}" -eq 0 ]; then
  echo "capability-auto-install: $CAP_ID declares executable surfaces, not auto-consented; review with: gsd-tools capability install $BUNDLE_DIR --scope global" >&2
  exit 0
fi

# Re-hash after the install: if the bytes moved while it ran, the mirror is not
# described by NEW_HASH, so record nothing and retry next session.
if [ "$INSTALL_STATUS" -eq 0 ]; then
  if [ "$(bundle_hash)" != "$NEW_HASH" ]; then
    echo "capability-auto-install: the $CAP_ID bundle changed during the install; not recording it as installed" >&2
  else
    printf 'Auto-installed capability: %s (user scope)\n' "$CAP_ID"
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
    # Unlink first so the redirection creates a fresh regular file instead of
    # following a link at STATE_FILE. A directory there makes both fail
    # harmlessly: no sidecar, retry next session. Residual: a racing attacker
    # could re-plant the link between rm and redirection; closing it needs
    # O_NOFOLLOW, which no shell offers.
    rm -f "$STATE_FILE" 2>/dev/null
    printf '%s' "$NEW_HASH" > "$STATE_FILE" 2>/dev/null
  fi
elif [ "$INSTALL_STATUS" -eq 127 ]; then
  # Deliberate divergence from this repo's usual silent `|| true`
  # fail-open convention -- this path is unattended, so silence would leave
  # a capability permanently inactive with nobody the wiser. Do not "fix"
  # this back to silent. Do NOT write STATE_FILE, so the next session retries.
  echo "capability-auto-install: gsd-tools not found; $CAP_ID not installed" >&2
elif { [ "$INSTALL_STATUS" -eq 124 ] || [ "$INSTALL_STATUS" -eq 137 ]; } && [ "${#_TIMEOUT[@]}" -gt 0 ]; then
  # 137 is the -k SIGKILL of a child that ignored SIGTERM. Only when the wrapper
  # was used: an install that itself exits 124 must not be mislabelled a kill.
  echo "capability-auto-install: capability install for $CAP_ID exceeded ${INSTALL_TIMEOUT}s and was killed; not installed" >&2
else
  # Same rationale as above -- install command ran and failed.
  echo "capability-auto-install: capability install failed for $CAP_ID (exit $INSTALL_STATUS)" >&2
fi

exit 0
