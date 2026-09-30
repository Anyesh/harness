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
