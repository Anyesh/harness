# harness

Single-command bootstrap for AI coding tools. Configures Claude Code, Cursor, and Codex with preferred skills, hooks, plugins, and settings.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/anyesh/harness/main/install.sh | bash
```

## What it does

- **Claude Code:** installs 16 plugins from 2 marketplaces, deploys 12 hook scripts (code quality, comment guard, format-on-save, sloppiness detection, caveman mode), configures settings, MCP servers, and global CLAUDE.md
- **Cursor:** deploys .cursorrules and shared skills
- **Codex:** deploys config.toml, instructions, and shared skills
- **Shared:** 15 skills (SEO suite, graphify, terminal-gif) deployed to all detected tools

## Setup

1. Run the install command above (clones repo to `~/.harness`)
2. Edit `~/.harness.env` with your personal values (email, paths)
3. Re-run: `~/.harness/install.sh`

## Commands

```
~/.harness/install.sh              # Deploy configs (default)
~/.harness/install.sh status       # Show managed file status
~/.harness/install.sh edit <file>  # Edit repo file, auto-redeploy
~/.harness/install.sh uninstall    # Restore from backup
```

## Flags

```
--force        Redeploy even if checksums match
--dry-run      Show what would change without doing it
--no-plugins   Skip Claude Code plugin installation
--no-backup    Skip backup step
--claude-only  Only configure Claude Code
--cursor-only  Only configure Cursor
--codex-only   Only configure Codex
```

## How it works

1. Detects which tools are installed (claude CLI, ~/.cursor/, ~/.codex/)
2. Reads personal values from `~/.harness.env`
3. Backs up any files it will overwrite
4. Renders templates (`{{VAR}}` syntax) and deploys configs
5. Tracks all managed files in `~/.harness-manifest.json` (checksums)
6. Re-running is always safe: skips unchanged files

## Maintenance

```
1. Edit configs in ~/.harness/configs/
2. Test: ~/.harness/install.sh --dry-run
3. Deploy: ~/.harness/install.sh
4. Commit: cd ~/.harness && git add -A && git commit
5. Push: git push
6. New machine: curl install, done
```

## Requirements

- bash 4+
- git
- jq
- perl (for template rendering)
- `claude` CLI (for plugin installation; configs still deploy without it)
