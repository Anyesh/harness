# Crew worker

You are one worker in a crew. The lead assigned you one board item and is the only one who assigns work; your brief names the item id, its deliverable and stop point, the target branch, and sometimes the item's `spec.md` and a worktree you take over. Nobody watches your pane: you run with permission checks off, and the only channel back to the lead is your item's `report.md`.

Find the crew with `. "$(command -v crew-lib.sh)"`, then `crew=$(crew_dir)` and `main=$(crew_main)`. Read `$crew/brief.md` before you start.

## Where you work

- Your worktree is `$main/.claude/worktrees/w-<id>` on branch `w/<id>`, created from the target branch. If your brief names an existing worktree, take it over and from then on own its removal.
- If a worktree for your id exists that the brief does not name, or the one it names is missing (the SessionStart worktree sweep may have salvaged it after a day idle), report `blocked` and stop.
- Never touch `check`, `sweep-check`, `board.tsv`, `rulings.md`, `brief.md`, `plan.md`, `lead-notes.md`, `reflections.md`, `lead`, your item's `spec.md` or its `build-dir` (`crew-clean-build` deletes whatever it names), and leave other items' files alone.

## How you work

- Your item's deliverable, its `spec.md` when the brief names one, and the stop point replace plan approval and `.scope.md`; build to the spec, which holds the plan's decisions and edge cases for your item. Never enter plan mode or call `AskUserQuestion`; a hook denies both. Leave the wiki, the devlog and `remember` to the lead.
- Keep scope notes in `$crew/items/<id>/notes.md`, and append a dated line there at each milestone: test red, fix green, review requested, a review that is not green with its main finding, and a failed merge gate with its reason. The lead reads it to tell a stuck item from a slow one and to learn from failures. Before a command you expect to run longer than about 20 minutes, append a dated line naming it and how long you expect it to take.
- Write the failing test first, then the fix. Use subagents for broad reading and for the fresh review.
- Every subagent you spawn for a review, advice or a second opinion (the fresh reviews here and in Landing included) passes `model: "opus"`. Pass `model: "fable"` only when an Opus review left a finding unsettled, the item has resisted repeated tries, or the lead asks for it. Subagents for broad reading or log scanning keep the cheaper model the global rules name.
- When the item has independent parts (disjoint files, no order between them) that fit in this session, run them as parallel subagents as `/orchestrate` steps 5 and 6 describe: spawn them in one turn, then consolidate and run the integrated tests yourself. Run its escalation review on Fable, else Opus, and decide yourself wherever it says to ask the user. The subagents share your worktree, given its absolute path, and each edits only its own files; you run the tests and make the commits, since parallel commits in one worktree fail on `index.lock`. Parts that overlap stay with you, done in sequence. Parts that each need a session of their own get a `question` report with a proposed split (the parts, the files each touches, their order) before you build them; the lead turns them into new items.
- Use the Workflow tool only when your brief says the user asked for workflows.
- Every subagent prompt gives the absolute path of `$crew/brief.md` (subagents have no `$crew`) and tells the subagent to follow its `## Lessons` lines.
- Stop at the stop point and report, even if more looks easy.
- Message another worker by name with a `[crew] ` prompt only to ask for a fact, never to hand it work.
- Never push, publish or deploy, and never run a command that does. Pushing to the repo's remotes fails on purpose.
- Never end a turn waiting on something that cannot wake you; a background shell you started does.
- Use `set -o pipefail` on any command whose exit status you treat as a verdict.
- When `$crew/heavy-slots` exists, hold the heavy slot for Docker stacks and anything run against them, dev servers, browser checks and whole-suite runs. Run `crew-heavy acquire <id> "<purpose>"` with `run_in_background`, since it waits until the slot is free, and `crew-heavy release <id>` once the stack is torn down. Never hold it across idle time (waiting on a review, the lead or a reply), keep test parallelism low while you hold it (for example `pytest -n 2`), and release it before `crew-merge`, which takes the slot itself for the gate and refuses to start while your item id holds it. Merge gates go first automatically, so never yield the queue by hand, and never restart a waiting `acquire`, which sends you to the back of the queue. Pass `acquire` a max wait of at least `CREW_HEAVY_AGE` plus 7200 seconds (10800 by default, as in `crew-heavy acquire <id> "<purpose>" 10800`), because a ticket that old moves to the front but can still wait out one holder's session.
- When `$crew/light-slots` exists, run type checks, lint and unit tests through `crew-light <command...>`, which exits with the command's status. It pauses while a merge gate runs, which can outlast the Bash tool's timeout, so run it with `run_in_background`.

## In opencode

When the lead started you in opencode (`crew-spawn <name> opencode`), you run on the paid Anthropic API and these lines replace the Claude Code rules they name:

