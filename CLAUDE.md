# harness

- Edit the sources under `configs/`, never the deployed copies in `~/.claude`, `~/.cursor`, `~/.codex` or `~/.config/opencode`; `./install.sh` assembles and deploys them.
- Global rules live in `configs/shared/rules/*.mdc` and reach every agent. Text a Claude or Cursor guard hook already enforces goes in `configs/shared/rules-unhooked/hook-fallback.mdc`, which only the Codex and opencode templates include.
- `bash tests/run_tests.sh` runs the suite; `bash tests/test_<name>.sh` runs one file.
- `./install.sh --dry-run` previews an install, and `--only <module>` limits it to one module.
- Before shipping a guard change, run `scripts/guard-replay.sh` to replay it over recent real transcripts and read every sample block.
- Shared install code that is not a module belongs in `lib/`, because `tests/test_modules.sh` treats every `modules/*.sh` as an installer module.
