---
name: crew
description: "Run a crew: this session becomes the lead and directs separate Claude worker sessions, on the user's other Claude accounts, in Herdr panes; each worker owns one board item in its own worktree and lands it through a reviewed merge gate. Use when the user types /crew or asks to run a crew or work through items with several agents in Herdr. Not for splitting work across subagents inside one session (that is /orchestrate). Claude Code inside Herdr only."
trigger: /crew
---

# /crew

You are the lead. Asking for a crew is the explicit Herdr request the herdr skill requires. You keep the permission mode the user started you in; if you stop on a permission prompt you look idle and workers' reports wait for you.

While a crew runs, `crew-question-guard.sh` denies your `AskUserQuestion`, `EnterPlanMode` and `ExitPlanMode` and tells you what to do instead. Follow its text; it is the one statement of that exception.

## Start or resume

1. `[[ $HERDR_ENV == 1 ]]` or stop and tell the user to start Claude inside Herdr.
2. Resolve the crew from the shared library, and keep your shell's working directory inside the repo afterwards, because the guard finds the crew from the hook's `cwd`:

   ```bash
   . "$(command -v crew-lib.sh)"
   crew=$(crew_dir) slug=$(crew_slug) main=$(crew_main)
   ```

3. Create `$crew` if needed and make sure `<git common dir>/info/exclude` lists `.claude/crew/`, `.claude/worktrees/` and `.dagr/` (the run file `crew-sweep` writes for the dagr pane, wherever your pane's directory is).
4. No `$crew/lead` file means a fresh crew. Move any `board.tsv`, `rulings.md`, `items/`, `.sweep-seen`, `dagr-run` and `dagr.log` into `$crew/done-$(date +%F-%H%M%S)/`, keeping `brief.md` and `check`. Item ids continue past the highest id in any `done-*` archive, and never use an id whose `w/<id>` branch or `.claude/worktrees/w-<id>` worktree exists.
5. A `lead` file means resume:
   - If `herdr agent get "$slug-lead"` finds a live agent other than you, rename it to the first free `$slug-old<N>` and leave it open, since it may be a session the user still uses. Until its current sweep returns `SUPERSEDED` it may still edit the board, prompt a worker or close a tab, so after your first sweep re-read the board and check every worker.
   - Mark `done` every item with a `merged` file, or with a `merging` file (`key value` lines `pid`, `start`, `tip` and, once the fast-forward is under way, `merged`) whose `merged` sha is an ancestor of its target, and re-read reports you have not acted on.
6. Name yourself `$slug-lead` with `herdr agent rename` and write `$crew/lead` as your pane id and session id separated by a tab: `$HERDR_PANE_ID` and the `.agent_session.value` of your pane in `herdr pane list`. Do this before you spawn a worker or start a sweep, because without it every sweep prints `SUPERSEDED`. After `/clear` your session id changes and your sweep prints `SUPERSEDED`, so run `/crew` again to resume. Never restart a sweep that printed `SUPERSEDED`; if you think it is wrong, run `crew-role` and act on its answer.

## Files you own

- `board.tsv`: tab-separated `id status owner branch into updated deliverable`, no header, `status` one of `open|assigned|done|blocked`, `updated` in epoch seconds, `owner` the worker's agent name and `branch` `w/<id>`. Only you edit it, with your file tools.
- `rulings.md`: timestamped decisions, the done bar, and every worker number used with its profile.
- `brief.md`: what workers in this repo need beyond `references/worker.md`, such as test commands, build paths that must not depend on the checkout location and what not to touch.
- `check`: an executable gate that `crew-merge` runs in a temporary merge of the item into its target. Write it before the first assignment.

## Workers

The pool is `claude-profile names` plus `default`. Keep your own `${CLAUDE_PROFILE:-default}` for yourself and spread workers across the rest.

To spawn one worker:

1. N is one past the highest worker number in `rulings.md` or any `done-*/rulings.md`, below 1000. Write it to `rulings.md` with the profile before anything else, and if `herdr agent get "$slug-wN"` finds an agent, take the next N.
2. Build the environment and create the tab. The empty value resets each remote's push URLs, so `git push` to a named remote fails while fetch still works; nothing but the worker's instructions stops `git push <url>`, a publish or a deploy.

   ```bash
   envs=(--env HARNESS_UNATTENDED=1 --env HARNESS_NOTIFY=0)
   if [[ $profile != default ]]; then
     while read -r kv; do envs+=(--env "$kv"); done < <(claude-profile env "$profile")
   fi
   n=0
   for r in $(git -C "$main" remote); do
     for v in "" /nonexistent/crew-no-push; do
       envs+=(--env "GIT_CONFIG_KEY_$n=remote.$r.pushurl" --env "GIT_CONFIG_VALUE_$n=$v")
       n=$((n + 1))
     done
   done
   ((n)) && envs+=(--env "GIT_CONFIG_COUNT=$n")
   herdr tab create --cwd "$main" --label "$slug-wN" --no-focus "${envs[@]}"
   ```

3. Take `.result.root_pane.pane_id` and poll `herdr pane process-info --pane <id>` until `.result.process_info.shell_pid` is a number equal to `.foreground_process_group_id`, which means the shell is at its prompt. Then run `herdr agent start "$slug-wN" --kind claude --pane <id> --timeout 120000`, passing Claude's `--dangerously-skip-permissions` after herdr's end-of-options marker as `herdr agent start --help` shows. Retry only while the shell is at its prompt, never once a foreground process is named `claude`.
4. On `agent_not_ready`, read the screen with `herdr agent read "$slug-wN" --source visible --lines 40`:
   - The workspace trust dialog ("Is this a project you created or one you trust?", with `❯ No, exit` above `Yes, I trust this folder`) gets `herdr agent send-keys "$slug-wN" Down Enter`, because running `/crew` here is the user's trust decision; then wait for `idle`.
   - A startup step within authority the user already gave, such as approving the repo's `.mcp.json` servers, gets answered with `send-keys`.
   - Anything else, such as a login or billing prompt, means you close the tab and tell the user.

   If `herdr agent list` then shows the pane with an empty `.name // ""`, rename it.
5. Only now set the item's board row to `assigned`, with this owner and `updated` set to now.
6. Brief it in one prompt starting with `[crew] `, the prefix cache-guard lets through a cold cache. Name `references/worker.md` in this skill, `$crew/brief.md`, the item id, its deliverable and stop point (by default the mechanism and a red test, before any fix), the target branch, and for a replacement the existing worktree it takes over.

Address workers only by name: `send-keys` and `agent prompt` take the name. To close a worker's tab, take the `tab_id` of the `herdr tab list` entry labelled `$slug-wN` at that moment, and close nothing unless exactly one tab carries that label, noting it in `rulings.md` instead.

## Loop

Run `crew-sweep` with `run_in_background` (it waits up to 900 seconds for an item file to change, or takes the wait in seconds as its argument), act on everything it prints in the same turn, then start it again. Each worker with an `assigned` row gets a line `WORKER <name> item <id> <herdr status>` followed by any of the flags below.

- `SUPERSEDED`: another session is lead now, so stop acting as lead.
- `ALL-DONE`: assign the next open work if there is any, otherwise close out.
- `ERROR <step>: <message>`: a crew-role or herdr call failed and the sweep retried it; if the sweep exited after repeated errors, tell the user what failed and start it again.
- `CHANGED <path>` or `REMOVED <path>`: read that file. `TIMEOUT` means nothing changed during the wait.
- A changed `report.md`: answer a `question` with a `[crew]` prompt; for `done` with a `merged` file, mark the row `done` and give the worker its next item or close its tab; for `blocked`, mark the row `blocked` and log the reason; replace a `rate-limited` worker.
- `GONE <name>`: its Claude exited or its pane closed (herdr drops a name 10 to 15 seconds after exit). Close its tab by label, then give the item to a fresh worker that takes over the same worktree.
- `IDLE`: read its screen. "Usage limit reached" means it is rate-limited and cannot write its own report, so replace it on another profile; otherwise prompt it or replace it.
- `DIALOG`: read the screen it shows, then answer with `send-keys` within the same limits as at spawn or replace the worker, and log the call in `rulings.md`.
- `MERGING`: leave it alone, and never close or replace a worker while it merges.

When you replace a worker, close its tab first, then spawn the new one and brief it with the worktree it takes over.

## Your rules

- Decide product, scope and performance calls yourself and log each in `rulings.md`. Ask the user only for authority, in plain text at the end of a turn, and keep the other items moving meanwhile.
- Read reports and capped tails only. Never write feature code, run builds or suites, push or deploy, because your profile hits its weekly cap first.
- Each item has one owner, assigned only by you; workers never hand each other work.

## Stop

When the user says to stop the crew, close every worker tab (waiting for any `MERGING` worker to finish first), list each open item's branch and worktree for the user, and delete `$crew/lead`. A later `/crew` starts fresh.

## Close-out

1. Delete `$crew/lead`, which also ends the question guard for you.
2. For every `w/<id>` whose tip is already in its target, run `git -C "$main" worktree remove <path>` and then `git -C "$main" branch -d w/<id>`, never with `--force`, and list any that refuse.
3. Write one devlog entry for the crew's outcomes.
4. For each `blocked` item, tell the user the branch it is left on if that branch still exists, and `.git/worktree-salvage/` if the SessionStart worktree sweep salvaged its worktree. That sweep may remove a worktree after a day idle but keeps unlanded branches.
