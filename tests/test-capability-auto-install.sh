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
  grep -q "^capability install $HOME_DIR/.gsd/capability-bundle-$ID --scope global --yes\$" "$CALLS" || fail "baseline: spy called with unexpected arguments: $(cat "$CALLS")"
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
  [ "$(run_hook)" = 0 ] || fail "file boundary: baseline exit != 0"
  [ "$(ncalls)" = 1 ] || fail "file boundary: baseline install missing"
  printf AA > "$PLUGIN/fragments/a.md"; printf ABBB > "$PLUGIN/fragments/b.md"
  [ "$(run_hook)" = 0 ] || fail "file boundary: reinstall exit != 0"
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

# GSD_HOME set, HOME unset, no gsd-tools anywhere: the resolver must not trip set -u.
case5() {
  mk_env c5
  rm -f "$SPY/gsd-tools"
  local out
  out="$(cd "$CWD" && env -i PATH=/usr/bin:/bin CLAUDE_PLUGIN_ROOT="$PLUGIN" GSD_HOME="$HOME_DIR" \
    bash "$PLUGIN/hooks/capability-auto-install.sh" "$ID" 2>"$E/stderr"; echo "rc=$?")"
  [ "$out" = "rc=0" ] || fail "GSD_HOME only: expected exit 0, got: $out"
  grep -q 'unbound variable' "$E/stderr" && fail "GSD_HOME only: unbound variable: $(cat "$E/stderr")"
  [ ! -e "$HASH" ] || fail "GSD_HOME only: hash written without an install"
}

# SECURITY: a cwd git repo shipping gsd-core/bin/gsd-tools.cjs must never be executed
# (untrusted repo code execution at SessionStart). Do not restore a repo-local lookup.
case6() {
  mk_env c6
  local marker="$E/hostile-ran"
  git -C "$CWD" init -q
  mkdir -p "$CWD/gsd-core/bin"
  printf 'require("fs").writeFileSync(%s, "x");\n' "\"$marker\"" > "$CWD/gsd-core/bin/gsd-tools.cjs"
  [ "$(run_hook)" = 0 ] || fail "hostile repo: exit != 0"
  [ ! -e "$marker" ] || fail "hostile repo: repo-local gsd-tools.cjs was executed"
  [ "$(ncalls)" = 1 ] || fail "hostile repo: PATH gsd-tools not called (got $(ncalls))"
}

# A bundle declaring an executable surface must not be auto-consented.
case7() {
  mk_env c7
  node -e 'const f=process.argv[1],m=JSON.parse(require("fs").readFileSync(f));m.hooks=[{event:"SessionStart",script:"x.sh"}];require("fs").writeFileSync(f,JSON.stringify(m))' "$PLUGIN/capability.json"
  [ "$(run_hook)" = 0 ] || fail "executable: exit != 0"
  [ "$(ncalls)" = 1 ] || fail "executable: expected 1 spy call, got $(ncalls)"
  grep -q -- '--yes' "$CALLS" && fail "executable: --yes passed: $(cat "$CALLS")"
  grep -q "^capability install $HOME_DIR/.gsd/capability-bundle-$ID --scope global\$" "$CALLS" || fail "executable: unexpected arguments: $(cat "$CALLS")"
  grep -q "gsd-tools capability install $HOME_DIR/.gsd/capability-bundle-$ID" "$E/stderr" || fail "executable: stderr lacks review line: $(cat "$E/stderr")"
  [ "$(wc -l < "$E/stderr" | tr -d ' ')" = 1 ] || fail "executable: expected one stderr line: $(cat "$E/stderr")"
  [ ! -e "$HASH" ] || fail "executable: hash written"
}

# The install call never reads the session's stdin (a prompt must not block startup).
case8() {
  mk_env c8
  printf '#!/usr/bin/env bash\necho "$@" >> "%s"\nread -r l && printf "%%s" "$l" > "%s"\nexit 0\n' "$CALLS" "$E/stdin" > "$SPY/gsd-tools"
  local rc
  rc="$(printf 'y\n' | run_hook)"
  [ "$rc" = 0 ] || fail "stdin: exit != 0"
  [ "$(ncalls)" = 1 ] || fail "stdin: spy not called"
  [ ! -s "$E/stdin" ] || fail "stdin: install call read session stdin"
}

# Publication guard (ported from sota-numerics): a global install publishes
# machine-wide, so only bundle bytes that a tracking repository already holds
# upstream may be installed. Rows, in the order the hook evaluates them:
#   1. git binary unusable                    -> refuse   (case 9)
#   2. repo tracks no bundle path             -> guard does not apply (case 17)
#   3. tracked, symlink in the bundle         -> refuse   (cases 15, 23)
#   4. tracked, index hides edits             -> refuse   (case 16)
#   5. tracked, dirty/untracked/ignored files -> refuse   (cases 12, 13, 14, 18, 22)
#   6. tracked, no origin/HEAD|origin/main    -> refuse   (case 11)
#   7. tracked, HEAD not an ancestor of it    -> refuse   (case 10)
#   8. tracked, clean and published           -> install  (cases 19, 20)
#   9. git cannot read the repository         -> refuse   (case 21)
# A refusal never writes the sidecar, so a later published state retries.
# Fixture git is isolated from the user's config (global hooks, signing).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$SCRATCH" XDG_CONFIG_HOME="$SCRATCH/xdg"
G=(git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -C)

