# ponytail capability — what actually reaches an agent

This capability declares three `contributions[]` entries at `plan:pre`, `execute:wave:pre`, and
`execute:wave:post`. Only one of them is functional at gsd-core 1.10.0.

**Point correction (discovered at install time, not by RESEARCH.md):** the third entry was
originally authored at `verify:pre` with `into: "verifier"`. `capability install` rejected it:
gsd-core's generated Loop Host Contract (`bin/lib/loop-host-contract.cjs`) restricts `verify:pre`/
`verify:post`'s valid `contribution.into` values to `["orchestrator"]` only — the `"verifier"`
agent role is contractually valid solely within the `execute` step's points
(`execute:pre`/`execute:wave:pre`/`execute:wave:post`/`execute:post`, agentRoles
`["executor", "verifier"]`), never within the `verify` step's own points. The entry was relocated
to `execute:wave:post` (post-wave, pairing naturally with `execute:wave:pre`'s pre-wave executor
reminder) with `into: "verifier"` preserved, rather than keeping the point and changing `into` to
`"orchestrator"` — the latter would satisfy validation but defeat D-05's role-matched intent, since
the fragment's whole purpose is to speak to "the verifier," not a second generic orchestrator
reminder. `capability-validator.cjs`'s only contract check for `contributions[]` is
`contrib.into ∈ POINT_TO_CONTRACT.get(contrib.point).agentRoles`; no other structural constraint was
violated.

## Functional today

`plan:pre` → `into: "planner"` is the sole `kind == "contribution"` injection loop that exists
anywhere in the shipped gsd-core workflow markdown (`plan-phase.md`). When `ponytail.enabled`
resolves true, `fragments/planner-ladder.md` is read and injected verbatim into the `gsd-planner`
subagent's own prompt, along with the resolved `ponytail.level` value via `configValues`.

Quick planning uses the same contribution through the project-scoped
`skills/quick-planner` bridge when that path is appended to
`agent_skills.gsd-planner`. The bridge asks `render-hooks plan:pre` for the
resolved registry and emits only Ponytail's active planner fragment. It copies
no ladder text and applies equally to standard, validate, and full Quick modes.
This bridge remains downstream-only until open-gsd/gsd-core#3778 ships; #5
tracks its removal in favor of native Quick dispatch.

Both standard and bridged Quick planner delivery use the same current-evidence rule: historical context may guide discovery but cannot authorize concrete mutable targets without a current task-relevant observation. Explicit user-fixed and immutable scope stays concrete; unobserved mutable scope stays conditional and observes first; drift-prone plan-time evidence uses one concrete read-only task-local `<precondition>` immediately before mutation. Facts produced by the task and ordering already expressed by `depends_on` do not gain redundant preconditions.

## Plan-review checker declaration

