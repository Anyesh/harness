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

Turn any collection of sources into a persistent, compounding knowledge base maintained entirely by the LLM. Based on Andrej Karpathy's LLM Wiki pattern: instead of re-deriving knowledge from raw documents on every query (like RAG), the LLM incrementally builds and maintains structured wiki pages where cross-references already exist, contradictions are already flagged, and synthesis already reflects everything you've read. The wiki keeps getting richer with every source you add and every question you ask.

You never write the wiki yourself. The LLM writes and maintains all of it. You curate sources, direct the analysis, and ask the right questions. Open Obsidian on one side and Claude on the other — Claude makes edits, you browse the results in real time via the graph view.

## Usage

```
/wiki init <vault-path>                    # create vault structure + schema
/wiki ingest <url>                         # fetch URL, save to raw/, update wiki pages
/wiki ingest <file-path>                   # ingest local file (PDF, DOCX, markdown, text)
/wiki ingest --batch <dir>                 # ingest all files in directory (autonomous mode)
/wiki ingest --text "..."                  # ingest inline text directly
/wiki query "<question>"                   # search wiki, synthesize answer with citations
/wiki query "<question>" --file            # same, but also save answer as synthesis page
/wiki lint                                 # structural health check (orphans, stubs, contradictions)
/wiki lint --fix                           # lint and auto-fix actionable issues
/wiki sync                                 # sync wiki from post-commit graph changes
/wiki status                               # quick summary of wiki state
```

## What You Must Do When Invoked

Parse the subcommand from the user's input and dispatch to the appropriate section below. If no subcommand is given, show the usage block above and ask what they'd like to do.

Before any operation, resolve the vault path using the resolution order defined in the Vault Path Resolution section. If no vault can be found and the subcommand is not `init`, stop with: "No wiki vault found. Run `/wiki init <vault-path>` first."

---

## Vault Path Resolution

Find the vault in this order (first match wins):

1. **Explicit path** in the command: `/wiki ingest <source> --vault <path>`
2. **`.wiki-vault` file** in the current working directory (contains one line: the absolute vault path)
3. **`WIKI_VAULT_PATH` environment variable**
4. **Error**: No vault found

Once resolved, verify the path contains `WIKI_SCHEMA.md`. If not, stop with an error.

---

## For /wiki init

### Step 1 — Validate path

Check if `<vault-path>` exists as a directory. If it doesn't exist, create it. If it already contains `WIKI_SCHEMA.md`, warn: "This directory already has a wiki. Re-initializing will overwrite the schema but preserve all existing content. Continue?" Wait for confirmation before proceeding.

### Step 2 — Create directory structure

```bash
mkdir -p "<vault-path>/raw/assets"
mkdir -p "<vault-path>/wiki/entities"
mkdir -p "<vault-path>/wiki/concepts"
mkdir -p "<vault-path>/wiki/sources"
mkdir -p "<vault-path>/wiki/synthesis"
mkdir -p "<vault-path>/graphify-out"
```

### Step 3 — Write WIKI_SCHEMA.md

Write the following to `<vault-path>/WIKI_SCHEMA.md`, substituting the vault name from the directory basename and the current date:

