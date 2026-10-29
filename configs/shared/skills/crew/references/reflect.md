# Reflection round

Read when a sweep prints `REFLECT` and at close-out. A round turns what went wrong since the last one into rules where they are enforced, so the same mistake costs time once.

1. Read what changed since the last round: reports and their `lessons:` sections, each item's `notes.md` (where workers log non-green reviews and failed merge gates), workers you replaced, `CHECK` lines, new rulings, and how many items opened and closed.
2. For each lesson, name the class of mistake rather than the one instance, then put it where it is enforced, in the same turn:
   - A rule for workers goes into `brief.md` under `## Lessons`, one imperative line each. Send the new lines in one `[crew]` prompt, saying it is not an answer, to every live worker not flagged `DIALOG`, `MERGING`, `IDLE` or `GONE`; those catch up when they re-read the lessons before landing. A worker whose current report is an unanswered `question` gets the lines with its answer instead.
   - Anything a script can catch goes into `sweep-check` (while work runs, read-only) or `check` (at merge).
   - A rule for you goes into `lead-notes.md`.
   - A rule every crew in any repo should follow goes under `## Proposed /crew changes` in `lead-notes.md`; close-out tells the user that list.
3. Merge duplicate lines and drop ones that stopped applying, so the brief stays short.
4. Change `check` or `sweep-check` only by writing a temporary file in `$crew`, running `chmod +x` on it and moving it over the old one with `mv`. Bash reads a running script as it goes, and `crew-merge` may be running `check` for a worker at that moment; it also refuses a `check` that is not executable.
5. Look at throughput: items replaced twice, items stuck since the last round, profiles with room and no worker. Act on each.
6. Append one dated line to `reflections.md` saying what the round changed, even when nothing was learned; it resets the sweep's `REFLECT`.
