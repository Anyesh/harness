# harness

- Edit the sources under `configs/`, never the deployed copies in `~/.claude`, `~/.cursor`, `~/.codex` or `~/.config/opencode`; `./install.sh` assembles and deploys them.
- Global rules live in `configs/shared/rules/*.mdc` and reach every agent. Hook-specific detail (the comment guard's WHY markers and directive allowlist, the Stop hook's full phrase list) goes in `configs/shared/rules-unhooked/hook-fallback.mdc`, which only the Codex and opencode templates include; the rules those hooks enforce stay in the shared rules so every agent sees them.
- `configs/shared/skills/humanize` and `configs/shared/skills/ownit` are injected into every session by hooks, so they count as global rules: check them against `configs/shared/rules/` whenever either changes.
- `bash tests/run_tests.sh` runs the suite; `bash tests/test_<name>.sh` runs one file.
- `./install.sh --dry-run` previews an install, and `--only <module>` limits it to one module.
- Before shipping a guard change, run `scripts/guard-replay.sh` to replay it over recent real transcripts and read every sample block.
- After changing the global rules, run `scripts/rules-eval.sh OLD.md NEW.md` to compare agent behavior under each rendered file; every run is a real model call.
- Shared install code that is not a module belongs in `lib/`, because `tests/test_modules.sh` treats every `modules/*.sh` as an installer module.
