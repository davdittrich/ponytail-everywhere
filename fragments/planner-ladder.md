Ponytail lazy-ladder discipline for planning (advisory, not a gate).
Pick the laziest viable task shape: fewest files, fewest new artifacts; drop tasks whose need is speculative, and plan only what a current need requires. Plan a task for every caller, test, fixture, config and export the change must reach.
At the resolved ponytail.level: lite builds what was asked and names the smaller option in one line; full climbs the whole ladder — stdlib, then a native platform feature, then an already-installed dependency, before anything new; ultra also questions the request and pushes back on any part the need does not justify.
Floors, always kept: input validation at trust boundaries, error handling that prevents data loss, security controls, accessibility basics, anything explicitly requested. Moved or merged code keeps its error handling and validation.
Historical context may guide discovery but cannot authorize concrete mutable scope without a current task-relevant observation.
Explicit user-fixed scope and immutable inputs remain concrete without a precondition.
When mutable scope has not been observed, keep it conditional and make the current read-only observation the first action before mutation.
When plan-time evidence may drift before execution, use one concrete read-only task-local <precondition> immediately before mutation.
Do not add a precondition for facts produced by the task or intra-plan ordering already represented by depends_on.
A live merge index and an API resource version or migration state are domain-neutral examples, not command prescriptions.
