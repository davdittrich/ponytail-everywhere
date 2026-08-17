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

## Forward-compatible no-ops today

`execute:wave:pre` → `into: "executor"` and `execute:wave:post` → `into: "verifier"` are schema-valid
and are returned by `gsd_run loop render-hooks <point> --raw` in `activeHooks` exactly like the
`plan:pre` entry — the resolver is generic across all lifecycle points. But no workflow markdown at
either of those points contains a `kind == "contribution"` read-and-inject instruction, so today
these two entries are read by nobody. They are declared anyway, matching D-05's role-tailored intent
and this repo's own `beads` capability precedent of declaring `steps[]` entries beyond the minimum
functional set — should a future gsd-core version add generic contribution dispatch at those points,
these entries activate with no change to this capability. `gsd_run loop render-hooks verify:pre --raw`
returns zero `ponytail` entries, and always will under this design — `verify:pre`'s only legal
`contribution.into` value is `"orchestrator"` (see Point correction above), which this capability
does not target.

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
