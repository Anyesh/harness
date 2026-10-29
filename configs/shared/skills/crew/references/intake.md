# Plan intake

Read when the user hands the crew a plan. Run it after Start step 7, so a fresh crew has already archived the previous crew's files and written its first reflection line.

1. Copy the plan to `$crew/plan.md`.
2. Split it into items. Each item lands as one reviewed merge, fits one worker session and has a deliverable someone can observe (a test that passes, a command that prints X). Pieces that would edit the same files become one item, or a chain through `deps` so they never run at once.
3. Decide the plan's open choices yourself and log each in `rulings.md`; the question guard denies you `AskUserQuestion` while the crew runs.
4. Have the split reviewed by a fresh subagent: give it `plan.md`, the proposed items with their deliverables, deps and spec text, and the repo, and ask whether every part of the plan is in some item, whether each item can land on its own, which items would edit the same files without a dep between them, and whether the order holds. Fix what it confirms and send the revised split to a new fresh reviewer, round after round, until a round comes back clean.
5. Write each item's part of the plan to `$crew/items/<id>/spec.md`: its design decisions, exceptions and edge cases, plus every constraint the plan sets for all of its work. The board's deliverable is a one-line label; the spec is what the worker builds and is reviewed against.
6. Write the board rows, all `open`, with `deps` naming only ids on the board and forming no cycle; ids follow Start step 4. An item's stop point is landed (merged) unless the plan says otherwise.
7. Write `check` if it does not exist, run `crew-sweep 0` (one comparison, no wait), and act on everything it prints as the Loop says, assigning `READY` items while a profile has room (at most two live workers per profile, or the number `rulings.md` sets). Then start the Loop.
