# Plan

Write a plan or PRD to `<vault>/wiki/projects/<slug>/plans/<kebab-title>.md`. Take `<vault>` and `<slug>` from the session's `WIKI:` line; without one, `<vault>` is the vault the wiki-maintenance rule names and the slug is the kebab-case basename of the main checkout (`git rev-parse --path-format=absolute --git-common-dir` without `/.git`), never a worktree.

## Format

```
---
type: plan
status: active
created: YYYY-MM-DD
updated: YYYY-MM-DD
tags:
  - plan
  - <slug>
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
- After writing, list the page in `<vault>/wiki/projects/<slug>/index.md` (`plans/<kebab-title>.md` plus a short description). Never edit `<vault>/wiki/index.md`, which the harness generates.
