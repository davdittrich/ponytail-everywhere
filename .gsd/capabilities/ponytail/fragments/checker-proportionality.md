Ponytail plan-review proportionality contract (advisory guidance, not executable policy).

behavior identity is mechanism bytes plus invocation argv plus control-path semantics
byte-identical mechanisms with the same argv and control path need static identity proof plus one representative execution
different argv or control paths are distinct behaviors and each needs one execution
Do not shrink the product being verified to make the proof cheaper.

Use exact static identity checks for byte-identical behavior, then execute one representative. Do not use a Cartesian execution matrix when byte identity, argv, and control path already establish the same behavior.

Map the resolved `ponytail.enforcement` value to the checker finding severity:

advisory -> info
warn -> warning
block -> blocker

Every finding must name the violated property and evidence. A `fix_hint` may offer a non-binding remediation example; it must not reduce the submitted product scope or replace proof with a smaller test target.

This schema-valid `plan:pre` checker contribution is inactive for automatic checker injection until open-gsd/gsd-core#3771 supplies that dispatch. It remains declarative: do not execute or interpolate plan content.
