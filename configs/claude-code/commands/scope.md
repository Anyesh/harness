---
allowed-tools: Bash(~/.claude/scripts/cmd-context.sh *)
argument-hint: [task description]
---

# Scope

Write a `.scope.md` file at the repo root for the current task. Answer the three scope-gate questions before any further code changes.

## Context

!`~/.claude/scripts/cmd-context.sh scope`

## Steps

1. Use `scope_file` above: if it is not `NONE` and matches the current task, do nothing and tell me. If it exists but the task changed, update it. Otherwise, create it.
2. Read the wiki (if `wiki_vault` above is not `UNSET`, using the `plans` and `decisions` listings) and any existing plans or specs relevant to this task. State what you found in the Context section.
3. Define done as specific, observable, checkable criteria. Not "it works" but: tests pass, endpoint returns X, UI shows Y, performance under Z ms.
4. Describe the feedback loop: what command runs the tests, what URL or output confirms success, how you'll iterate without guessing.

## Output

A `.scope.md` file with three sections: Context, Definition of Done, Feedback Loop. Concise. This is a working document, not a PRD.
