---
allowed-tools: Bash(~/.claude/scripts/cmd-context.sh *)
argument-hint: <decision title>
---

# Decision

Write an architecture decision record (ADR) to `<wiki_vault>/wiki/projects/<repo_slug>/decisions/<kebab-title>.md`, using the values below.

## Context

!`~/.claude/scripts/cmd-context.sh decision`

Use `repo_slug`, `wiki_vault` and `today` exactly as printed. The `decisions` listing shows existing ADRs; avoid duplicating one, and cross-link related ones.

## Format

```
---
type: decision
status: accepted
created: <today>
project: <repo_slug>
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

After writing, update `<wiki_vault>/wiki/index.md` (wiki_index says whether it exists) to include the new decision.
