## For /wiki log

Append a devlog entry to the current project's `wiki/projects/<slug>/devlog.md`, in the vault named on the session's `WIKI:` line.

### Step 1: Determine project

The slug is on the session's `WIKI:` line. Without one, take the kebab-case basename of the main checkout: `git rev-parse --path-format=absolute --git-common-dir` without its trailing `/.git`, or `$PWD` outside git. A worktree logs to its main checkout's project.

### Step 2: Ensure project directory exists

If `wiki/projects/<slug>/` doesn't exist, create it with subdirectories (decisions/, plans/, spikes/, concepts/), an `overview.md` stub, and an `index.md` with frontmatter (`type: project-index`, `project: <slug>`, `title: <project title>`) listing `- [Devlog](devlog.md): chronological project log` and `- [Overview](overview.md): what the project is`.

### Step 3: Write devlog entry

Read existing `devlog.md` (or create if first entry). Prepend a new H2 entry:

```markdown
## [YYYY-MM-DD] <Brief title of what was done>

<2-4 bullet points of key outcomes, decisions made, or things learned. Link to any decision/plan/spike pages created this session.>
```

### Step 4: Folder index

A devlog entry needs no index line: the project's `index.md` lists `devlog.md` once, and that line stays as it is. Never edit `wiki/index.md`, which the harness generates from the folder indexes.
