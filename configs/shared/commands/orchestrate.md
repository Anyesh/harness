# Orchestrate

Turn this session into a multi-agent orchestrator: escalate the plan to a bigger model for review, split the work into independent streams, run them as parallel subagents, then consolidate and review their output yourself. Use when a task is genuinely parallelizable, meaning several independent files, modules, or workstreams with no shared ordering dependency. Don't force a split onto a single dependency chain; that just adds merge risk for no benefit.

## Steps

1. **Find or write the plan.** Use a plan already in this conversation or under `$WIKI_VAULT/wiki/projects/<slug>/plans/` if one exists. If none exists, write one first (see the `plan` command), since there's nothing to split or review without one.

2. **Escalate for review.** Check the model-identification system reminder for the current model, then spawn a fresh `Plan` agent on a strictly bigger one: `model: "fable"` (Fable 5.1) if not already running as Fable, else `model: "opus"`. Give it the full plan content, relevant file paths, and enough codebase context to reason concretely, not just the plan text in isolation. Ask it specifically for:
   - which pieces are truly independent (no shared state, no ordering dependency)
   - which pieces must stay sequential or single-owner (shared files, migrations, anything two agents editing at once would conflict on)
   - a concrete split into N workstreams, each with an owned file/scope boundary

3. **Fold the split into the plan.** If a plan file exists, edit it in place with a "Parallel Execution" section: the workstreams, what each owns, and the consolidation criteria. If no plan file exists, hold the split in your own context rather than creating one just for this.

4. **Decide on git worktrees.** Use one per workstream when workstreams touch overlapping files or would collide running concurrently (ports, build artifacts, lockfiles). Skip worktrees when the file sets are fully disjoint and nothing runs concurrently in a way that collides. If genuinely unclear from the split, ask the user once via `AskUserQuestion` rather than guessing. When worktrees are needed, use the Agent tool's `isolation: "worktree"` per subagent rather than creating them by hand.

5. **Spawn the subagents in parallel.** One `Agent` call per workstream, all issued in the same turn so they run concurrently; never one call per turn. Each subagent starts fresh (not `fork`) so its context and, if isolated, its working directory stay scoped to its own workstream. Use `fork` only if a stream genuinely needs this conversation's full history to proceed. Each prompt is self-contained: scope, files it owns, what not to touch, and what to return (a summary of changes, not raw diffs).

6. **Consolidate as the orchestrator.** Once every subagent reports back:
   - review each one's actual changes (diff its worktree/branch if isolated), not just its summary
   - check for conflicts between streams, such as the same file touched differently or interface mismatches
   - merge worktree branches back yourself, resolving conflicts yourself
   - run the full test suite once, integrated, not per-subagent
   - report what was built, what the bigger-model review caught, and any conflicts resolved

## Rules

- The main session reviews, splits, spawns, and consolidates. It does not implement a workstream itself unless the split leaves exactly one.
- Don't invent parallelism that isn't there; a single dependency chain gets the bigger-model review and stays single-threaded.
- An unused worktree cleans itself up. A used one leaves you its path and branch, so decide with the user whether to merge, keep, or discard it rather than discarding silently.
