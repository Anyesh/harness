# Devlog

Append a dated entry to this project's devlog in the Obsidian wiki at `<vault>/wiki/projects/<slug>/devlog.md`. Take `<vault>` and `<slug>` from the session's `WIKI:` line; without one, `<vault>` is the vault the wiki-maintenance rule names and the slug is the kebab-case basename of the main checkout (`git rev-parse --path-format=absolute --git-common-dir` without `/.git`), never a worktree.

## What to write

A single entry, newest at top, in this format:

```
## [YYYY-MM-DD] Brief title

- Key outcome or decision
- Context that wouldn't be obvious from git history
- Link to [[decision]] or [[plan]] page if one exists
```

## Rules

- Today's date (absolute YYYY-MM-DD, not "today" or relative).
- 2-4 bullets, not a session transcript.
- Skip anything obvious from the code or commits — write only what would help a future reader.
- No "In this session we..." framing. No attribution. No hedging.

If no devlog file exists yet, create it with frontmatter (`type: devlog`, `project: <slug>`) and an H1 heading. A devlog entry needs no index line.
