# Crew memory store

Read at Start, at close-out and whenever a sweep prints a `MEMORY` line. The store keeps what outlives a run: each repo's brief, lead notes and gate scripts, a short history per run, and rules meant for every crew.

## Where it lives

- One git repo at `$CREW_MEMORY_DIR` (default `~/.local/share/crew-memory`), cloned from `CREW_MEMORY_REMOTE` in `~/.config/harness/crew-memory.env`. It is private; never copy its contents into a project repo, a PR or the harness repo except through `references/promote.md`.
- `mem=$(crew_mem)` (from `crew-lib.sh`) is `repos/<key>/` once the repo has an entry, else `$crew`, so a repo that was never moved keeps working. The key comes from the repo's origin URL, so every clone on every machine finds the same entry.
- The store is yours to commit and push: `crew-memory sync`, the sweep and `crew-archive` do it without asking. Project repos never receive crew commits.

## Layout and caps

```
rules/proposed.md        cross-repo rules awaiting promotion, "- <rule> (<date>, <key>)", cap 8 KB
rules/decided.md         one line per promoted (harness sha) or rejected (reason) rule
repos/<key>/
  origin                 normalized origin URL, or none
  brief.md               worker brief; ## Lessons capped at CREW_LESSONS_MAX_BYTES (8 KB)
  lead-notes.md          lead rules, dated, under topic headings, no cap
  check preflight preflight.d/ sweep-check thresholds watch-paths heavy-slots light-slots wait-patterns
  <helper scripts the gate scripts call, reached as $CREW_MEM/<helper>>
  index.md               one line per run
  archive/               imported originals, out of the read path
  runs/<run-id>/         summary.md, rulings.md, reflections.md, plan.md, board.tsv, items/<id>/*.md
```

Run state stays in `$crew`: `board.tsv`, `items/`, `rulings.md`, `reflections.md`, `plan.md`, `handover.md`, `.sweep-*`, queues and locks, `lead`, and the bulk of finished runs in `done-<run-id>/`.

Lead notes have no size cap, since one session reads them and a big repo needs many rules. Keep them under `## <topic>` headings (gates, workers, host, a product area) and keep them current: a reflection round deletes the rules a landed mechanism or a later change made stale and moves general ones to `rules/proposed.md`. The worker Lessons stay capped because every worker reads the whole brief at spawn.

## Commands

- `crew-memory ensure`: creates the store and moves this repo's persistent files into `repos/<key>/` in one step. It moves nothing while an `assigned` row, a live merge or a live sweep could be reading them, and prints `MEMORY pending <reason>`; run it again at the next fresh start.
- `crew-memory sync [msg]`: commits, rebases onto the remote and pushes. The sweep runs it every `CREW_MEMORY_SYNC_EVERY` seconds (600).
- `crew-memory status`: reports without changing anything.
- `crew-lesson add [--lead|--all] "<rule>"`: worker lessons, lead rules, cross-repo rules.
- `crew-archive [--import <done-dir>]`: moves a finished run into `$crew/done-<run-id>/` and copies its durable text into `runs/<run-id>/`.

## MEMORY lines

- `MEMORY ok <sha>`: pushed.
- `MEMORY pending <reason>`: the repo is not in the store yet; nothing to do mid-run.
- `MEMORY stray <file>`: a persistent file sits in `$crew` although the store has the entry. Merge its content into `$mem/<name>` (the store copy is the one read) and delete the stray.
- `MEMORY over <file> <bytes>/<cap>`: merge or retire lines until it fits; never raise the cap.
- `MEMORY conflict <files>`: another machine changed the same file. Resolve it in the store by hand (`git -C $CREW_MEMORY_DIR pull --rebase`, fix, continue) and sync again.
- `MEMORY push-failed <reason>` and `MEMORY unpushed <n>`: the commits are safe locally; tell the user if it persists past close-out.
- `MEMORY no-remote`: the env file names no remote; tell the user once.

## Gate scripts

- crew-merge snapshots every executable in `$mem` under the store's `.sync.lock` once per run and runs the copies with `CREW_MEM` pointing at the snapshot, so a sync or an edit never changes a gate mid-run. A gate script reaches a helper beside it as `$CREW_MEM/<helper>`; run state stays at `$crew` paths.
- Change `check`, `preflight` or `sweep-check` by writing `$mem/.tmp-<name>`, `chmod +x`, then `mv` over the old one; the store ignores `.tmp*` files, so a half-written script is never committed.
- `preflight.d/` holds drop-in checks crew-merge runs after `preflight` on every item, sorted. A repo with database migrations gets a migration-head test as its first entry, since two items that each add a migration on one head pass alone and break together. `crew-lint-waits` (literal sleeps and timeouts in added test lines) is enabled by linking it in: `ln -s "$(command -v crew-lint-waits)" "$mem/preflight.d/20-lint-waits"`.
