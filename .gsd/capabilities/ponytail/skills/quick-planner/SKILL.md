---
name: quick-planner
description: Deliver Ponytail's active planner contribution during GSD Quick planning when this project configures the bridge for gsd-planner.
---

# Ponytail Quick Planner Bridge

Before writing the Quick plan, run this once from the project root:

```bash
gsd-tools loop render-hooks plan:pre --raw 2>/dev/null \
  | node .gsd/capabilities/ponytail/skills/quick-planner/render.cjs
```

If stdout is non-empty, apply it once as advisory planning guidance. If it is
empty, continue without Ponytail guidance. Do not separately load or render a
Ponytail planner contribution; the renderer already selects the active one.
