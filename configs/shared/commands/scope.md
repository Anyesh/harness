# Scope

Write a `.scope.md` file at the repo root for the current task. Answer the three scope-gate questions before any further code changes.

## Steps

1. Check if `.scope.md` already exists. If it does and matches the current task, do nothing and tell me. If it exists but the task changed, update it. Otherwise, create it.
2. Read the wiki (if `WIKI_VAULT` is set), check `graphify-out/GRAPH_REPORT.md` if present, and read any existing plans or specs relevant to this task. State what you found in the Context section.
3. Define done as specific, observable, checkable criteria. Not "it works" but: tests pass, endpoint returns X, UI shows Y, performance under Z ms.
4. Describe the feedback loop: what command runs the tests, what URL or output confirms success, how you'll iterate without guessing.

## Output

A `.scope.md` file with three sections: Context, Definition of Done, Feedback Loop. Concise — this is a working document, not a PRD.