```markdown
---
vault_name: "<basename of vault-path>"
created: "YYYY-MM-DD"
version: 1
---

# Wiki Schema

This file defines how the wiki is structured. The LLM reads it at the start of every operation. You and the LLM co-evolve this over time as you figure out what works for your domain.

## Page Types

### Entity
People, organizations, tools, libraries, projects, or other named things.
- Directory: `wiki/entities/`
- Filename: kebab-case of entity name (e.g., `andrej-karpathy.md`)
- Required frontmatter: type, created, updated, aliases, tags, source_count
- Required sections: Overview, Key Facts, Sources, Backlinks

### Concept
Ideas, methods, patterns, principles, techniques, or other abstract knowledge.
- Directory: `wiki/concepts/`
- Filename: kebab-case of concept name
- Required frontmatter: type, created, updated, tags, source_count
- Required sections: Definition, Explanation, Related Concepts, Sources, Backlinks

### Source Summary
One per ingested source. Summarizes what was ingested and what it contributed to the wiki.
- Directory: `wiki/sources/`
- Filename: kebab-case of source title or URL slug
- Required frontmatter: type, created, source_url, source_type, author, tags
- Required sections: Summary, Key Claims, Entities Mentioned, Concepts Discussed, Raw Source

### Synthesis
Cross-cutting analyses or filed query answers. These are answers that were valuable enough to persist.
- Directory: `wiki/synthesis/`
- Filename: kebab-case of synthesis title or question
- Required frontmatter: type, created, updated, query, tags, source_count
- Required sections: Question, Answer, Evidence, Sources

## Frontmatter Conventions

All pages use YAML frontmatter compatible with Obsidian's properties panel:
- `type`: one of entity, concept, source, synthesis
- `created`: ISO 8601 date (YYYY-MM-DD)
- `updated`: ISO 8601 date, bumped on every edit
- `tags`: list of Obsidian tags (without #)
- `source_count`: number of distinct raw sources that informed this page
- `aliases`: list of alternative names (enables Obsidian alias resolution)

## Linking Rules

- Use Obsidian wikilinks: `[[Page Name]]`
- Use display aliases when the filename differs from the display text: `[[kebab-name|Display Name]]`
- Every entity or concept mentioned in prose MUST be wikilinked on first occurrence in each section
- Every page MUST have a `## Sources` section listing raw source paths that informed it
- Every page MUST have a `## Backlinks` section maintained by the LLM listing pages that link here

## Tags

Tags live in frontmatter as a YAML list (Obsidian renders them in the tag pane and search):
- Domain tags chosen per-wiki: e.g., ai, ml, engineering, business, health
- Type tags added automatically: entity, concept, source, synthesis
- Status tags reflecting page maturity:
  - `stub`: source_count < 2 (needs more coverage)
  - `review`: flagged for verification during lint
  - `mature`: source_count >= 3 (well-sourced)

## Quality Thresholds

- Pages with source_count < 2 are tagged `stub`
- Pages with source_count >= 3 are tagged `mature`
- Pages not updated in 90 days are flagged as potentially stale during lint
- Contradictions between pages are flagged during lint with both claims cited
```

### Step 4 — Write index.md

Write the following to `<vault-path>/wiki/index.md`:

```markdown
---
type: index
created: YYYY-MM-DD
updated: YYYY-MM-DD
total_sources: 0
total_entities: 0
total_concepts: 0
total_syntheses: 0
---

# Wiki Index

> Start here. This catalog is the LLM's primary retrieval mechanism — it reads this file to find relevant pages before answering any question.

## Sources (chronological, newest first)

_No sources ingested yet. Run `/wiki ingest <source>` to add content._

## Entities (alphabetical)

_No entities yet._

## Concepts (alphabetical)

_No concepts yet._

## Syntheses

_No syntheses yet._

## Recent Activity

See [[log]] for full timeline.
```

### Step 5 — Write log.md

Write the following to `<vault-path>/wiki/log.md`:

```markdown
---
type: log
created: YYYY-MM-DD
---

# Activity Log

Chronological record of wiki operations. Each entry uses a parseable prefix for unix tool compatibility:
`grep "^## \[" log.md | tail -5` gives you the last 5 entries.
```

### Step 6 — Write .wiki-vault breadcrumb

Write the absolute path of `<vault-path>` to `.wiki-vault` in the current working directory. This is a single line, no trailing newline, so that subsequent `/wiki` invocations in this directory can find the vault automatically.

### Step 7 — Write .obsidian/app.json

```bash
mkdir -p "<vault-path>/.obsidian"
```

Write to `<vault-path>/.obsidian/app.json`:
```json
{
  "useMarkdownLinks": false,
  "newLinkFormat": "shortest",
  "attachmentFolderPath": "raw/assets"
}
```

### Step 8 — Check for existing content

If the vault path contains `.md` files outside of `wiki/` and `raw/` (excluding WIKI_SCHEMA.md), report how many existing markdown files were found and ask whether to ingest them as sources. If yes, copy them to raw/ and queue for batch ingest. If no, proceed.

### Step 9 — Report

```
Wiki initialized at <vault-path>

  WIKI_SCHEMA.md     — conventions and structure (edit to customize)
  wiki/index.md      — content catalog
  wiki/log.md        — activity timeline

