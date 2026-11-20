# Promoting cross-repo rules

Read in a harness session when SessionStart prints `CREW-PROPOSALS: N pending`. Leads append rules for every crew to `$CREW_MEMORY_DIR/rules/proposed.md` through `crew-lesson add --all`; this turns each one into a change to the public skill or a recorded rejection, so no rule is lost and none is proposed twice.

For each line in `rules/proposed.md`:

1. Check `rules/decided.md` and the current skill; a rule already covered is decided as a duplicate with the covering file and line.
2. Decide where the rule is enforced. A mechanism (a check in a crew script, a hook, a sweep line) beats skill text; text goes in the one place the reader meets the situation (`SKILL.md`, `references/worker.md`, a reference file).
3. Generalize it: no repo key, client or product term, host, path, person or measured value. The rule states the class of mistake, as a reflection lesson does.
4. Implement it with tests, as any harness change (failing test first, the touched test files, shellcheck and shfmt).
5. Have a fresh subagent on the judgment model review the diff against the rule and the privacy bar: nothing in the diff identifies the repo, the client or the user's infrastructure. Fix what it confirms.
6. Commit in harness with a short subject, then push. `publish-leak-guard` and gitleaks stay the last gate.
7. Move the line from `proposed.md` to `decided.md` as `- <rule> -> <harness sha>`, or `- <rule> -> rejected: <reason>`, and run `crew-memory sync "promote"`.

A rule that turns out repo-specific moves to that repo's `lead-notes.md` (`crew-lesson add --lead` from inside that repo) and is decided as `moved to <key>`.
