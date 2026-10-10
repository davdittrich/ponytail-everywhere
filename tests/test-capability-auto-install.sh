#!/usr/bin/env bash
# capability-auto-install.sh: spy-based behaviour tests (gsd-tools is faked, never real).
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ID=ponytail

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH" 2>/dev/null' EXIT

# mk_env <name>: fresh plugin copy, GSD_HOME, spy on PATH, non-git cwd.
mk_env() {
  E="$SCRATCH/$1"
  PLUGIN="$E/plugin"; HOME_DIR="$E/home"; SPY="$E/spy"; CALLS="$E/calls"; CWD="$E/cwd"
  mkdir -p "$PLUGIN/hooks" "$HOME_DIR" "$SPY" "$CWD"
  (cd "$REPO_ROOT" && cp -R capability.json fragments NOTES.md "$PLUGIN"/)
  cp "$REPO_ROOT/hooks/capability-auto-install.sh" "$PLUGIN/hooks/"
  : > "$CALLS"
  printf '#!/usr/bin/env bash\necho "$@" >> "%s"\nexit 0\n' "$CALLS" > "$SPY/gsd-tools"
  chmod +x "$SPY/gsd-tools"
  HASH="$HOME_DIR/.gsd/capability-auto-install-$ID.hash"
}

run_hook() {
  (cd "$CWD" && PATH="$SPY:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN" GSD_HOME="$HOME_DIR" \
    bash "$PLUGIN/hooks/capability-auto-install.sh" "$ID" 2>"$E/stderr" >"$E/stdout"; echo $?)
}
ncalls() { wc -l < "$CALLS" | tr -d ' '; }

case1() {
  mk_env c1
  [ "$(run_hook)" = 0 ] || fail "baseline: first run exit != 0"
  [ "$(ncalls)" = 1 ] || fail "baseline: expected 1 spy call, got $(ncalls)"
  grep -q '^capability install' "$CALLS" || fail "baseline: spy not called with 'capability install'"
  [ -s "$HASH" ] || fail "baseline: hash sidecar not written"
  [ "$(run_hook)" = 0 ] || fail "baseline: second run exit != 0"
  [ ! -s "$E/stdout" ] && [ ! -s "$E/stderr" ] || fail "baseline: second run not silent"
  [ "$(ncalls)" = 1 ] || fail "baseline: second run called spy again"
}

case2() {
  mk_env c2
  rm -rf "$PLUGIN/fragments"
  [ "$(run_hook)" = 0 ] || fail "staging failure: exit != 0"
  [ "$(ncalls)" = 0 ] || fail "staging failure: spy called despite failed staging"
  [ ! -e "$HASH" ] || fail "staging failure: hash file written"
  grep -q 'staging failed' "$E/stderr" || fail "staging failure: stderr lacks 'staging failed'"
}

case3() {
  mk_env c3
  rm -rf "$PLUGIN/fragments"; mkdir "$PLUGIN/fragments"
  printf AAA > "$PLUGIN/fragments/a.md"; printf BBB > "$PLUGIN/fragments/b.md"
  run_hook >/dev/null
  [ "$(ncalls)" = 1 ] || fail "file boundary: baseline install missing"
  printf AA > "$PLUGIN/fragments/a.md"; printf ABBB > "$PLUGIN/fragments/b.md"
  run_hook >/dev/null
  [ "$(ncalls)" = 2 ] || fail "file boundary: content moved across files did not trigger reinstall"
}

case4() {
  mk_env c4
  local out
  out="$(cd "$CWD" && env -i PATH="$SPY:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN" \
    bash "$PLUGIN/hooks/capability-auto-install.sh" "$ID" 2>"$E/stderr"; echo "rc=$?")"
  [ "$out" = "rc=0" ] || fail "no home: expected silent stdout and exit 0, got: $out"
  [ ! -s "$E/stderr" ] || fail "no home: stderr not empty: $(cat "$E/stderr")"
  [ "$(ncalls)" = 0 ] || fail "no home: spy called"
}

rc=0
for c in "1 baseline" "2 staging failure" "3 file boundary" "4 no home"; do
  n="${c%% *}"
  if ( "case$n" ) >"$SCRATCH/out$n" 2>&1; then pass "case $c"; else cat "$SCRATCH/out$n"; rc=1; fi
done
[ "$rc" = 0 ] || exit 1
echo "ALL PASS"
