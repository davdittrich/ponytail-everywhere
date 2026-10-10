#!/usr/bin/env bash
# Regression test for the gsd_tools() resolver under `set -u` with HOME unset.
# No framework: fail() records and continues so every case reports; exit code is
# nonzero if any case failed.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GSD_TOOLS_SH="$REPO_ROOT/hooks/gsd-tools.sh"
AUTO_INSTALL_SH="$REPO_ROOT/hooks/capability-auto-install.sh"

FAILED=0
fail() { echo "FAIL: $1"; FAILED=1; }
pass() { echo "PASS: $1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" 2>/dev/null' EXIT

# --- Case a: HOME unset, no gsd-tools on PATH -> return 127, no unbound-variable abort ---
mkdir -p "$WORK/cwd" "$WORK/bin"
ln -s "$(command -v bash)" "$WORK/bin/bash" # PATH holds only bash: no host gsd-tools can shadow the not-found path
OUT="$(cd "$WORK/cwd" && env -i PATH="$WORK/bin" bash -c 'set -u; . "$1"; gsd_tools --version; echo rc=$?' x "$GSD_TOOLS_SH" 2>"$WORK/err")"
LAST="$(printf '%s\n' "$OUT" | tail -n 1)"
if [ "$LAST" = "rc=127" ]; then
  pass "case a: HOME unset -> rc=127"
else
  fail "case a: expected last stdout line rc=127, got '$LAST'"
fi
if [ -s "$WORK/err" ]; then
  fail "case a: unexpected stderr: $(cat "$WORK/err")"
else
  pass "case a: stderr empty"
fi

# --- Case b: CLAUDE_CONFIG_DIR fallback must guard HOME with ${HOME:-} ---
EXPECT='${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}'
for f in "$GSD_TOOLS_SH" "$AUTO_INSTALL_SH"; do
  name="${f#"$REPO_ROOT"/}"
  LINES="$(grep -F 'CLAUDE_CONFIG_DIR:-' "$f")"
  if [ -z "$LINES" ]; then
    fail "case b: no CLAUDE_CONFIG_DIR:- line in $name"
    continue
  fi
  BAD="$(printf '%s\n' "$LINES" | grep -vF "$EXPECT")"
  if [ -n "$BAD" ]; then
    fail "case b: $name has CLAUDE_CONFIG_DIR:- line without '$EXPECT': $BAD"
  else
    pass "case b: $name CLAUDE_CONFIG_DIR:- line guards HOME"
  fi
done

if [ "$FAILED" -eq 0 ]; then
  echo "ALL PASS"
fi
exit "$FAILED"
