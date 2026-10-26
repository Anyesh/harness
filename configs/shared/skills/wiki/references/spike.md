## For /wiki spike <title>

Document an exploration or prototype attempt.

Write to `wiki/projects/<slug>/spikes/<title-kebab>.md`:

```markdown
---
type: spike
outcome: <success|abandoned|partial>
created: YYYY-MM-DD
tags:
  - spike
  - <project-slug>
project: <project-slug>
---

# <Title>

## Question

<What was being investigated>

## What Was Tried

<What approaches were attempted, in order>

## Findings

<What was learned — facts discovered, not opinions>

## Conclusion

<The takeaway: what to do next, or why this was abandoned>
```

Fill from session context. Add a devlog entry and list the page in the project's `index.md` (`spikes/<title-kebab>.md` plus a short description). Never edit `wiki/index.md`, which is generated.