Open <vault-path> as a vault in Obsidian, then:
  /wiki ingest <url-or-file>     — add your first source
```

---

## For /wiki ingest

### Step 1 — Resolve vault and read state

Resolve vault path per the Vault Path Resolution section, then read these files to understand current state:

- `WIKI_SCHEMA.md` (conventions — read once per session, skip if already read this session)
- `wiki/index.md` (current catalog — always read, since this is how you know what exists)
- `wiki/log.md` (read last 20 lines only, for continuity context)

### Step 2 — Detect source type and fetch

| Source Input | Detection | Fetch Method |
|-------------|-----------|-------------|
| URL (web page) | starts with `http://` or `https://` | `mcp__web-strip__fetch` with the URL |
| URL (PDF) | URL ends in `.pdf` | `mcp__markitdown__convert_to_markdown` with the URL |
| Local PDF/DOCX/XLSX/PPTX | file path with document extension | `mcp__markitdown__convert_to_markdown` with file path |
| Local markdown/text | file path with `.md` or `.txt` extension | Read tool directly |
| `--text "..."` flag | inline text after flag | Use the text as-is |
| `--batch <dir>` | directory path | Enumerate all supported files, process each |

If fetch fails (404, timeout, unsupported format), report the error and stop without creating partial wiki entries for failed fetches.

### Step 3 — Save immutable copy to raw/

Determine a filename using the pattern `YYYY-MM-DD_<slug>.<ext>` where the slug comes from the source title (if available), the URL (if a URL source), or the original filename. Save to `<vault-path>/raw/`.

Write YAML frontmatter at the top of the raw file:

```yaml
---
source_url: "<original URL or file path>"
captured_at: "YYYY-MM-DDTHH:MM:SSZ"
source_type: "url|pdf|docx|text|clipboard"
author: "<if known from the source content>"
title: "<extracted or inferred title>"
---
```

The raw file is NEVER modified after creation — it is the immutable record of what was ingested.

### Step 4 — Analyze content and plan page updates

Read the fetched content carefully and identify:

- **Title**: the source's title or a descriptive name
- **Author**: if stated or inferable from the content
- **Entities mentioned**: proper nouns — people, organizations, tools, projects, libraries, specific systems
- **Concepts discussed**: ideas, methods, patterns, principles, techniques — abstract knowledge worth its own page
- **Key claims**: factual assertions, findings, opinions, or conclusions that should be captured

Then cross-reference against `wiki/index.md` to determine which pages already exist and which need to be created.

**Present the plan to the user:**

```
Source: "<title>" (<source type>)
Saved:  raw/YYYY-MM-DD_<slug>.md

Plan:
  CREATE  wiki/sources/<slug>.md              (source summary)
  CREATE  wiki/entities/<entity-1>.md         (new entity)
  CREATE  wiki/concepts/<concept-1>.md        (new concept)
  UPDATE  wiki/entities/<existing-entity>.md  (add source, update facts)
  UPDATE  wiki/concepts/<existing-concept>.md (add source, expand explanation)
  UPDATE  wiki/index.md                       (catalog update)
  APPEND  wiki/log.md                         (activity entry)

N pages will be touched. Proceed?
```

Wait for confirmation, since the user may want to redirect emphasis ("Skip entity X" or "Also create a page for Y"). Adjust the plan accordingly before executing.

**Exception**: In `--batch` mode, skip confirmation and execute autonomously for each source, showing a progress line per source instead.

### Step 5 — Create source summary page

Write `wiki/sources/<slug>.md` following this structure:

```markdown
---
type: source
created: YYYY-MM-DD
source_url: "<url or path>"
source_type: url|pdf|docx|text|clipboard
author: "<author>"
tags:
  - source
  - <domain tags inferred from content>
---

# <Source Title>

## Summary

<2-3 paragraph summary capturing the main points, written in flowing prose with [[wikilinks]] to entities and concepts mentioned>

## Key Claims

- <Claim 1, with [[wikilinks]] to relevant entities/concepts>
- <Claim 2>
- <Claim 3>

## Entities Mentioned

- [[Entity Name]] — <role or context in this source>

## Concepts Discussed

- [[Concept Name]] — <how the source discusses this concept>

## Raw Source

`raw/YYYY-MM-DD_<slug>.md`
```

