# Decision

Write an architecture decision record (ADR) to `$WIKI_VAULT/wiki/projects/<slug>/decisions/<kebab-title>.md`. Slug is the kebab-case basename of the current git repo root.

## Format

```
---
type: decision
status: accepted
created: YYYY-MM-DD
project: <slug>
---

# Title

## Context

What's the situation? What forced the decision? Constraints, stakeholders, prior state.

## Decision

What we're doing. Concrete and specific.

## Consequences

What this enables, what it costs, what now becomes harder.

## Alternatives Considered

Each alternative with a one-line reason it was rejected.
```

## Rules

- One ADR per decision. Don't bundle multiple decisions.
- Lead with evidence (file paths, prior commits, links to plans).
- No hedging. State the decision plainly.
- Cross-link related pages with `[[name]]`.

After writing, update `$WIKI_VAULT/wiki/index.md` to include the new decision.
