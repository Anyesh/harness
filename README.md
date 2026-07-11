# harness

Single-command bootstrap for AI coding tools. One repo, one install, full environment reproducible on any linux machine in under 30 seconds.

![harness install demo](demo.gif)


## Numbers

| Metric | Count |
|--------|-------|
| Config templates | 80 |
| Managed files deployed | 52 |
| Hooks (Claude Code) | 23 |
| Hooks (Cursor events) | 11 |
| Skills (shared) | 19 |
| Plugins (Claude Code) | 15 |
| MCP servers | 5 |
| Modules | 8 |
| Template variables | 5 |
| No-op redeploy | <2s |

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/anyesh/harness/main/install.sh | bash
```

First run clones the repo to `~/.harness`, detects installed tools, and deploys everything. Subsequent runs are idempotent (checksum-based skip).

## What gets deployed

### Claude Code

```
~/.claude/settings.json        ← permissions, hooks config, enabledMcpjsonServers
~/.claude/.mcp.json            ← MCP server definitions (cognitive-cache, web-strip, markitdown, second-brain)
~/.claude/CLAUDE.md            ← global instructions (exploration-first, TDD, scope gates, no AI comments)
~/.claude/hooks/               ← 23 hook scripts (see below)
~/.claude/skills/              ← 19 skill definitions
~/.claude/plugins/             ← 15 plugins from 2 marketplaces
```

### Cursor

```
~/.cursor/rules/*.mdc          ← 15 shared rules (alwaysApply)
~/.cursor/mcp.json             ← MCP servers (merged with existing; harness adds second-brain, cognitive-cache, web-strip, markitdown)
~/.cursor/hooks.json           ← 11 hook events (session, prompt, tool, shell, edit, stop, compact)
~/.cursor/hooks/               ← shared hook scripts (same family as Claude Code)
~/.cursor/skills/              ← shared skills (converge, humanize, ownit, wiki, terminal-gif)
~/.cursor/commands/            ← shared slash commands (plan, scope, commit, decision, devlog)
```

### Codex

```
~/.codex/config.toml           ← model, approval mode
~/.codex/instructions.md       ← shared instructions
```

## Hooks

| Hook | Trigger | Purpose |
|------|---------|---------|
| `pre-edit-comment-guard.py` | PreToolUse (Write/Edit) | Blocks AI-generated narration comments |
| `pre-edit-code-quality.sh` | PreToolUse (Write/Edit) | Rejects shortcut-seeking language |
| `stop-sloppiness-guard.sh` | PostResponse | Detects lazy patterns, injects correction |
| `cost-guard.sh` | PreToolUse (Bash) | Blocks unbounded output in main context |
| `context-cold-start-guard.sh` | beforeSubmitPrompt / preCompact (Cursor) | Blocks cold re-bill on large context after model change, compaction, or cache idle |
| `pre-bash-guard.sh` | PreToolUse (Bash) | Validates commands before execution |
| `format-on-save.sh` | PostToolUse (Write/Edit) | Auto-formats written files |
| `pre-compact.sh` | PreToolUse (Compact) | Pre-compaction hook |
| `session-start.sh` | SessionStart | Activates modes, checks environment |
| `session-end-ingest.sh` | SessionEnd | Ingests session into second-brain (machine memory) |
| `session-start-wiki.sh` | SessionStart | Injects project wiki context + devlog |
| `humanize-*.js` | Various | Humanize mode activation, config |
| `ownit-*.js` | Various | Ownership mindset activation, config |

## MCP Servers

| Server | Transport | Purpose |
|--------|-----------|---------|
| `second-brain` | stdio | Personal knowledge graph (KùzuDB, BGE embeddings, 384-dim) |
| `cognitive-cache` | stdio | Optimal file selection for LLM context |
| `web-strip` | stdio | Clean markdown extraction from URLs (Readability) |
| `markitdown` | stdio | PDF/DOCX/XLSX → markdown |
| `verdant` | stdio | Cross-session tool call caching (per-project) |

## Skills

| Category | Skills |
|----------|--------|
| SEO | `seo`, `seo-audit`, `seo-page`, `seo-plan`, `seo-technical`, `seo-schema`, `seo-sitemap`, `seo-content`, `seo-images`, `seo-hreflang`, `seo-geo`, `seo-competitor-pages`, `seo-programmatic` |
| Knowledge | `wiki` (Karpathy-pattern LLM wiki) |
| Workflow | `terminal-gif`, `humanize`, `ownit` |

## Modules

```
claude        Claude Code: configs, plugins, hooks, skills, MCP
cursor        Cursor: rules, mcp.json, hooks.json, skills, commands
codex         Codex: config.toml, instructions
second-brain  second-brain daemon + MCP server registration
wiki          Obsidian wiki vault init (Karpathy pattern, per-project)
watch         File watcher for auto-ingest
leakguard     gitleaks + global pre-commit scan for personal info/secrets;
              pairs with the publish-leak-guard Claude hook that scans built
              artifacts (sdists/wheels) before uv publish/twine upload.
              Escape hatches: '#gitleaks:allow' inline, LEAKGUARD_SKIP=1.
lib           Shared functions (logging, template rendering, manifest)
```

## Wiki (Knowledge Base)

The harness deploys an LLM-maintained wiki based on Andrej Karpathy's [LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) pattern. The LLM builds and maintains structured Obsidian pages as you work; you never write the wiki yourself.

**Setup:** Set `WIKI_VAULT` in `~/.harness.env` to your Obsidian vault path. The wiki module creates the structure on install.

**How it works:**
- Every session, the LLM sees wiki context (project devlog, index) via session-start hook
- CLAUDE.md instructs the LLM to proactively write wiki pages when plans, decisions, spikes, or concepts emerge
- Pages are organized per-project: `wiki/projects/<slug>/` with devlog, decisions/, plans/, spikes/
- Pre-compact hook reminds the LLM to capture anything valuable before context compression
- `/wiki` skill provides full operations: ingest external sources, query, lint

**What gets captured:** plans, PRDs, architecture decisions (ADRs), exploration spikes, concepts, devlogs. Not captured: routine fixes, debugging transcripts, AI bloat.

**Vault structure:**
```
$WIKI_VAULT/
├── wiki/
│   ├── projects/<slug>/    ← per-project knowledge
│   ├── concepts/           ← cross-project concepts
│   ├── synthesis/          ← filed query answers
│   ├── sources/            ← external source summaries
│   ├── index.md            ← master catalog
│   └── log.md             ← activity timeline
├── raw/                    ← immutable source copies
└── WIKI_SCHEMA.md          ← conventions
```

## Template Variables

Set in `~/.harness.env`:

```bash
USER_EMAIL=you@example.com
GITHUB_USER=yourhandle
DATA_ROOT=/path/to/data
MCP_COGNITIVE_CACHE_PATH=cognitive-cache-mcp
HOME_DIR=/home/youruser
```

## Commands

```bash
./install.sh                    # Full deploy (default)
./install.sh --only claude      # Single module
./install.sh --force            # Redeploy even if unchanged
./install.sh --dry-run          # Preview without changes
./install.sh status             # Show managed file state
./install.sh uninstall          # Restore all backups
```

## Architecture

```
~/.harness.env                  ← Personal variables (not committed)
~/.harness-manifest.json        ← Deployed file checksums (auto-generated)
harness/
├── configs/
│   ├── claude-code/            ← Templates: settings, CLAUDE.md, .mcp.json, hooks, skills
│   ├── cursor/                 ← Templates: rules, mcp.json
│   └── codex/                  ← Templates: config.toml, instructions
├── modules/                    ← Deploy logic per tool (claude.sh, cursor.sh, etc.)
├── lib/                        ← Shared: template rendering, manifest, backup, detect
├── tools/                      ← Bundled tools (web-strip)
└── install.sh                  ← Entrypoint
```

## Deploy Flow

1. `install.sh` sources all libs and modules
2. Detects installed tools via PATH and config dirs
3. Reads `~/.harness.env` for template variables
4. Per module: renders templates → checksums → skips if unchanged → backs up → deploys
5. Writes `~/.harness-manifest.json` with file hashes
6. Idempotent: re-run anytime, only changed files get touched

## New Machine Setup

```bash
# 1. Install
curl -fsSL https://raw.githubusercontent.com/anyesh/harness/main/install.sh | bash

# 2. Configure
cat > ~/.harness.env << 'VARS'
USER_EMAIL=you@example.com
GITHUB_USER=yourhandle
DATA_ROOT=/path/to/data
HOME_DIR=$HOME
VARS

# 3. Deploy
~/.harness/install.sh

# 4. Verify
claude mcp list    # Should show 5 servers connected
```

## Requirements

- bash 4+
- git
- jq
- perl (template rendering)
- `claude` CLI (for plugin/MCP registration; configs deploy without it)
- Node.js (for web-strip)
- Python 3.9+ with `uv`/`uvx` (for cognitive-cache, markitdown)
