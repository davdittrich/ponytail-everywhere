#!/usr/bin/env bash
# capability-auto-install.sh: spy-based behaviour tests (gsd-tools is faked, never real).
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ID=ponytail

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

SCRATCH="$(mktemp -d)"
trap 'chmod -R u+rwx "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH" 2>/dev/null' EXIT

# mk_env <name>: fresh plugin copy, GSD_HOME, spy on PATH, non-git cwd.
mk_env() {
  E="$SCRATCH/$1"
  PLUGIN="$E/plugin"; HOME_DIR="$E/home"; SPY="$E/spy"; CALLS="$E/calls"; CWD="$E/cwd"
  mkdir -p "$PLUGIN/hooks" "$HOME_DIR" "$SPY" "$CWD"
  (cd "$REPO_ROOT" && cp -R capability.json fragments NOTES.md "$PLUGIN"/)
  cp "$REPO_ROOT/hooks/capability-auto-install.sh" "$REPO_ROOT/hooks/gsd-tools.sh" "$PLUGIN/hooks/"
  : > "$CALLS"
  printf '#!/usr/bin/env bash\necho "$@" >> "%s"\nmkdir -p "$GSD_HOME/.gsd/capabilities/%s" && : > "$GSD_HOME/.gsd/capabilities/%s/capability.json"\nexit 0\n' "$CALLS" "$ID" "$ID" > "$SPY/gsd-tools"
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
#   5b. tracked, filter attribute (or check-attr cannot answer) -> refuse (cases 40-42;
#       43 is the -filter opt-out that installs)
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

# --- hardening ported from sota-numerics (gsd-beads-s8bu) ---

# A deleted global mirror must be repaired even though the sidecar still matches.
case24() { mk_env c24
  [ "$(run_hook)" = 0 ] && [ "$(ncalls)" = 1 ] || fail "mirror: first install missing"
  rm -rf "$HOME_DIR/.gsd/capabilities"
  [ "$(run_hook)" = 0 ] && [ "$(ncalls)" = 2 ] || fail "mirror: deleted mirror not repaired (calls: $(ncalls))"; }

# A symlink planted at the sidecar path must not redirect the write.
case25() { mk_env c25; mkdir -p "$(dirname "$HASH")"; printf keep > "$E/victim"; ln -s "$E/victim" "$HASH"
  [ "$(run_hook)" = 0 ] || fail "sidecar link: exit != 0"
  [ "$(cat "$E/victim")" = keep ] || fail "sidecar link: write followed the link"
  [ ! -L "$HASH" ] && [ -s "$HASH" ] || fail "sidecar link: sidecar is not a fresh regular file"; }

# Bytes that move while the install runs are not described by the hash computed before it.
case26() { mk_env c26; local f; f="$(cd "$PLUGIN/fragments" && ls | head -1)"
  printf '#!/usr/bin/env bash\necho "$@" >> "%s"\nprintf x >> "%s/fragments/%s"\nexit 0\n' "$CALLS" "$PLUGIN" "$f" > "$SPY/gsd-tools"
  [ "$(run_hook)" = 0 ] || fail "moved bytes: exit != 0"
  [ "$(ncalls)" = 1 ] || fail "moved bytes: install not attempted"
  [ ! -e "$HASH" ] || fail "moved bytes: sidecar recorded a hash the mirror may not match"
  grep -q 'changed during the install' "$E/stderr" || fail "moved bytes: stderr lacks message: $(cat "$E/stderr")"; }

# The install runs under `timeout -k 5 60`. The stub skips the `true` probe and execs the rest.
mk_timeout() { # <stub body after the probe>
  printf '#!/usr/bin/env bash\ncase "$*" in *" true") exit 0;; esac\n%s\n' "$1" > "$SPY/timeout"; chmod +x "$SPY/timeout"; }
case27() { mk_env c27; mk_timeout 'printf "%s\n" "${*:1:3}" >> "'"$E"'/tlog"; shift 3; exec "$@"'
  [ "$(run_hook)" = 0 ] || fail "timeout: exit != 0"
  [ "$(cat "$E/tlog" 2>/dev/null)" = "-k 5 60" ] || fail "timeout: install not wrapped in 'timeout -k 5 60' (log: $(cat "$E/tlog" 2>&1))"
  [ "$(ncalls)" = 1 ] && [ -s "$HASH" ] || fail "timeout: install through the wrapper failed: $(cat "$E/stderr")"; }
case28() { mk_env c28; mk_timeout 'exit 124'
  [ "$(run_hook)" = 0 ] || fail "timeout kill: exit != 0"
  [ ! -e "$HASH" ] || fail "timeout kill: sidecar written"
  grep -q 'exceeded 60s' "$E/stderr" || fail "timeout kill: stderr lacks message: $(cat "$E/stderr")"; }
case29() { mk_env c29
  printf '#!/usr/bin/env bash\n[ "$1" = -k ] && exit 125\nprintf "%%s\\n" "$1" >> "%s/tlog"; shift; exec "$@"\n' "$E" > "$SPY/timeout"; chmod +x "$SPY/timeout"
  [ "$(run_hook)" = 0 ] || fail "no -k: exit != 0"
  [ "$(cat "$E/tlog" 2>/dev/null)" = 60 ] || fail "no -k: bare bound not used (log: $(cat "$E/tlog" 2>&1))"
  [ "$(ncalls)" = 1 ] || fail "no -k: install did not run"; }

# core.fsmonitor naming a command that answers "nothing changed" hides edits from plain `status`.
case30() { mk_git c30
  printf '#!/usr/bin/env bash\nprintf token\n' > "$E/fsm"; chmod +x "$E/fsm"
  git -C "$PLUGIN" config core.fsmonitor "$E/fsm"
  git -C "$PLUGIN" status --porcelain >/dev/null 2>&1
  printf x >> "$PLUGIN/NOTES.md"
  [ -z "$(git -C "$PLUGIN" status --porcelain -- NOTES.md 2>/dev/null)" ] || fail "fsmonitor: precondition -- the monitored status should look clean"
  refused "fsmonitor under-reporting" 'uncommitted or ignored'; }

# A submodule inside the bundle told to report itself clean: local config (31) and committed .gitmodules (32).
mk_submodule() { # <name> [gitmodules line]
  mk_git "$1"
  git init -q "$E/sub"; printf lib > "$E/sub/lib.py"; "${G[@]}" "$E/sub" add lib.py; "${G[@]}" "$E/sub" commit -qm sub
  "${G[@]}" "$PLUGIN" -c protocol.file.allow=always submodule add -q "$E/sub" fragments/vendor
  [ -z "${2:-}" ] || printf '\tignore = all\n' >> "$PLUGIN/.gitmodules"
  "${G[@]}" "$PLUGIN" add -A -- .gitmodules fragments; "${G[@]}" "$PLUGIN" commit -qm vendor
  git -C "$PLUGIN" update-ref refs/remotes/origin/main HEAD
  printf UNPUBLISHED > "$PLUGIN/fragments/vendor/lib.py"; }
case31() { mk_submodule c31; git -C "$PLUGIN" config submodule.fragments/vendor.ignore all
  [ -z "$(git -C "$PLUGIN" status --porcelain --ignored --untracked-files=all -- fragments 2>/dev/null)" ] || fail "submodule: precondition -- configured status should look clean"
  refused "submodule hidden by config" 'uncommitted or ignored'; }
case32() { mk_submodule c32 ignore
  [ -z "$(git -C "$PLUGIN" status --porcelain --ignored --untracked-files=all -- fragments 2>/dev/null)" ] || fail "submodule: precondition -- shipped setting should look clean"
  refused "submodule hidden by .gitmodules" 'uncommitted or ignored'; }

# A repository git declines to open: discovery fails, yet an ancestor .git holds a HEAD.
case33() { mk_git c33; printf x >> "$PLUGIN/NOTES.md"; git -C "$PLUGIN" config core.repositoryformatversion 99
  git -C "$PLUGIN" rev-parse --git-dir >/dev/null 2>&1 && fail "unopenable repo: precondition -- git should decline"
  refused "repository git declines" 'cannot read the repository'; }
# Same, with a .git the hook cannot even inspect.
case34() { [ "$(id -u)" -ne 0 ] || { echo "SKIP: unreadable .git (root ignores chmod 000)"; return 0; }; mk_git c34; printf x >> "$PLUGIN/NOTES.md"; chmod 000 "$PLUGIN/.git"
  local rc=0; refused "unreadable .git" 'cannot read the repository' || rc=$?; chmod 755 "$PLUGIN/.git"; return $rc; }
# git answers `--git-dir` but not `ls-files` and no .git exists on the path (GIT_DIR in the environment).
case35() { mk_git c35; printf x >> "$PLUGIN/NOTES.md"; mv "$PLUGIN/.git" "$E/gd"; printf junk > "$E/gd/index"
  export GIT_DIR="$E/gd" GIT_WORK_TREE="$PLUGIN"
  git -C "$PLUGIN" ls-files >/dev/null 2>&1 && fail "env repo: precondition -- ls-files should fail"
  refused "repository from GIT_DIR" 'cannot read the repository'; }
# SIGKILL of a child that ignored SIGTERM is reported as the same timeout.
case36() { mk_env c36; mk_timeout 'exit 137'
  [ "$(run_hook)" = 0 ] || fail "SIGKILL: exit != 0"
  [ ! -e "$HASH" ] || fail "SIGKILL: sidecar written"
  grep -q 'exceeded 60s' "$E/stderr" || fail "SIGKILL: stderr lacks message: $(cat "$E/stderr")"; }
# No gsd-tools reachable: the timed child returns 127 and the hook says so, writing nothing.
case37() { mk_env c37; rm -f "$SPY/gsd-tools"
  # node alone (it reads the manifest for the consent check); no gsd-tools anywhere on PATH
  mkdir "$E/nodebin"; ln -s "$(command -v node)" "$E/nodebin/node"
  (cd "$CWD" && env -i PATH="$E/nodebin:/usr/bin:/bin" CLAUDE_PLUGIN_ROOT="$PLUGIN" GSD_HOME="$HOME_DIR" \
    bash "$PLUGIN/hooks/capability-auto-install.sh" "$ID" 2>"$E/stderr" >/dev/null)
  grep -q 'gsd-tools not found' "$E/stderr" || fail "127: stderr lacks message: $(cat "$E/stderr")"
  [ ! -e "$HASH" ] || fail "127: sidecar written"; }
# Paths arrive as argv in the timed child, never interpolated into its script.
case38() { mk_env c38; HOME_DIR="$E/h o'me"; mkdir -p "$HOME_DIR"; HASH="$HOME_DIR/.gsd/capability-auto-install-$ID.hash"
  [ "$(run_hook)" = 0 ] && [ "$(ncalls)" = 1 ] || fail "odd path: install did not run: $(cat "$E/stderr")"
  grep -qF "capability install $HOME_DIR/.gsd/capability-bundle-$ID --scope global --yes" "$CALLS" || fail "odd path: argv mangled: $(cat "$CALLS")"
  [ -s "$HASH" ] || fail "odd path: sidecar not written"; }
# The resolver comes from hooks/gsd-tools.sh, sourced in the timed child. A plugin copy
# without it must fail like a missing gsd-tools: message, no sidecar, retried next session.
case39() { mk_env c39; rm -f "$PLUGIN/hooks/gsd-tools.sh"
  [ "$(run_hook)" = 0 ] || fail "missing helper: exit != 0"
  [ "$(ncalls)" = 0 ] || fail "missing helper: spy called through an inline resolver"
  [ ! -e "$HASH" ] || fail "missing helper: sidecar written"
  grep -q 'gsd-tools not found' "$E/stderr" || fail "missing helper: stderr lacks message: $(cat "$E/stderr")"; }

# A clean filter maps an edited worktree file back onto its committed blob, so `status`
# is clean while the install copies the edit. Only a same-size edit reaches the filtered
# comparison (git trusts a changed size without running the filter). Ported from sota-numerics.
case40() { mk_git c40
  git -C "$PLUGIN" show HEAD:NOTES.md > "$E/canon"
  printf '#!/usr/bin/env bash\ncat >/dev/null\ncat "%s"\n' "$E/canon" > "$E/clean"; chmod +x "$E/clean"
  git -C "$PLUGIN" config filter.hide.clean "$E/clean"; printf 'NOTES.md filter=hide\n' >> "$PLUGIN/.git/info/attributes"
  { printf 'Z'; tail -c +2 "$E/canon"; } > "$PLUGIN/NOTES.md"
  cmp -s "$E/canon" "$PLUGIN/NOTES.md" && fail "filter: precondition -- the edit must differ"
  [ -z "$(git -C "$PLUGIN" status --porcelain --ignored --untracked-files=all --ignore-submodules=none -- NOTES.md 2>/dev/null)" ] || fail "filter: precondition -- the filtered status should look clean"
  refused "clean filter hiding an edit" 'filter attribute'; }
# check-attr cannot answer: refuse, do not read an empty answer as "no filter".
case41() { mk_git c41; local real; real="$(command -v git)"
  printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = check-attr ] && { echo "fatal: unreadable" >&2; exit 128; }; done\nexec "%s" "$@"\n' "$real" > "$SPY/git"; chmod +x "$SPY/git"
  refused "check-attr failing" 'filter attribute'; }