### Step 6 — Create or update entity pages

For each entity in the plan:

**If creating a new entity page**, write `wiki/entities/<kebab-name>.md`:

```markdown
---
type: entity
created: YYYY-MM-DD
updated: YYYY-MM-DD
aliases:
  - <alternative names if any>
tags:
  - entity
  - <domain tags>
  - stub
source_count: 1
---

# <Entity Name>

## Overview

<1-2 paragraph description based on what this source tells us>

## Key Facts

- <Fact from this source, with [[wikilinks]]>

## Sources

- `raw/YYYY-MM-DD_<slug>.md` — <what this source says about the entity>

## Backlinks

- [[<Source Summary Page>]]
```

**If updating an existing entity page**, read the current page first, then apply these changes: bump `updated` to today's date, increment `source_count`, add new facts to `## Key Facts` without duplicating existing ones (but noting if a new source reinforces or contradicts an existing fact), add the raw source path to `## Sources` with a note about what it contributes, add backlinks from the new source summary page, and if `source_count` reaches 3, replace the `stub` tag with `mature`.

### Step 7 — Create or update concept pages

Same pattern as entities. **If creating a new concept page**, write `wiki/concepts/<kebab-name>.md`:

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

<1-2 sentence crisp definition>

## Explanation

<Detailed explanation from this source, written in flowing prose with [[wikilinks]] to related entities and concepts>

## Related Concepts

- [[Related Concept]] — <nature of the relationship>

## Sources

- `raw/YYYY-MM-DD_<slug>.md` — <what this source says about the concept>

## Backlinks

- [[<Source Summary Page>]]
```

**If updating an existing concept page**, read it first and then: bump `updated` and increment `source_count`, enrich the `## Explanation` section by weaving in new information from this source (rather than appending a separate block), add new `## Related Concepts` entries if the source reveals new connections, add the raw source to `## Sources`, update backlinks, note contradictions explicitly with both claims cited rather than silently overwriting, and update the status tag if the threshold for `mature` is crossed.

### Step 8 — Update index.md

Read the current `wiki/index.md` and apply these updates: add the new source to `## Sources` at the top (newest first) as `- [[<Source Title>]] (YYYY-MM-DD) — <one-line description>`, add new entities to `## Entities` in alphabetical order, add new concepts to `## Concepts` in alphabetical order, bump the frontmatter counts (`total_sources`, `total_entities`, `total_concepts`), and bump the `updated` date.

### Step 9 — Append to log.md

Append an entry to `wiki/log.md`:

```markdown

## [YYYY-MM-DD] ingest | <Source Title>

- Source: `raw/YYYY-MM-DD_<slug>.md`
- Created: <N> pages (<list of page names>)
- Updated: <N> pages (<list of page names>)
- Total pages touched: <N>
```

### Step 10 — Report

```
Ingested: "<Source Title>"
  Created: N source summaries, N entities, N concepts
  Updated: N entities, N concepts
  Total: N pages touched

Wiki now: X sources, Y entities, Z concepts
```

---

## For /wiki ingest --batch

When `--batch <dir>` is given, enumerate all supported files in the directory and ingest each one sequentially without per-source confirmation.

```bash
find "<dir>" -maxdepth 1 -type f \( -name "*.md" -o -name "*.txt" -o -name "*.pdf" -o -name "*.docx" -o -name "*.html" \) | sort
```

For each file, run the full ingest flow (Steps 2-10) but skip the confirmation prompt in Step 4, printing a progress line instead:

```
[1/12] Ingesting: article-title.md ... 8 pages touched
[2/12] Ingesting: research-paper.pdf ... 11 pages touched
...
```

After all files are processed, show a summary:

```
Batch ingest complete: 12 sources processed
  Created: N source summaries, N entities, N concepts
  Updated: N entities, N concepts
  Total unique pages touched: N

Wiki now: X sources, Y entities, Z concepts
```

---

