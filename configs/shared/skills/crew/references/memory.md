# Crew memory

Read at Start, at close-out and whenever a sweep prints a `MEMORY` line. Crew memory keeps what outlives a run: each repo's brief, lead notes and gate scripts, a short history per run, and rules meant for every crew.

## Where it lives

- In the project's wiki folder: `<vault>/wiki/projects/<slug>/crew`. wiki-sync carries the folder to the other machines, so there is no git repo, nothing to commit and nothing to push. A work machine's crew memory stays in the work vault, because the vault comes from the wiki hooks' own rule.
- `mem=$(crew_mem)` (from `crew-lib.sh`) is that folder once it exists, else `$crew`, so a repo that was never moved keeps working.
- Cross-repo rules wait in the harness wiki folder, `<vault>/wiki/projects/harness/crew` (`crew_proposals_dir`), in `proposed.md` and `decided.md`.
- Project repos never receive crew files. Never copy crew memory into a project repo, a PR or the harness repo except through `references/promote.md`.

## Layout and caps

```
<vault>/wiki/projects/harness/crew/
  proposed.md            cross-repo rules awaiting promotion, "- <rule> (<date>, <key>)", no cap
  decided.md             one line per promoted (harness sha) or rejected (reason) rule
<vault>/wiki/projects/<slug>/crew/
  brief.md               worker brief; ## Lessons capped at CREW_LESSONS_MAX_BYTES (8 KB)
  lead-notes.md          lead rules, dated, under topic headings, no cap
  check preflight preflight.d/ sweep-check thresholds watch-paths heavy-slots light-slots wait-patterns
  <helper scripts the gate scripts call, reached as $CREW_MEM/<helper>>
  index.md               one line per run
  archive/               imported originals, out of the read path
  runs/<run-id>/         summary.md, rulings.md, reflections.md, plan.md, board.tsv
```

Run state stays in `$crew`: `board.tsv`, `items/`, `rulings.md`, `reflections.md`, `plan.md`, `handover.md`, `.sweep-*`, queues and locks, `lead`, and finished runs in `done-<run-id>/`, where each item's spec and report stay.

Lead notes and proposals have no size cap, since one session reads them and a big repo needs many rules. Keep lead notes under `## <topic>` headings (gates, workers, host, a product area), read them by heading, and keep them current: a reflection round deletes the rules a landed mechanism or a later change made stale and moves general ones to `proposed.md`. The worker Lessons keep the 8 KB cap because every worker reads the whole brief at spawn.

## Commands

- `crew-memory ensure`: moves this repo's persistent files into the wiki crew folder in one step. It moves nothing while an `assigned` row, a live merge or a live sweep could be reading them, and prints `MEMORY pending <reason>`; run it again at the next fresh start.
- `crew-memory status`: reports without changing anything.
- `crew-lesson add [--lead|--all] "<rule>"`: worker lessons, lead rules, cross-repo rules.
- `crew-archive [--import <done-dir>]`: moves a finished run into `$crew/done-<run-id>/`, copies its summary.md, rulings.md, reflections.md, plan.md and board.tsv into `crew/runs/<run-id>/` and indexes them in `crew/index.md`.

## MEMORY lines

- `MEMORY no-vault`: no wiki vault was found; tell the user once.
- `MEMORY pending <reason>`: the repo has no crew folder yet; nothing to do mid-run.
- `MEMORY stray <file>`: a persistent file sits in `$crew` although the wiki crew folder has the entry. Merge its content into `$mem/<name>` (the wiki copy is the one read) and delete the stray.
- `MEMORY over crew/brief.md#Lessons <n>/<cap>`: merge or retire lessons until it fits; never raise the cap.

SessionStart prints `CREW-MEMORY: <crew dir>, <n> runs` and `CREW-PROPOSALS: <n> pending`.

## Gate scripts

- crew-merge snapshots every executable in `$mem` under `$crew/.mem.lock` once per run and runs the copies with `CREW_MEM` pointing at the snapshot, so a wiki-sync or an edit never changes a gate mid-run. A gate script reaches a helper beside it as `$CREW_MEM/<helper>`; run state stays at `$crew` paths.
- wiki-sync skips dot paths and carries no file modes. Change `check`, `preflight` or `sweep-check` by writing `$mem/.tmp-<name>`, `chmod +x`, then `mv` over the old one, so a half-written script is never synced. The crew scripts restore executable bits from shebangs (`crew_mem_fix_modes`) on a script that arrives from another machine.
- `preflight.d/` holds drop-in checks crew-merge runs after `preflight` on every item, sorted. A repo with database migrations gets a migration-head test as its first entry, since two items that each add a migration on one head pass alone and break together. `crew-lint-waits` (literal sleeps and timeouts in added test lines) is enabled by linking it in: `ln -s "$(command -v crew-lint-waits)" "$mem/preflight.d/20-lint-waits"`.
