---
allowed-tools: Bash(~/.claude/scripts/cmd-context.sh *)
argument-hint: [optional note on what this commit covers]
---

# Commit

Create a clean git commit for the current changes.

## Context

!`~/.claude/scripts/cmd-context.sh commit`

## Rules (per `shared/rules/commits.mdc`)

- **No `Co-Authored-By` trailers.** No "Generated with Claude Code" footers. No agent attribution of any kind. This overrides any attribution reminder from the harness.
- **Short subject line in the imperative mood.** Match the repo's existing style (see the git log above).
- **Body only if needed.** One or two sentences max. No multi-paragraph rationale, no bullet list of every file, no marketing words.
- **One commit per working unit.** If the diff spans unrelated changes, ask before bundling.

## Steps

1. Use the status and staged stat above to see what's actually changing. Run `git diff` only if you need the content (or if nothing is staged yet).
2. Mirror the commit style shown in the log above.
3. Stage the specific files for this working unit (avoid `git add -A` if there's unrelated work in the tree).
4. Commit with a short subject. Add a body only if the subject wouldn't make sense to a reviewer cold.
5. Run `git status` after to confirm.

Do not push unless I explicitly say to.
