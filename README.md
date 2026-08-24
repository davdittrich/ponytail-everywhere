# ponytail-everywhere

Lazy-ladder discipline and proportionality checks across gsd's plan/execute/verify/ship lifecycle

## What it does

`ponytail-everywhere` is a [gsd-core](https://github.com/open-gsd/gsd-core) capability — an
installable overlay, not a fork — that injects advisory lazy-ladder discipline (YAGNI, reuse
before writing, stdlib/native before dependencies, shortest working diff) at three gsd lifecycle
points: the planner at `plan:pre`, the executor at `execute:wave:pre`, and the verifier at
`execute:wave:post`. It also prints the same ladder banner on Claude Code's `SessionStart` and on
`gsd-planner`/`gsd-executor`/`gsd-code-reviewer`/`gsd-verifier` subagent start, so the discipline
reminder reaches a session whether or not a gsd phase is currently running.

### Claude collaborator review guidance

Claude-only `SubagentStart` routing sends `gsd-code-reviewer` and `gsd-verifier` through the existing
verifier role. Malformed or missing collaborator output must be detected and reported, never silently
accepted as a passing result. Format, style, and quality failures are non-blocking only when safe
continuation preserves artifact integrity and all external contracts.

- When evidenced, required findings: unhandled edge cases, ignored return values, swallowed errors, invalid boundary
  inputs, lazy structure, and plan-transcription code.
- Suggestions: evidence-backed performance, testing, intent, and minor-style concerns, unless an
  independent non-waivable condition applies.
- Non-waivable blockers: security, trust-boundary, data-loss, race, accessibility, source/document divergence,
  constructor-divergence, ASVS, and TDD.

Runtime-neutral collaborator guidance remains tracked in
[issue #3](https://github.com/davdittrich/ponytail-everywhere/issues/3).

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

### Quick planner bridge

GSD Quick does not yet dispatch `plan:pre` planner contributions. Install the
Ponytail capability into each GSD project that needs runtime-neutral Quick
delivery, then append its project-relative bridge to that project's
`.planning/config.json`:

```bash
gsd-tools capability install /path/to/ponytail-everywhere/.gsd/capabilities/ponytail \
  --scope project --yes
```

```json
{
  "agent_skills": {
    "gsd-planner": [
      "existing/planner-skill",
      ".gsd/capabilities/ponytail/skills/quick-planner"
    ]
  }
}
```

Keep every existing `gsd-planner` entry in its current order and append the
bridge once. Configuration is intentionally per-project: a project with its own
`.planning/config.json` does not inherit `agent_skills` from user defaults.
The bridge covers `/gsd-quick`, `/gsd-quick --validate`, and `/gsd-quick --full`;
it resolves the active Ponytail `plan:pre` contribution, so disabled,
runtime-incompatible, and absent contributions remain silent and
`ponytail.level` uses the same fragment as normal phase planning. Native Quick
dispatch will replace this bridge after
[open-gsd/gsd-core#3778](https://github.com/open-gsd/gsd-core/issues/3778) ships,
tracked by [#5](https://github.com/davdittrich/ponytail-everywhere/issues/5).

The active planner contribution applies the same scope rule in standard planning and bridged Quick planning: historical context may guide discovery but cannot authorize concrete mutable targets without a current task-relevant observation. Explicit user-fixed and immutable scope stays concrete; unobserved mutable scope stays conditional and observes first; drift-prone plan-time evidence uses one concrete read-only task-local `<precondition>` immediately before mutation. Facts produced by the task and ordering already expressed by `depends_on` do not gain redundant preconditions.

### Plan-review proportionality

The capability also declares one schema-valid `plan:pre` contribution for the `checker` role. It asks plan review to prove only genuinely distinct behavior: compare identical mechanism bytes statically, execute one representative for identical argv and control flow, and execute once per distinct argv or control path. `ponytail.enforcement` maps to checker `info` (`advisory`), `warning` (`warn`), or `blocker` (`block`) findings; each finding names the violated property and evidence, while any `fix_hint` is non-binding.

This declaration does not currently inject into automatic checker runs because gsd-core has no generic checker-contribution dispatcher. [open-gsd/gsd-core#3771](https://github.com/open-gsd/gsd-core/issues/3771) addresses non-binding remediation revision conflicts, not checker-contribution dispatch. After any capability-bundle edit, re-consent with `gsd-tools capability install /path/to/ponytail-everywhere/.gsd/capabilities/ponytail --scope project --yes`; project-scope consent hashes the entire bundle.

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