## For /wiki query

### Step 1 — Resolve vault and read state

Resolve vault path, then read `WIKI_SCHEMA.md` (if not already read this session) and `wiki/index.md`.

### Step 2 — Identify relevant pages

Extract key terms from the question and scan `wiki/index.md` for matching entries by looking for those terms in page titles and descriptions. This index-based retrieval is the primary mechanism and works well up to ~100 sources.

If index scanning yields fewer than 3 matches, supplement with a broader search:

```bash
grep -rl "<key terms>" "<vault-path>/wiki/" --include="*.md" | head -20
```

If `<vault-path>/graphify-out/graph.json` exists, you may also load it and traverse for structurally related nodes, but this is optional and secondary to index-based retrieval.

### Step 3 — Read relevant pages

Read the 3-8 most relevant pages identified in Step 2, prioritizing in this order: concept pages matching question terms first (since these contain synthesized knowledge), then entity pages, then existing synthesis pages on related questions, and finally source summary pages discussing the topic.

### Step 4 — Synthesize answer

Write the answer in the conversation using information from the wiki pages, citing sources with wikilinks:

```
Based on the wiki:

<answer text, using [[wikilinks]] when referencing wiki pages>

Pages consulted:
- [[Page 1]] (type, N sources)
- [[Page 2]] (type, N sources)
```

If the wiki lacks enough information to answer confidently, say so: "The wiki doesn't have enough coverage on X. Consider ingesting sources about Y to build this area up."

### Step 5 — Optionally file as synthesis page

If the `--file` flag was given, or if the answer is substantive enough to be worth preserving, write it as a synthesis page in `wiki/synthesis/<question-slug>.md`:

```markdown
---
type: synthesis
created: YYYY-MM-DD
updated: YYYY-MM-DD
query: "<original question>"
tags:
  - synthesis
  - <domain tags>
source_count: <number of raw sources cited transitively>
---

# <Question as Title>

## Question

<Original question>

## Answer

<The synthesized answer with [[wikilinks]]>

## Evidence

- [[Page 1]] — <what it contributed to the answer>
- [[Page 2]] — <what it contributed>

## Sources (raw)

- `raw/<source1>.md`
- `raw/<source2>.md`
```

Then update `wiki/index.md` (add to Syntheses section, bump `total_syntheses`) and append to `wiki/log.md`.

If the `--file` flag was not given, ask: "This answer synthesizes multiple pages — file it as a synthesis page so it compounds in the wiki? [y/N]"

---

## For /wiki lint

### Step 1 — Resolve vault and read state

Resolve vault path, then read `WIKI_SCHEMA.md` and `wiki/index.md`.

### Step 2 — Enumerate all wiki pages

```bash
find "<vault-path>/wiki" -name "*.md" -type f | sort
```

Build a list of all pages with their types (from frontmatter or directory).

### Step 3 — Run structural checks

Perform these checks by reading pages and analyzing their content:

**Orphan pages** — pages that no other page links to beyond index.md. For each page, grep its name across all other wiki pages to count incoming wikilinks; a page is orphaned if it has zero inlinks from non-index pages.

**Broken wikilinks** — extract all `[[...]]` patterns from wiki pages and check that each target exists as a file, accounting for aliases in frontmatter.

**Stubs** — pages where `source_count` in frontmatter is less than 2, indicating they need more source coverage to be reliable.

**Stale pages** — pages where `updated` in frontmatter is more than 90 days old, which may contain outdated information that newer sources have superseded.

**Missing cross-references** — read entity and concept pages looking for mentions of other entities or concepts in the prose text that are NOT wikilinked, representing missed connections that should be added.

**Contradictions** — look for pages that discuss the same topic but make conflicting claims, which requires reading and comparing content across related pages.

**Index consistency** — verify that every page in wiki/ appears in index.md and every entry in index.md points to an existing page.

### Step 4 — Run graphify (optional)

If graphify is installed and the wiki has 20+ pages, run it on the wiki directory for deeper structural analysis that reveals community structure, god nodes, and surprising connections:

```bash
/graphify "<vault-path>/wiki" --no-viz
```

If graphify is not installed, skip this step and rely entirely on the direct checks from Step 3.