# A newline inside a tracked path must not shift the attribute triples. Only that file selects the filter.
case42() { mk_git c42; printf x > "$PLUGIN/fragments/$(printf 'zz\nb\nunspecified')"
  "${G[@]}" "$PLUGIN" add fragments; "${G[@]}" "$PLUGIN" commit -qm nl; git -C "$PLUGIN" update-ref refs/remotes/origin/main HEAD
  printf 'zz* filter=hide\n' >> "$PLUGIN/.git/info/attributes"
  refused "newline in a tracked path" 'filter attribute'; }
# `-filter` is the repository-local way out of a global rule.
case43() { mk_git c43; printf '* -filter\n' >> "$PLUGIN/.git/info/attributes"; installed "unset filter"; }

rc=0
for c in "1 baseline" "2 staging failure" "3 file boundary" "4 no home" "5 GSD_HOME only" "6 hostile repo" "7 executable surface" "8 stdin" "9 git unusable" "10 unpublished HEAD" "11 no upstream ref" "12 modified file" "13 untracked file" "14 ignored file" "15 symlink" "16 assume-unchanged" "17 repo tracks no bundle" "18 partly tracked" "19 published" "20 retry once published" "21 unreadable repo" "22 showUntrackedFiles=no" "23 symlinked bundle dir" "24 mirror repaired" "25 sidecar link" "26 bytes moved" "27 timeout wrap" "28 timeout kill" "29 timeout without -k" "30 fsmonitor" "31 submodule config" "32 submodule .gitmodules" "33 repo git declines" "34 unreadable .git" "35 GIT_DIR repo" "36 SIGKILL" "37 no gsd-tools" "38 odd path" "39 missing helper" "40 clean filter" "41 check-attr fails" "42 newline path" "43 unset filter"; do
  n="${c%% *}"
  if ( "case$n" ) >"$SCRATCH/out$n" 2>&1; then pass "case $c"; else cat "$SCRATCH/out$n"; rc=1; fi
done
[ "$rc" = 0 ] || exit 1
echo "ALL PASS"
