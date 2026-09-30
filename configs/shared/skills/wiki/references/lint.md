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
