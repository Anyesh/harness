---
name: wiki
description: >
  LLM-maintained knowledge wiki (Karpathy pattern). Ingest sources, maintain
  structured Obsidian pages, query with citations, lint for quality. Triggers on:
  "wiki ingest", "wiki query", "wiki lint", "wiki init", "add to wiki",
  "what does the wiki say about", "check wiki health".
trigger: /wiki
---

# /wiki

A persistent, compounding knowledge base maintained by the LLM during development sessions. Based on Andrej Karpathy's LLM Wiki pattern: instead of re-deriving knowledge on every query, the LLM incrementally builds and maintains structured wiki pages where cross-references exist, contradictions are flagged, and synthesis reflects everything explored. The wiki gets richer with every session.

The human never writes the wiki. The LLM writes and maintains all of it. The human curates what matters, directs analysis, and browses results in Obsidian.

## Usage

```
/wiki init <vault-path>              # create vault structure + schema
/wiki log                            # write devlog entry for current session
/wiki plan <title>                   # capture a planning session / PRD
/wiki decide <title>                 # record an architecture/design decision
/wiki spike <title>                  # document an exploration that was tried
/wiki concept <title>                # create/update a concept page
/wiki ingest <url-or-path>           # ingest external source into wiki
/wiki ingest --batch <dir>           # batch ingest directory
/wiki query "<question>"             # search wiki, synthesize answer
/wiki query "<question>" --file      # same + save as synthesis page
/wiki lint                           # structural health check
/wiki lint --fix                     # lint and auto-fix safe issues
/wiki status                         # quick summary of wiki state
```

## Vault Path Resolution

Find the vault in this order (first match wins):

1. Explicit `--vault <path>` argument
2. `.wiki-vault` file in current working directory (one line: absolute vault path)
3. `WIKI_VAULT` environment variable
4. Error: no vault found

Once resolved, verify path contains `WIKI_SCHEMA.md`.

## Per-Project Organization

The wiki is organized by project. Each project the user works on gets its own section:

```
<vault>/wiki/
├── projects/
│   ├── <project-slug>/
│   │   ├── overview.md        # what the project is, current state
│   │   ├── devlog.md          # append-only session log
│   │   ├── decisions/         # ADRs (architecture decision records)
│   │   ├── plans/             # planning docs, PRDs, specs
│   │   ├── spikes/            # explorations, prototypes, things tried
│   │   └── concepts/          # project-specific concepts
│   └── ...
├── concepts/                  # cross-project concepts
├── synthesis/                 # cross-project analyses, filed queries
├── sources/                   # external source summaries
├── raw/                       # immutable source copies
│   └── assets/
├── index.md                   # master catalog
└── WIKI_SCHEMA.md             # conventions (written by /wiki init)
```

**Project slug** is derived from the git repo name or directory basename (kebab-case). The LLM determines the current project from `git rev-parse --show-toplevel` or `$PWD`.

---

## Proactive Wiki Maintenance (Continuous Mode)

The LLM should update the wiki proactively during sessions when significant work happens. This is not triggered by `/wiki` — it happens naturally as part of the workflow. Specifically:

**Write to the wiki when:**
- A planning session produces a concrete plan or PRD
- An architecture/design decision is made (especially with tradeoffs discussed)
- A spike or exploration is completed (whether it succeeded or was abandoned)
- A brainstorming session produces ideas worth remembering
- A concept is explained or discussed in depth for the first time
- Scope is defined and rationale captured

**Do NOT write to the wiki for:**
- Routine code changes (bug fixes, refactors) unless they reveal something surprising
- Debugging steps (unless the root cause is non-obvious and worth documenting)
- Session transcripts or play-by-play narration
- AI-generated summaries of what was just done
- File listings, command outputs, or other raw data

**Quality bar:** Before writing a wiki page, ask: "Would a human reading this in Obsidian three months from now find it useful for understanding what was explored, decided, or learned?" If no, don't write it.

**Anti-bloat rules:**
- No "In this session we..." framing
- No timestamps in prose (frontmatter only)
- No attribution to "Claude" or "the AI" — write as if a knowledgeable colleague documented it
- No hedging ("it might be worth considering...") — be direct
- No listing things that are obvious from the code itself
- Maximum 2 paragraphs per section unless the content genuinely requires more
- Prefer structured lists over prose when listing facts, tradeoffs, or options

---

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

---

## For /wiki log

Append a devlog entry to the current project's `wiki/projects/<slug>/devlog.md`.

### Step 1 — Determine project

Get project slug from `basename $(git rev-parse --show-toplevel 2>/dev/null || echo $PWD)` converted to kebab-case.

### Step 2 — Ensure project directory exists

If `wiki/projects/<slug>/` doesn't exist, create it with subdirectories (decisions/, plans/, spikes/, concepts/) and add an `overview.md` stub. Add the project to `wiki/index.md` under `## Projects`.

### Step 3 — Write devlog entry

Read existing `devlog.md` (or create if first entry). Prepend a new H2 entry:

```markdown
## [YYYY-MM-DD] <Brief title of what was done>

<2-4 bullet points of key outcomes, decisions made, or things learned. Link to any decision/plan/spike pages created this session.>
```

