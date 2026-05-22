# Commit

Create a clean git commit for the current changes.

## Rules (per `shared/rules/commits.mdc`)

- **No `Co-Authored-By` trailers.** No "Generated with Claude Code" footers. No agent attribution of any kind.
- **Short subject line in the imperative mood.** Match the repo's existing style (run `git log --oneline -10` first).
- **Body only if needed.** One or two sentences max. No multi-paragraph rationale, no bullet list of every file, no marketing words.
- **One commit per working unit.** If the diff spans unrelated changes, ask before bundling.

## Steps

1. Run `git status` and `git diff --staged` (or `git diff` if nothing staged yet) to see what's actually changing.
2. Run `git log --oneline -10` to mirror the repo's commit style.
3. Stage the specific files for this working unit (avoid `git add -A` if there's unrelated work in the tree).
4. Commit with a short subject. Add a body only if the subject wouldn't make sense to a reviewer cold.
5. Run `git status` after to confirm.

Do not push unless I explicitly say to.
