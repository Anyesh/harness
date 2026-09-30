## For /wiki decide <title>

Create an architecture decision record.

Write to `wiki/projects/<slug>/decisions/<title-kebab>.md`:

```markdown
---
type: decision
status: accepted
created: YYYY-MM-DD
updated: YYYY-MM-DD
tags:
  - decision
  - <project-slug>
project: <project-slug>
---

# <Title>

## Context

<What situation prompted this decision>

## Decision

<What was decided, stated directly>

## Consequences

<What follows from this decision — tradeoffs accepted, constraints introduced>

## Alternatives Considered

- **<Alternative A>** — <why not chosen>
- **<Alternative B>** — <why not chosen>
```

Fill from session context. Update devlog and wiki/index.md.
