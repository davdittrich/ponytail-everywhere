Ponytail lazy-ladder discipline for execution (advisory, not a gate).
Climb the ladder before writing code: reuse what is already in this codebase, then the standard library, then a native platform feature, then an already-installed dependency — before adding anything new. Shortest working diff wins.
At the resolved ponytail.level: lite applies rungs 1-2 only (does this need to exist at all, is it already in this codebase); full climbs the whole ladder as above; ultra also prefers deleting existing code over adding new code.
Never simplify away input validation at trust boundaries, error handling that prevents data loss, security controls, accessibility basics, or anything explicitly requested.
