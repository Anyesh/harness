---
allowed-tools: Bash(~/.claude/scripts/cmd-context.sh *)
argument-hint: [optional focus for the entry]
---

# Devlog

Append a dated entry to this project's devlog in the Obsidian wiki at `<wiki_vault>/wiki/projects/<repo_slug>/devlog.md`, using the values below.

## Context

!`~/.claude/scripts/cmd-context.sh devlog`

Use `repo_slug`, `wiki_vault` and `today` exactly as printed.

## What to write

A single entry, newest at top, in this format:

```
## YYYY-MM-DD Brief title

- Key outcome or decision
- Context that wouldn't be obvious from git history
- Link to [[decision]] or [[plan]] page if one exists
```

## Rules

- Use `today` from the context above as the date (absolute YYYY-MM-DD).
- 2-4 bullets, not a session transcript.
- Skip anything obvious from the code or commits; write only what would help a future reader.
- No "In this session we..." framing. No attribution. No hedging.

If `devlog` above is `absent`, create it with frontmatter (`type: devlog`, `project: <repo_slug>`) and an H1 heading.
