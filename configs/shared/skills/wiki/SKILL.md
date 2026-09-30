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

Read the reference file for the requested operation before doing it. Usage, vault resolution, layout, proactive mode, second-brain, continuity and honesty rules stay in this file.

| Situation | Read |
| --- | --- |
| `/wiki init <vault-path>`: create vault structure, schema, index | references/init.md |
| `/wiki log`: write a devlog entry | references/log.md |
| `/wiki plan <title>`: write a plan or PRD page | references/plan.md |
| `/wiki decide <title>`: write a decision record | references/decide.md |
| `/wiki spike <title>`: write a spike page | references/spike.md |
| `/wiki concept <title>`: write a concept page | references/concept.md |
| `/wiki ingest <source>`: ingest a source into the vault | references/ingest.md |
| `/wiki query "<question>"`: answer from the wiki with citations | references/query.md |
| `/wiki lint`: check wiki health | references/lint.md |
| `/wiki status`: report wiki state | references/status.md |

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
