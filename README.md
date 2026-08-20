# ponytail-everywhere

Lazy-ladder discipline and proportionality checks across gsd's plan/execute/verify/ship lifecycle

## What it does

`ponytail-everywhere` is a [gsd-core](https://github.com/open-gsd/gsd-core) capability — an
installable overlay, not a fork — that injects advisory lazy-ladder discipline (YAGNI, reuse
before writing, stdlib/native before dependencies, shortest working diff) at three gsd lifecycle
points: the planner at `plan:pre`, the executor at `execute:wave:pre`, and the verifier at
`execute:wave:post`. It also prints the same ladder banner on Claude Code's `SessionStart` and on
`gsd-planner`/`gsd-executor`/`gsd-verifier` subagent start, so the discipline reminder reaches a
session whether or not a gsd phase is currently running.

## Pre-expansion proportionality

Claude Code checks proportionality before expanding these five commands:

- `gsd-new-project`
- `gsd-new-milestone`
- `gsd-manager`
- `gsd-mvp-phase`
- `gsd-discuss-phase`

The hook recommends one route based on observable scope:

| Route | Use when |
|---|---|
| `direct` | Read-only review, explanation, diagnosis, or one action needing no durable plan |
| `quick` | A bounded, atomic implementation fix |
| `phase` | A coherent multi-step capability in the existing project or milestone |
| `milestone` | A new project direction or coordinated set of phases with roadmap impact |

A positive mismatch exists only when the recommended route is narrower than the submitted
command. A milestone recommendation and insufficient evidence are never positive mismatches.

`ponytail.enforcement` controls the result and defaults to `warn`:

| Mode | Positive mismatch | Proportionate or broader work |
|---|---|---|
| `advisory` | Allow with route guidance | Allow silently |
| `warn` | Stop expansion and require an explicit direct, quick, phase, or milestone resubmission | Allow silently |
| `block` | Stop expansion; resubmit the same command with `[ponytail:milestone]` to override once | Allow silently |

The marker applies only to the submission containing it; it creates no persistent approval.
Classification uses conservative local rules first. Only ambiguous requests invoke Claude in
print mode. Recognized GitHub issue, pull request, review, and issue-comment URLs may be read with
`gh api --method GET`; each lookup has a three-second timeout and only bounded evidence reaches
the classifier. Missing tools, timeouts, errors, invalid output, and low-confidence results fail
open with advisory context rather than blocking work. `ponytail.enabled=false` makes the hook
silent before classification or lookup.

The decision creates no planning, audit, approval, cache, or recommendation-history artifacts.
This pre-command interception currently applies only to Claude Code, which consumes the plugin's
`UserPromptExpansion` hook. Codex does not consume that Claude plugin hook and does not receive
this interception from this repository.

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

- **Lifecycle reminders remain advisory.** All three lifecycle contributions declare
  `onError: skip`; only the Claude Code pre-expansion check can block, according to
  `ponytail.enforcement`.
- **Three config keys**, read from a project's `.planning/config.json`: `ponytail.enabled`
  (boolean, default `true`), `ponytail.level` (`lite` | `full` | `ultra`, default `full`), and
  `ponytail.enforcement` (`advisory` | `warn` | `block`, default `warn`).
- **The `SessionStart` hook re-grants the capability bundle at user scope on every session
  start**, and exits silently when the bundle is unchanged.
- **Installing through the marketplace copies the cloned repo into the installer's local plugin
  cache** under `~/.claude/plugins/cache/` — documented Claude Code behavior this repo does not
  control.

## License

MIT — see [LICENSE](LICENSE).

## gsd-core

`ponytail-everywhere` is a capability for [gsd-core](https://github.com/open-gsd/gsd-core).
