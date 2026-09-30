## For /wiki init

### Step 1 — Validate path

Check if `<vault-path>` exists. Create if not. If it already contains `WIKI_SCHEMA.md`, warn and ask to confirm re-init.

### Step 2 — Create structure

```
mkdir -p <vault-path>/wiki/projects
mkdir -p <vault-path>/wiki/concepts
mkdir -p <vault-path>/wiki/synthesis
mkdir -p <vault-path>/wiki/sources
mkdir -p <vault-path>/raw/assets
```

### Step 3 — Write WIKI_SCHEMA.md

Write to `<vault-path>/WIKI_SCHEMA.md`:

```markdown
---
vault_name: "<basename>"
created: "YYYY-MM-DD"
version: 2
---

# Wiki Schema

LLM-maintained knowledge wiki. The LLM reads this at the start of every operation.

## Page Types

### Devlog Entry (append-only per project)
- Location: `wiki/projects/<slug>/devlog.md`
- Format: H2 dated entries, newest first
- Content: what was worked on, key outcomes, links to decisions/plans/spikes created

### Decision (ADR)
- Location: `wiki/projects/<slug>/decisions/<title>.md`
- Frontmatter: type, status (proposed|accepted|superseded), created, updated, tags
- Sections: Context, Decision, Consequences, Alternatives Considered

### Plan / PRD
- Location: `wiki/projects/<slug>/plans/<title>.md`
- Frontmatter: type, status (draft|active|completed|abandoned), created, updated, tags
- Sections: Goal, Background, Approach, Scope, Open Questions

### Spike / Exploration
- Location: `wiki/projects/<slug>/spikes/<title>.md`
- Frontmatter: type, outcome (success|abandoned|partial), created, tags
- Sections: Question, What Was Tried, Findings, Conclusion

### Concept
- Location: `wiki/concepts/<title>.md` (cross-project) or `wiki/projects/<slug>/concepts/<title>.md` (project-specific)
- Frontmatter: type, created, updated, tags, source_count
- Sections: Definition, Explanation, Related Concepts, Sources

### Source Summary
- Location: `wiki/sources/<title>.md`
- Frontmatter: type, created, source_url, source_type, author, tags
- Sections: Summary, Key Claims, Entities Mentioned, Concepts Discussed

### Synthesis
- Location: `wiki/synthesis/<title>.md`
- Frontmatter: type, created, query, tags, source_count
- Sections: Question, Answer, Evidence, Sources

## Frontmatter Conventions

- `type`: devlog, decision, plan, spike, concept, source, synthesis
- `created` / `updated`: YYYY-MM-DD
- `tags`: YAML list, no # prefix
- `status`: lifecycle state (varies by type)
- `source_count`: number of sources informing this page
- `project`: project slug (for cross-referencing)

## Linking

- Use Obsidian wikilinks: `[[Page Name]]`
- Display aliases: `[[kebab-name|Display Name]]`
- Wikilink entities and concepts on first mention per section
- Every page has a `## Sources` or `## References` section

## Quality

- Pages with source_count < 2 are `stub`
- Pages with source_count >= 3 are `mature`
- Pages not updated in 90 days are flagged stale in lint
- Contradictions noted explicitly with both claims cited
```

### Step 4 — Write index.md

```markdown
---
type: index
created: YYYY-MM-DD
updated: YYYY-MM-DD
---

# Wiki Index

Master catalog. The LLM reads this first to find relevant pages.

## Projects

_No projects yet._

## Concepts

_No concepts yet._

## Sources

_No sources yet._

## Syntheses

_No syntheses yet._
```

### Step 5 — Write .wiki-vault breadcrumb

Write vault path to `.wiki-vault` in current working directory.

### Step 6 — Report

```
Wiki initialized at <vault-path>

  WIKI_SCHEMA.md    — conventions (edit to customize)
  wiki/index.md     — master catalog (update every session, no exceptions)

Open in Obsidian and start working. The wiki grows as you do.
```
