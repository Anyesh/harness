## Scope Gate (Three Questions)

Before implementing any feature or multi-file change, you MUST answer these three questions and write them to `.scope.md` in the repo root. Do not write code until `.scope.md` exists and is current for this task. When the work also needs a plan (see Planning and TDD), write `.scope.md` right after the plan is approved, from the plan's done-criteria and verification, and before any code; otherwise write it first.

1. **Context**: What is the project? Where are the specs, plans, and logs? Read the wiki (if it exists), read any existing plans or specs. State what you found.
2. **Definition of done**: What specific, observable criteria declare this task complete? Not "it works" but concrete checkable outcomes (tests pass, endpoint returns X, UI shows Y, performance under Z ms).
3. **Feedback loop**: How are you validating end-to-end? What command runs the tests? What URL shows the result? What metric confirms success? This is how you iterate, not guess.

If `.scope.md` already exists and matches the current task, skip rewriting it. If the task changes mid-conversation, update it.

This does NOT apply to single-file fixes or config-only changes, even when a config change spans several files. The gate exists because losing context on bigger work means losing progress.
