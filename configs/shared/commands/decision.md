# Decision

Write an architecture decision record (ADR) to `<vault>/wiki/projects/<slug>/decisions/<kebab-title>.md`. Take `<vault>` and `<slug>` from the session's `WIKI:` line; without one, `<vault>` is the vault the wiki-maintenance rule names and the slug is the kebab-case basename of the main checkout (`git rev-parse --path-format=absolute --git-common-dir` without `/.git`), never a worktree.

## Format

```
---
type: decision
status: accepted
created: YYYY-MM-DD
updated: YYYY-MM-DD
tags:
  - decision
  - <slug>
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

After writing, list the decision in `<vault>/wiki/projects/<slug>/index.md` (`decisions/<kebab-title>.md` plus a short description). Never edit `<vault>/wiki/index.md`, which the harness generates.
