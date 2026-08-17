# ponytail-everywhere

Advisory-only lazy-ladder discipline reminders across gsd's plan/execute/verify/ship lifecycle

## What it does

`ponytail-everywhere` is a [gsd-core](https://github.com/open-gsd/gsd-core) capability — an
installable overlay, not a fork — that injects advisory lazy-ladder discipline (YAGNI, reuse
before writing, stdlib/native before dependencies, shortest working diff) at three gsd lifecycle
points: the planner at `plan:pre`, the executor at `execute:wave:pre`, and the verifier at
`execute:wave:post`. It also prints the same ladder banner on Claude Code's `SessionStart` and on
`gsd-planner`/`gsd-executor`/`gsd-verifier` subagent start, so the discipline reminder reaches a
session whether or not a gsd phase is currently running.

## Requirements

- Bash (POSIX shell)
- gsd-core >= 1.10.0

## Install

```bash
claude plugin marketplace add davdittrich/gsd-beads
claude plugin install ponytail-everywhere@gsd-beads -y
```

The marketplace stays hosted at `davdittrich/gsd-beads` even though this plugin lives in its own
repo — the marketplace entry just points here.

## Uninstall

```bash
claude plugin uninstall ponytail-everywhere -y
```

## Caveats

- **Advisory, never blocking.** All three lifecycle contributions declare `onError: skip` — a
  failure degrades to silence rather than halting a phase.
- **Two config keys**, both read from a project's `.planning/config.json`: `ponytail.enabled`
  (boolean, default `true`) and `ponytail.level` (`lite` | `full` | `ultra`, default `full`).
- **The `SessionStart` hook re-grants the capability bundle at user scope on every session
  start**, and exits silently when the bundle is unchanged.
- **Installing through the marketplace copies the cloned repo into the installer's local plugin
  cache** under `~/.claude/plugins/cache/` — documented Claude Code behavior this repo does not
  control.

## License

MIT — see [LICENSE](LICENSE).

## gsd-core

`ponytail-everywhere` is a capability for [gsd-core](https://github.com/open-gsd/gsd-core).
