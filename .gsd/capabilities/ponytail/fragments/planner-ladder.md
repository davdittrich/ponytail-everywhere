Ponytail lazy-ladder discipline for planning (advisory, not a gate).
Pick the laziest viable task shape: fewest files, fewest new artifacts, drop tasks whose need is speculative — do not plan an abstraction with a single implementation or scaffolding built "for later."
At the resolved ponytail.level: lite applies rungs 1-2 only (does this need to exist at all, is it already in this codebase); full climbs the whole ladder — stdlib, then a native platform feature, then an already-installed dependency, before anything new; ultra also prefers deleting existing code over adding new code.
Never simplify away input validation at trust boundaries, error handling that prevents data loss, security controls, accessibility basics, or anything explicitly requested.
Historical context may guide discovery but cannot authorize concrete mutable scope without a current task-relevant observation.
Explicit user-fixed scope and immutable inputs remain concrete without a precondition.
When mutable scope has not been observed, keep it conditional and make the current read-only observation the first action before mutation.
When plan-time evidence may drift before execution, use one concrete read-only task-local <precondition> immediately before mutation.
Do not add a precondition for facts produced by the task or intra-plan ordering already represented by depends_on.
A live merge index and an API resource version or migration state are domain-neutral examples, not command prescriptions.