### Step 5 — Generate health report

Compute a health score (0-100) starting at 100 and subtracting: 5 per orphan page, 3 per stub page, 2 per broken wikilink, 1 per stale page, and 5 per index inconsistency, with a floor of 0.

Present the report:

```
Wiki Lint Report
================

Health: NN/100

## Orphan Pages (no incoming links besides index)
- wiki/entities/minor-entity.md — consider linking from [[Related Concept]]

## Stubs (< 2 sources)
- wiki/concepts/some-concept.md (1 source) — needs more coverage

## Broken Wikilinks
- wiki/sources/article.md links to [[Nonexistent Page]] — create it or fix the link

## Missing Cross-References
- [[Concept A]] mentions "Entity B" in prose but doesn't wikilink it

## Stale Pages (not updated in 90+ days)
- wiki/entities/old-entity.md (last updated: YYYY-MM-DD)

## Index Consistency
- wiki/concepts/new-concept.md exists but is not listed in index.md

## Suggested Actions
- Ingest more sources covering: <list of stub topics>
- Create pages for: <concepts mentioned but lacking their own page>
- Investigate: "<suggested question that crosses multiple wiki areas>"
```

### Step 6 — Offer fixes

If `--fix` was given, automatically apply safe fixes: add missing entries to index.md, add missing wikilinks for entities and concepts mentioned in prose, and update backlinks sections across all pages. For destructive or judgment-call fixes (deleting orphans, resolving contradictions), present them individually and wait for confirmation.

If `--fix` was not given, ask: "Want me to auto-fix the safe issues (index updates, missing wikilinks, backlinks)?"

Append a lint entry to log.md:

```markdown

## [YYYY-MM-DD] lint | Health: NN/100

- Orphans: N
- Stubs: N
- Broken links: N
- Stale: N
- Fixed: N issues (if --fix was applied)
```

---

## For /wiki status

Quick read-only summary that resolves the vault, reads index.md frontmatter and the tail of log.md, then displays:

```
Wiki: <vault_name>
Path: <vault-path>

  Sources:    N
  Entities:   N
  Concepts:   N
  Syntheses:  N

  Stubs: N pages need more coverage
  Last ingest: YYYY-MM-DD (<source title>)
  Last lint: YYYY-MM-DD (health: NN/100)
```

If lint has never been run, show "Last lint: never — run `/wiki lint` for a health check" instead.

---

## For /wiki sync

Triggered automatically when a SessionStart hook detects `.wiki-sync-pending` in the repo root, or manually by the user. This bridges the gap between the git post-commit hook (which rebuilds the graph deterministically) and the wiki (which needs LLM reasoning to create pages).

### Step 1 — Read the pending marker

Read `.wiki-sync-pending` from the repo root. It contains:

```yaml
---
timestamp: 2026-05-05T12:00:00Z
commit: abc1234
message: the commit message
vault: /path/to/vault
---
file1.py
file2.ts
```

Extract the vault path, commit SHA, and list of changed files. If no `.wiki-sync-pending` exists and the user ran this manually, check if `graphify-out/graph.json` has been modified more recently than the last wiki log entry — if so, proceed with a full diff. If neither condition is met, report "Wiki is up to date with the graph."

### Step 2 — Diff graph against wiki index

Read `graphify-out/graph.json` and `wiki/index.md`. Compare:

- **New entities in graph not in wiki**: nodes tagged as entity types (functions, classes, modules, services, people, organizations) that have no corresponding page in `wiki/entities/`.
- **New concepts in graph not in wiki**: nodes tagged as concept types (patterns, algorithms, protocols, abstractions) that have no corresponding page in `wiki/concepts/`.
- **Changed entities**: nodes whose edge count or community membership changed significantly (new edges > 30% of prior edge count), suggesting the entity's role evolved.

Build a sync plan listing: pages to create, pages to update, pages unaffected.

### Step 3 — Present sync plan

Show the user:

```
Wiki Sync Plan (commit abc1234)
================================

Create (N new pages):
  - wiki/entities/new-module.md — 5 edges, community: "Auth Layer"
  - wiki/concepts/retry-pattern.md — 3 edges, community: "Resilience"

Update (M changed pages):
  - wiki/entities/api-gateway.md — 4 new edges (was 6, now 10)

Unchanged: K pages

Proceed? [Y/n]
```