# mk_git <name> [paths...]: mk_env, then a repo in the plugin tracking <paths>
# (default: the whole bundle) with origin/main at HEAD.
mk_git() {
  local n="$1"; shift
  mk_env "$n"
  git -C "$PLUGIN" init -q
  [ $# -gt 0 ] || set -- capability.json fragments NOTES.md
  "${G[@]}" "$PLUGIN" add -- "$@"
  "${G[@]}" "$PLUGIN" commit -q -m init
  git -C "$PLUGIN" update-ref refs/remotes/origin/main HEAD
}
refused() { # <case> <stderr fragment>
  [ "$(run_hook)" = 0 ] || fail "$1: exit != 0"
  [ "$(ncalls)" = 0 ] || fail "$1: spy called despite refusal"
  [ ! -e "$HASH" ] || fail "$1: sidecar written on refusal"
  grep -q "$2" "$E/stderr" || fail "$1: stderr lacks '$2': $(cat "$E/stderr")"
}
installed() {
  [ "$(run_hook)" = 0 ] || fail "$1: exit != 0"
  [ "$(ncalls)" = 1 ] || fail "$1: expected 1 install, got $(ncalls): $(cat "$E/stderr")"
  [ -s "$HASH" ] || fail "$1: sidecar not written"
}

case9() {
  mk_git c9
  mkdir "$E/badgit"; printf '#!/bin/sh\nexit 1\n' > "$E/badgit/git"; chmod +x "$E/badgit/git"
  SPY="$E/badgit:$SPY"
  refused "git unusable" 'git is unusable'
}
case10() { mk_git c10; printf x >> "$PLUGIN/NOTES.md"; "${G[@]}" "$PLUGIN" commit -qam local
  refused "unpublished HEAD" 'not published'; }
case11() { mk_git c11; git -C "$PLUGIN" update-ref -d refs/remotes/origin/main
  refused "no upstream ref" 'no origin/HEAD or origin/main'; }
case12() { mk_git c12; printf x >> "$PLUGIN/NOTES.md"; refused "modified tracked file" 'uncommitted or ignored'; }
case13() { mk_git c13; printf x > "$PLUGIN/fragments/new.md"; refused "untracked file" 'uncommitted or ignored'; }
case14() { mk_git c14; printf 'fragments/*.tmp\n' > "$PLUGIN/.git/info/exclude"; printf x > "$PLUGIN/fragments/a.tmp"
  refused "ignored file" 'uncommitted or ignored'; }
case15() { mk_git c15; ln -s ../NOTES.md "$PLUGIN/fragments/link.md"
  "${G[@]}" "$PLUGIN" add fragments; "${G[@]}" "$PLUGIN" commit -qm link
  git -C "$PLUGIN" update-ref refs/remotes/origin/main HEAD
  refused "symlink" 'contains a symlink'; }
case16() { mk_git c16; git -C "$PLUGIN" update-index --assume-unchanged NOTES.md
  refused "assume-unchanged" 'assume-unchanged or skip-worktree'; }
case17() { mk_env c17; git -C "$PLUGIN" init -q; : > "$PLUGIN/other"; "${G[@]}" "$PLUGIN" add other
  "${G[@]}" "$PLUGIN" commit -qm other; installed "repo tracks no bundle path"; }
case18() { mk_git c18 capability.json; refused "partly tracked bundle" 'uncommitted or ignored'; }
case19() { mk_git c19; installed "clean and published"; }
case20() { mk_git c20; printf x >> "$PLUGIN/NOTES.md"; "${G[@]}" "$PLUGIN" commit -qam local
  [ "$(run_hook)" = 0 ] && [ "$(ncalls)" = 0 ] || fail "retry: first run not refused"
  git -C "$PLUGIN" update-ref refs/remotes/origin/main HEAD
  [ "$(run_hook)" = 0 ] && [ "$(ncalls)" = 1 ] && [ -s "$HASH" ] || fail "retry: not installed once published"; }
case21() { mk_env c21; printf 'gitdir: %s/nowhere\n' "$E" > "$PLUGIN/.git"
  refused "unreadable repository" 'cannot read the repository'; }
# status.showUntrackedFiles=no must not hide a new directory in the bundle.
case22() { mk_git c22; git -C "$PLUGIN" config status.showUntrackedFiles no
  mkdir "$PLUGIN/fragments/sub"; printf x > "$PLUGIN/fragments/sub/new.md"
  refused "showUntrackedFiles=no" 'uncommitted or ignored'; }
# A committed symlink *as* a top-level bundle path: find on `fragments` without
# a trailing slash does not follow it, so only the bare -L test catches it.
case23() { mk_git c23; mkdir "$E/outside"; printf x > "$E/outside/a.md"
  git -C "$PLUGIN" rm -rq fragments; ln -s "$E/outside" "$PLUGIN/fragments"
  "${G[@]}" "$PLUGIN" add fragments; "${G[@]}" "$PLUGIN" commit -qm linkdir
  git -C "$PLUGIN" update-ref refs/remotes/origin/main HEAD
  refused "symlinked top-level directory" 'contains a symlink'; }

rc=0
for c in "1 baseline" "2 staging failure" "3 file boundary" "4 no home" "5 GSD_HOME only" "6 hostile repo" "7 executable surface" "8 stdin" "9 git unusable" "10 unpublished HEAD" "11 no upstream ref" "12 modified file" "13 untracked file" "14 ignored file" "15 symlink" "16 assume-unchanged" "17 repo tracks no bundle" "18 partly tracked" "19 published" "20 retry once published" "21 unreadable repo" "22 showUntrackedFiles=no" "23 symlinked bundle dir"; do
  n="${c%% *}"
  if ( "case$n" ) >"$SCRATCH/out$n" 2>&1; then pass "case $c"; else cat "$SCRATCH/out$n"; rc=1; fi
done
[ "$rc" = 0 ] || exit 1
echo "ALL PASS"