`plan:pre` → `into: "checker"` resolves `fragments/checker-proportionality.md` verbatim with
`ponytail.enforcement`. The declaration is schema-valid in gsd-core 1.11.0 but remains declarative because gsd-core has no generic automatic checker-contribution dispatcher. [open-gsd/gsd-core#3771](https://github.com/open-gsd/gsd-core/issues/3771) addresses non-binding remediation revision conflicts, not that dispatch. Do not claim present checker delivery, patch gsd-core, or add a local
bridge: this capability owns only the declarative contribution.

The fragment keeps verification proportional: equal mechanism bytes, argv, and control path get
static identity proof plus one execution; a behavior-selecting argv or control-path difference gets
one execution per distinct behavior. Findings require property and evidence, and `fix_hint` text is
explicitly non-binding so it cannot reduce product scope. Re-consent after this bundle change before
relying on its project-scope contribution.

## Declared but undelivered at the execute points

`execute:wave:pre` → `into: "executor"` and `execute:wave:post` → `into: "verifier"` are
schema-valid, name roles the generated loop host contract publishes for those points, and are
returned by `gsd_run loop render-hooks <point> --raw` in `activeHooks` exactly like the `plan:pre`
entries.

gsd-core 1.12.0 added generic contribution dispatch at both points — 1.11.0 had none — so the
execute workflow now tells the orchestrator to inject every `kind == "contribution"` fragment per
`references/loop-hook-dispatch.md`. That instruction is necessary, not sufficient. The plan workflow
also carries an explicit landing site inside the planner subagent prompt that injects each
`into == "planner"` fragment verbatim. The execute workflow carries no `into ==` selection anywhere:
its executor `Agent(prompt=...)` template has no contribution block, and the one `gsd-verifier` spawn
it does contain sits after the wave loop, not at `execute:wave:post`. Both fragments therefore land
in the orchestrator's own context and reach neither target agent.

Do not describe these two contributions as functional. `tests/test-execute-contributions.sh` pins the
observed state from both sides: it proves the dispatch instruction exists at both points, proves the
landing-site probe is not blind by finding the planner one, and fails the moment an executor or
verifier landing site appears — update this section and the README in that same change.

Tracked upstream as open-gsd/gsd-core#XXXX. Related: open-gsd/gsd-core#3997 asks for the same landing
site in external reviewer prompts; open-gsd/gsd-core#4286 records the upstream position that an
admissible role is not reach.

`engines.gsd` stays `>=1.10.0`. Raising it to `>=1.12.0` would gate the whole capability — including
the `plan:pre` planner contribution, which works on 1.10.0 and 1.11.0 — on a release that delivers
nothing extra to these two entries. Raise it when a landing site makes them functional.

`gsd_run loop render-hooks verify:pre --raw` returns zero `ponytail` entries, and always will under
this design — `verify:pre`'s only legal `contribution.into` value is `"orchestrator"` (see the Point
correction above), which this capability does not target.

Actual execute-time and verify-time reach in this repo comes from a different mechanism entirely:
the sibling `ponytail-everywhere` Claude Code plugin's role-matched `SubagentStart` hooks (Plan 01),
which fire directly on `gsd-executor` and `gsd-verifier` subagent spawn regardless of what any
`capability.json` `contributions[]` entry declares.

## Why no gsd-core patch (D-01)

`.gsd/capabilities/beads/GSD-CORE-PATCH.md` records this repo's one precedent for patching a
machine-local gsd-core workflow file to add missing generic dispatch (`ship:pre` gate dispatch). That
patch is deliberately not repeated here: D-01 scopes this capability to the one lifecycle point that
already has real generic contribution dispatch, and the `ponytail-everywhere` plugin's hooks cover
the remaining reach without touching gsd-core at all. Patching `plan-phase.md`/`execute-plan.md` to
add contribution dispatch at more points is out of scope for this phase.

## Toggle-testing gotcha: `--cwd` mirror alone is not enough (discovered at Task 3)

`gsd-tools`'s project-scope consent (`#1459`) binds to the *realpath of the project root*, not
just to the capability bundle's content hash. A `mktemp -d` mirror directory symlinked back to
this repo's `.gsd`/`.gsd-capabilities.json`/`.git` — even with a real, unmodified copy of
`.planning/config.json` — resolves to a **different** realpath than this repo's own root, so
`gsd_tools loop render-hooks <point> --raw --cwd <mirror>` reports `ponytail` as
`"discovered — no user consent record (inactive)"` even though the real root shows it active.
Testing the `ponytail.enabled` toggle against such a mirror therefore requires granting a
*separate* consent record for the mirror's own realpath — done here via the `GSD_HOME` env var
(an existing, already-documented gsd-tools override, not new infrastructure), pointed at a second
`mktemp -d` scratch directory so the record never touches the real `$HOME/.claude` consent store:
`GSD_HOME=<scratch> gsd_tools capability install ./.gsd/capabilities/ponytail --scope project
--yes --cwd <mirror>`, then `GSD_HOME=<scratch> gsd_tools loop render-hooks ... --cwd <mirror>`
for both the baseline and `ponytail.enabled: false` checks. Both scratch directories are removed
on exit; nothing under `$HOME/.claude` or this repo's `.planning/config.json` is touched.

## Re-consent after any edit

Project-scope consent (`capability install ./.gsd/capabilities/ponytail --scope project --yes`) is a
whole-bundle content hash over every file under `.gsd/capabilities/ponytail/`. Editing any file here
— including this one — silently deactivates the capability until `capability install` is re-run.