### Step 4 — Update wiki/index.md

Ensure the project has an entry under `## Projects`. Add it if missing. Add the new devlog entry as a line item only if it represents a notable milestone; routine devlog writes do not need an index line.

---

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

---

## For /wiki decide <title>

Create an architecture decision record.

Write to `wiki/projects/<slug>/decisions/<title-kebab>.md`:

```markdown
---
type: decision
status: accepted
created: YYYY-MM-DD
updated: YYYY-MM-DD
tags:
  - decision
  - <project-slug>
project: <project-slug>
---

# <Title>

## Context

<What situation prompted this decision>

## Decision

<What was decided, stated directly>

## Consequences

<What follows from this decision — tradeoffs accepted, constraints introduced>

## Alternatives Considered

- **<Alternative A>** — <why not chosen>
- **<Alternative B>** — <why not chosen>
```

Fill from session context. Update devlog and wiki/index.md.

---

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

Fill from session context. Update devlog and wiki/index.md.

---

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

---

## For /wiki ingest <source>

Ingest an external source (URL, PDF, file) into the wiki.

### Step 1 — Resolve vault, read index and log

### Step 2 — Fetch source

| Input | Method |
|-------|--------|
| URL (web page) | `mcp__web-strip__fetch` |
| URL (PDF) | `mcp__markitdown__convert_to_markdown` |
| Local PDF/DOCX/XLSX | `mcp__markitdown__convert_to_markdown` |
| Local markdown/text | Read tool |
| `--text "..."` | Use as-is |

### Step 3 — Save to raw/

Save as `raw/YYYY-MM-DD_<slug>.<ext>` with frontmatter (source_url, captured_at, source_type, author, title). Never modify after creation.

### Step 4 — Analyze and plan updates

Identify: title, author, entities, concepts, key claims. Cross-reference against index. Present plan to user (unless `--batch`).

### Step 5 — Create source summary page

Write to `wiki/sources/<slug>.md` with Summary, Key Claims, Entities, Concepts sections.

### Step 6 — Create/update entity and concept pages

For each entity or concept identified: create new pages or update existing ones following the templates above.

### Step 7 — Update index.md

### Step 8 — Report results

---

## For /wiki query "<question>"

### Step 1 — Read index.md to find relevant pages

### Step 2 — Read the most relevant pages (up to 5)

### Step 3 — Synthesize answer with `[[wikilink]]` citations

If `--file` flag given, also save the answer as `wiki/synthesis/<question-slug>.md` and update index.

### Step 4 — Suggest follow-ups

If the query reveals gaps, suggest: sources to ingest, pages to create, or questions to investigate.

---

## For /wiki lint

Health-check the wiki and report issues.

### Checks

1. **Orphan pages**: no incoming links besides index
2. **Stubs**: source_count < 2
3. **Broken wikilinks**: links to non-existent pages
4. **Missing cross-references**: entities/concepts mentioned in prose but not wikilinked
5. **Stale pages**: not updated in 90+ days
6. **Index consistency**: pages on disk not listed in index.md
7. **Empty projects**: project directories with no content beyond overview stub
8. **Bloat detection**: pages with excessive AI-style prose (hedging, narration, attribution)

### Output format

```
Wiki Health: NN/100

## Issues Found
- <category>: <count> (<list or examples>)

## Suggested Actions
- <actionable fix>
```

If `--fix` given: auto-fix safe issues (index updates, missing wikilinks). Ask for confirmation on destructive fixes.

---

## For /wiki status

Quick read-only summary:

```
Wiki: <vault_name>
Path: <vault-path>

  Projects:   N (<list>)
  Concepts:   N
  Sources:    N
  Syntheses:  N
  Decisions:  N (across all projects)
  Plans:      N
  Spikes:     N

  Stubs: N pages need coverage
  Last activity: YYYY-MM-DD (<description>)
```

---

## Second-Brain Integration

The wiki can READ from second-brain (via MCP `recall` and `context` tools) to inform page content — pulling in prior decisions, context from past sessions, or knowledge accumulated over time. This helps write richer pages without requiring the user to re-explain history.

The wiki NEVER writes to second-brain. They are separate systems:
- Second-brain = machine memory (vector search, graph DB, for LLM recall)
- Wiki = human-readable knowledge (markdown in Obsidian, for humans to browse)

When writing a wiki page, you may `recall` from second-brain to fill in context you don't have in the current conversation, but always verify recalled information against the codebase before committing it to a wiki page.

---

## Multi-Session Continuity

- Always read `wiki/index.md` before any operation. Read only the current project's section plus the all-projects header list; do not load the full file unless doing a cross-project query.
- Read `WIKI_SCHEMA.md` at the start of first wiki operation per session.
- The session-start hook injects the 3 most recent devlog entries automatically. If you need earlier context, grep `wiki/projects/<slug>/devlog.md` for the relevant date range, then Read only that section.
- Wiki files on disk are the source of truth, not conversation memory.

---

## Honesty Rules

- Never invent claims not supported by sources or session context
- Cite what informed each fact
- Note contradictions explicitly with both claims
- Prefer stubs over fabricated content
- Do not hallucinate connections between concepts
