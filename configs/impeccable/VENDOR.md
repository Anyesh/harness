# Vendored: impeccable

Source fork: https://github.com/Anyesh/impeccable (self-maintained fork of pbakaus/impeccable)
Pinned commit: b913668ba4d25b95c4a62278d3637837e9d2c6d9

## Why vendored (not installed via marketplace/npx)
Impeccable is architected for project-local install: every build hardcodes project-relative
script paths (`node .claude/skills/impeccable/scripts/...`). The harness installs skills
globally (`~/.claude`, `~/.cursor`, `~/.agents`), where those paths resolve against the
project CWD and fail. `deploy_impeccable_skill` (install.sh) rewrites them to absolute
`$HOME/...` paths at deploy time so the scripts resolve regardless of CWD.

## Layout (deduped)
- `scripts/` and `reference/` are byte-identical across the upstream .claude/.cursor/.agents
  builds (reference differs only by the path prefix, rewritten at deploy), so each is vendored once.
- `SKILL.<variant>.md` is per-target: the Claude build carries `user-invocable`/`argument-hint`/
  `allowed-tools` frontmatter that the other harnesses ignore.
- `agents/` is the Codex-only sidecar (asset-producer + openai.yaml), auto-discovered by Codex.

## Resyncing the fork
1. Sync the fork from upstream on GitHub, then `git clone --depth 1` it.
2. Copy `<build>/scripts`, `<build>/reference`, each build's `SKILL.md` to `SKILL.<variant>.md`,
   and `.agents/.../agents` here.
3. Update the pinned commit above.