If invoked automatically via the SessionStart hook context, proceed without asking (the hook already informed the user).

### Step 4 — Create and update pages

For each new page:
- Read the node's edges and community from `graph.json`
- Read the source files referenced by the node's edges (up to 3 most connected)
- Write a wiki page following the entity or concept template from `WIKI_SCHEMA.md`
- Set `source_count: 1` and tag as `stub` (because graph extraction is a single source — the codebase)
- Add a `graph-synced` tag to frontmatter so lint can distinguish graph-derived pages from manually ingested ones

For each updated page:
- Read the existing page
- Read the new edges from `graph.json`
- Append new relationships and update the description to reflect the entity's evolved role
- Bump `updated` date and increment `source_count` if new source files were consulted

### Step 5 — Update index and log

Add all new pages to `wiki/index.md` under the appropriate section (entities or concepts).

Append to `wiki/log.md`:

```markdown

## [YYYY-MM-DD] sync | commit: <sha> | +N pages, ~M updated

- New: <list of created page names>
- Updated: <list of updated page names>
- Source: post-commit hook (graphify AST)
```

### Step 6 — Clean up

Delete `.wiki-sync-pending` from the repo root. The sync is complete.

---

## Multi-Session Continuity

The wiki is the persistent artifact while conversation context is ephemeral, so follow these rules to ensure continuity across sessions:

- **Always read `wiki/index.md` before any operation** because this is how you discover what the wiki currently contains — never rely on conversation memory for wiki state.
- **Always read `WIKI_SCHEMA.md` at the start of the first wiki operation in a session** since it tells you the conventions for this specific wiki. You may cache it for the rest of the session.
- **Read the last 20 entries of `wiki/log.md`** before ingest or query operations to understand recent activity and avoid re-ingesting sources that were recently processed.
- **The wiki files are the source of truth.** If a previous conversation created pages, they exist on disk — read them rather than relying on any memory of what was done.

---

## Honesty Rules

- Never invent claims that aren't in the sources — if a source doesn't say something, don't add it to the wiki.
- Always cite which raw source informed a fact, since every claim on a wiki page must trace back to a `raw/` file.
- When sources contradict each other, note both claims with their source citations rather than silently picking one.
- Mark uncertain information explicitly: if you're not sure whether two names refer to the same entity, create separate pages and note the potential connection rather than merging them.
- Prefer creating a stub page over guessing content, because a page with `source_count: 1` and accurate content is always better than one padded with fabricated details.
- Do not hallucinate connections between concepts — if two things aren't connected in any source, don't create a "Related Concepts" link between them.

---

## Page Naming Conventions

- All filenames use kebab-case: `attention-mechanism.md`, `andrej-karpathy.md`
- If two entities share a name, disambiguate with a suffix: `python-language.md` vs `python-comedy.md`
- Source summary filenames derive from the source title or URL slug: `attention-is-all-you-need.md`
- Synthesis filenames derive from the question: `how-does-self-attention-compare-to-convolution.md`
- Keep filenames under 60 characters, abbreviating if necessary while maintaining clarity
- The wikilink display name can differ from the filename: `[[attention-mechanism|Attention Mechanism]]`

---

## When Things Go Wrong

**Duplicate pages detected**: If you discover two pages for the same entity or concept (e.g., created by different ingest sessions with slightly different names), merge them by combining content into one page, redirecting the other's backlinks, deleting the duplicate, and updating index.md.

**Source re-ingested**: If the user ingests a source that's already in `raw/` (same URL or filename), warn: "This source was already ingested on YYYY-MM-DD. Re-ingest to capture updates?" If yes, create a new raw file with today's date and update existing wiki pages with any new information from the fresh copy.

**Large wiki (100+ sources)**: When index.md exceeds 500 lines, suggest splitting into `wiki/index-sources.md`, `wiki/index-entities.md`, and `wiki/index-concepts.md`, with index.md serving as a hub linking to each sub-index and the retrieval logic updated accordingly.
