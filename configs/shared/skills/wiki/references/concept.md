## For /wiki concept <title>

Create or update a concept page. If `--project` is given or the concept is clearly project-specific, put it in the project directory. Otherwise use the cross-project `wiki/concepts/` directory.

**Creating:**

```markdown
---
type: concept
created: YYYY-MM-DD
updated: YYYY-MM-DD
tags:
  - concept
  - <domain tags>
  - stub
source_count: 1
---

# <Concept Name>

## Definition

<Crisp 1-2 sentence definition>

## Explanation

<Detailed explanation with [[wikilinks]] to related concepts>

## Related Concepts

- [[Related]] — <nature of relationship>

## Sources

- <What informed this page>
```

**Updating:** Read existing page, weave in new information, bump counts, note contradictions.