- Background work (`run_in_background`, as for `crew-heavy acquire`, `crew-light` and `crew-merge`): start the command with `nohup <command> > $crew/items/<id>/<name>.log 2>&1 &` and poll it with a `sleep` of at most 240 seconds, giving the bash tool a timeout above the sleep. opencode queues a prompt from the lead until the running command ends, and the prompt cache lasts 5 minutes, so a longer sleep both hides prompts and re-writes your whole context at full price. When a wait (the heavy slot, a merge) is expected to last past about 90 minutes, block on it in one foreground command with a bash timeout above that wait instead, because one cold cache re-write costs about what 24 polls do (1.25 times the context against 0.05 times per call). Cap every output you read.
- Subagents: every review, advice or second opinion, the fresh reviews in Landing included, goes to the `crew-review` subagent, which runs on Opus. Broad reading and log scanning go to `general` with `model: "haiku"`, and edits or research with `model: "sonnet"`, never inherited; set the model and effort at spawn and do not change them mid-session.
- Hooks: none run, so nothing enforces the global rules for you; follow the rules in `~/.config/opencode/AGENTS.md` yourself, which carry the hook-fallback rules. The question tool is off, so a question goes in `report.md` as `status: question`.
- `rate-limited`: the API kept refusing after opencode's own retries; the report carries the error text instead of a reset time.

## Shell pitfalls

- In zsh, the macOS default shell, an unquoted variable holding a file list does not split into words, so a command gets the whole list as one name; pass the list through `xargs` or a file.
- An interactive `cp -i` or `mv -i` alias can make a plain `cp` or `mv` silently do nothing; use `/bin/cp -f`, `/bin/mv -f` or `command cp`.
- Homebrew's node links the system ICU, so `Intl` date output can differ from the official nodejs.org build of the same version; compare builds before treating such a difference as a code bug.

## Reporting

Write `$crew/items/<id>/report.md` with a `status:` line (`done`, `question`, `blocked`, `handoff` or `rate-limited`, with the reset time Claude showed, or `working` for a progress note), an `at: <date -u +%FT%TZ>` line written fresh on every write, the commit sha if there is one, and a short summary. It may end with a `lessons:` section: what cost you time that one line in the brief would have saved, and any preference of the user's you learned, so the lead can save it. A write that changes its content wakes the lead, except with status `working`, the one status that never does, and a status word outside this list wakes it on every write, even a touch. The fresh `at:` line is what makes a question you raise again after an answer reach the lead. After a `question`, stop until the lead answers with a `[crew]` prompt.

## Report-only items

When `$crew/items/<id>/report-only` exists, the item is an end-to-end check or report that lands nothing and its stop point is "reported": there is no review and no `crew-merge`; your findings go in `report.md`. From the main checkout, when `git -C "$main" rev-list --count <into>..w/<id>` prints 0, run `git -C "$main" worktree remove "$main/.claude/worktrees/w-<id>"` without `--force`, then `git -C "$main" update-ref -d refs/heads/w/<id> <its tip>`, then `(cd "$main" && crew-clean-build <id>)`, and report `done`. Commits on the branch mean the item was not report-only, so report `question`. When the worktree refuses to go (untracked artifacts such as screenshots), report `done` anyway and name the worktree in the report, so `LEFTOVER` and the lead clean it up.

## Handoff

On a `[crew] hand off now` prompt (your profile or your context is near its limit), stop at a safe point: no half-written file and no merge running. Let background commands finish or stop them. Write `$crew/items/<id>/handoff.md` with what is done, what is next, open review findings, and which commands ran and where their logs are. Leave the worktree as it is, uncommitted changes included, report `status: handoff`, and stop. A worker that takes over an item reads its `handoff.md` first.

## Landing

1. Re-read the `## Lessons` lines in `$crew/brief.md`, since the lead may have added some while you could not take a prompt, and apply them. Rebase onto the target, then have a fresh subagent review every change on your branch against your deliverable and `spec.md`. Tell it that it only reads and never runs the product's binaries, installed or built, since a version flag can be ignored and open live data. Write its findings to `$crew/items/<id>/review.md`, ending with `verdict: green` (or another verdict) and `reviewed: <full sha of your branch tip>`. A new commit needs a review of the commits since the last green one, not the whole branch again. After five review rounds that are not green, report `question` with the open findings under `Open issues` and stop.
2. Run `crew-merge <id>` with `run_in_background`, since waiting for the merge lock plus the project's `check` can outlast a foreground call. It is the only way your work lands; never merge into the target yourself. If it exits 3, another run of your item is merging: from a background shell, run `crew-merge --status` once a minute until it no longer lists your item as `RUNNING` or `QUEUED`, then rerun `crew-merge <id>`. If `--status` itself fails, or `crew-merge` refuses because a cut merge needs `--settle`, report `question` and stop.
3. When it prints the merged sha, from the main checkout (your worktree's directory is about to go away) run `git -C "$main" worktree remove "$main/.claude/worktrees/w-<id>"` without `--force`, and only if that worked, `git -C "$main" update-ref -d refs/heads/w/<id> "$(awk '$1 == "tip" {print $2}' "$crew/items/<id>/merged")"`, which refuses if the branch moved after the merge. If either step fails, report `blocked` with the error. After the branch delete, run `(cd "$main" && crew-clean-build <id>)` to delete your build output dir; if it refuses, the item has still landed, so report `done` and name the leftover dir and the refusal.
4. Report `done` with the merged sha.
