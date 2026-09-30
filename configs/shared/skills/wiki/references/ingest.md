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
