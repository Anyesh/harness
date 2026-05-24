## Scope Gate (Three Questions)

Before implementing any feature or multi-file change, you MUST answer these three questions and write them to `.scope.md` in the repo root. Do not write code until `.scope.md` exists and is current for this task.

1. **Context**: What is the project? Where are the specs, plans, and logs? Read the wiki (if it exists), read any existing plans or specs. State what you found.
2. **Definition of done**: What specific, observable criteria declare this task complete? Not "it works" but concrete checkable outcomes (tests pass, endpoint returns X, UI shows Y, performance under Z ms).
3. **Feedback loop**: How are you validating end-to-end? What command runs the tests? What URL shows the result? What metric confirms success? This is how you iterate, not guess.

If `.scope.md` already exists and matches the current task, skip rewriting it. If the task changes mid-conversation, update it.

This does NOT apply to quick fixes, config changes, or single-file edits. It applies when the work is substantial enough that losing context would mean losing progress.
