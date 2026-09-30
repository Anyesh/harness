---
allowed-tools: Bash(~/.claude/scripts/cmd-context.sh *)
argument-hint: <plan title>
---

# Plan

Write a plan or PRD to `<wiki_vault>/wiki/projects/<repo_slug>/plans/<kebab-title>.md`, using the values below.

## Context

!`~/.claude/scripts/cmd-context.sh plan`

Use `repo_slug`, `wiki_vault` and `today` exactly as printed. The `plans` listing shows existing plans; extend or cross-link one instead of duplicating it.

## Format

```
---
type: plan
status: active
created: <today>
project: <repo_slug>
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
- After writing, update `<wiki_vault>/wiki/index.md` (wiki_index says whether it exists).
