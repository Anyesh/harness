# Plan

Write a plan or PRD to `$WIKI_VAULT/wiki/projects/<slug>/plans/<kebab-title>.md`. Slug is the kebab-case basename of the current git repo root.

## Format

```
---
type: plan
status: active
created: YYYY-MM-DD
project: <slug>
---

# Title

## Goal

One paragraph: what we're trying to accomplish and why.

## Background

What the reader needs to know to understand the rest. Prior decisions, constraints, current state.

## Approach

How we'll get there. Specific steps, files to create/modify, build sequence.

## Scope

In scope. Out of scope. Be explicit about both.

## Open Questions

Things still to decide, with a recommended answer for each if you have one.
```

## Rules

- One plan per concrete piece of work.
- Approach section names specific files and steps, not vague intentions.
- Cross-link related pages with `[[name]]`.
- After writing, update `$WIKI_VAULT/wiki/index.md`.
