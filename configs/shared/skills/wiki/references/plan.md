## For /wiki plan <title>

Create a plan/PRD page for the current project.

### Step 1 — Resolve project and vault

### Step 2 — Write plan page

Write to `wiki/projects/<slug>/plans/<title-kebab>.md`:

```markdown
---
type: plan
status: active
created: YYYY-MM-DD
updated: YYYY-MM-DD
tags:
  - plan
  - <project-slug>
project: <project-slug>
---

# <Title>

## Goal

<What this plan aims to achieve, in 1-2 sentences>

## Background

<Why this work is needed, what prompted it>

## Approach

<How it will be done — architecture, key decisions, implementation strategy>

## Scope

<What's in and what's out>

## Open Questions

- <Unresolved questions that need answers>
```

Fill the content from the current session context (the planning discussion that just happened). Do not fabricate — only include what was actually discussed.

### Step 3 — Update devlog and index

Add a devlog entry noting the plan was created. Update wiki/index.md with the new plan page entry.
