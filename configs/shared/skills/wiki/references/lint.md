## For /wiki lint

Health-check the wiki and report issues.

### Checks

1. **Orphan pages**: no incoming links besides index
2. **Stubs**: source_count < 2
3. **Broken wikilinks**: links to non-existent pages
4. **Missing cross-references**: entities/concepts mentioned in prose but not wikilinked
5. **Stale pages**: not updated in 90+ days
6. **Index consistency**: pages on disk not listed in their folder's `index.md` (the generated `wiki/index.md` marks them "unlisted"), and folder index links that resolve to no page
7. **Empty projects**: project directories with no content beyond overview stub
8. **Bloat detection**: pages with excessive AI-style prose (hedging, narration, attribution)
9. **Work boundary**: in a work vault (path ending `Work/agent-wiki`), links that resolve outside it; in the personal vault, a `wiki/projects/<slug>/` whose slug is listed in `WIKI_WORK_PROJECTS` (comma-separated, in `~/.harness.env`)

### Output format

```
Wiki Health: NN/100

## Issues Found
- <category>: <count> (<list or examples>)

## Suggested Actions
- <actionable fix>
```

If `--fix` given: auto-fix safe issues (folder index lines, missing wikilinks). Ask for confirmation on destructive fixes.
