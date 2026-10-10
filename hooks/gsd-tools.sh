gsd_tools() {
  if [ -z "${_GSD_TOOLS_ARGS_SET+x}" ]; then
    _GSD_TOOLS_ARGS_SET=1
    # Never resolve from the cwd's git repo: a cloned repo's gsd-core/bin/gsd-tools.cjs is
    # untrusted code and must not run on SessionStart or command expansion.
    if command -v gsd-tools >/dev/null 2>&1; then
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
