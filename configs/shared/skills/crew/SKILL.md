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
4. No `$crew/lead` file means a fresh crew. Move any `board.tsv`, `rulings.md`, `plan.md`, `reflections.md`, `items/`, `.sweep-seen`, `.sweep-resources`, `.sweep-limits`, `.sweep-leftovers`, `dagr-run` and `dagr.log` into `$crew/done-$(date +%F-%H%M%S)/`, keeping `brief.md`, `check`, `sweep-check`, `watch-paths`, `thresholds` and `lead-notes.md`. Item ids continue past the highest id in any `done-*` archive, and never use an id whose `w/<id>` branch or `.claude/worktrees/w-<id>` worktree exists.
5. A `lead` file means resume:
   - If `herdr agent get "$slug-lead"` finds a live agent other than you, rename it to the first free `$slug-old<N>` and leave it open, since it may be a session the user still uses. Until its current sweep returns `SUPERSEDED` it may still edit the board, prompt a worker or close a tab, so after your first sweep re-read the board and check every worker.
   - A reboot or reset can rename the host, drop profiles and empty temp dirs, so re-derive both from the live host. Read the pool again from `claude-profile names` and log in `rulings.md` each worker whose profile is gone, so you replace it. Then run `crew-missing-paths`, which checks every absolute path named in the files at the top of `$crew` (`check`, `sweep-check`, helper scripts kept beside them, `brief.md`, `lead-notes.md`) and in item specs, and fix or recreate each `missing:` path it prints before you assign work.
   - Run `crew-merge --status`, and `crew-merge --settle <id>` for each `CUT` or `STALE` line it prints. Then mark `done` every item with a `merged` file, and re-read reports you have not acted on.
6. Name yourself `$slug-lead` with `herdr agent rename` and write `$crew/lead` as your pane id and session id separated by a tab: `$HERDR_PANE_ID` and the `.agent_session.value` of your pane in `herdr pane list`. Do this before you spawn a worker or start a sweep, because without it every sweep prints `SUPERSEDED`. After `/clear` your session id changes and your sweep prints `SUPERSEDED`, so run `/crew` again to resume. Never restart a sweep that printed `SUPERSEDED`; if you think it is wrong, run `crew-role` and act on its answer.
7. Read `lead-notes.md` and the `## Lessons` lines in `brief.md`. Act on a `## Handover` heading in `lead-notes.md`, which a lead at its usage limit left, then delete it, and finish or close any spawn that `rulings.md` shows as started but never assigned. On a fresh start, append the first dated line to `reflections.md`, so the first sweep does not ask for a reflection.
8. If the user handed you a plan, split it into board items with `references/intake.md` now, after any archive in step 4.

## Files you own

- `board.tsv`: tab-separated `id status owner branch into updated deliverable deps`, no header, `status` one of `open|assigned|done|blocked`, `updated` in epoch seconds, `owner` the worker's agent name, `branch` `w/<id>` and the optional `deps` the comma-separated ids of items that must be `done` first. Only you edit it, and only through `crew-board`: `add <id> <into> <deliverable> [deps]` writes an open row, `set <id> field=value...` changes `status`, `owner`, `into`, `deliverable`, `deps` or `updated` (stamped now unless given), and `show` prints it. Give each `crew-board` call its own Bash call, because zsh drops a whole command line on a parse error and an edit bundled with other commands can silently not happen.
- `rulings.md`: timestamped decisions, the done bar, and every worker number used with its profile.
- `brief.md`: what workers in this repo need beyond `references/worker.md`, such as test commands, build paths that must not depend on the checkout location and what not to touch, with the lessons from reflection under `## Lessons`. Give each worktree its own build output dir and the merge gate one more, never shared and built with smaller debug info, and run tests that could reach a live service through an isolation wrapper (`references/isolation.md`).
- `check`: an executable gate that `crew-merge` runs in a temporary merge of the item into its target. Write it before the first assignment.
- `sweep-check`: an optional executable that `crew-sweep` runs in the main checkout after each wait, for checks that should run while work is under way (stray logs, a service that should be down). It prints its findings and exits 0; a non-zero exit means the check itself broke. It only reads: it never changes tracked files, the index or refs, because `crew-merge` needs the main checkout clean and fast-forwards it.
- `watch-paths`: optional, one absolute path per line (build output dirs, caches) whose disk `crew-resources` checks besides the main checkout and the runs dir; a path that does not exist yet is checked at its nearest existing parent.
- `thresholds`: optional `KEY=value` lines, read by `crew-resources` and `crew-sweep` on every sweep so a resumed lead keeps them; a non-empty environment variable overrides a line. Keys: `CREW_DISK_MIN_GB`, `CREW_MEM_MIN_MB`, `CREW_LOAD_PER_CPU`, `CREW_IO_FULL_PCT`, and the whole-number keys `CREW_SESSION_SOFT_PCT` (70) and `CREW_WEEK_SOFT_PCT` (85), above which a profile takes no new work, `CREW_SESSION_HARD_PCT` (90) and `CREW_WEEK_HARD_PCT` (95), at which its workers hand off, `CREW_CONTEXT_K` (400, thousands of tokens of context before a worker hands off) and `CREW_WORKERS_PER_PROFILE` (5).
- `plan.md` and `items/<id>/spec.md`: the plan you were handed and each item's part of it (`references/intake.md`).
- `items/<id>/build-dir`: when the repo gives items their own build output dirs, the item's resolved absolute dir (no template), whose last component is the id or `w-<id>`. `crew-clean-build <id>` deletes that dir when the item lands.
- `lead-notes.md`: rules for you from reflection, and `## Proposed /crew changes` for every crew in any repo.
- `reflections.md`: one dated line per reflection round (`references/reflect.md`).

## Workers

The pool is `claude-profile names` plus `default`, your own `${CLAUDE_PROFILE:-default}` included. A profile runs at most `CREW_WORKERS_PER_PROFILE` live Claude sessions, counting every crew's workers and leads and the user's own sessions on it, since they share its usage limit. Fill the other profiles first, because yours also carries you, and when your profile nears its usage limit, close or replace the workers on it first.

Your status line and Claude's usage warnings never reach your context; the sweep's `POOL` lines carry every profile's figures instead, yours included.

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
5. Only now run `crew-board set <id> status=assigned owner=$slug-wN`, which also sets `updated` to now. If the repo gives items their own build output dirs, write the item's dir to `items/<id>/build-dir`.
6. Brief it in one prompt starting with `[crew] `, the prefix cache-guard lets through a cold cache. Name `references/worker.md` in this skill, `$crew/brief.md`, the item id, its deliverable, its `$crew/items/<id>/spec.md` if intake wrote one, its `$crew/items/<id>/build-dir` if you wrote one, its stop point (by default landed for an item from a plan, otherwise the mechanism and a red test, before any fix), the target branch, and for a replacement the existing worktree it takes over. For a new item write "create your worktree at `$main/.claude/worktrees/w-<id>`", because "your worktree is <path>" reads as an existing one, which `references/worker.md` has the worker report as blocked. Say that the user asked for workflows only when they did.

Address workers only by name: `send-keys` and `agent prompt` take the name. To close a worker's tab, take the `tab_id` of the `herdr tab list` entry labelled `$slug-wN` at that moment, and close nothing unless exactly one tab carries that label, noting it in `rulings.md` instead.

## Loop

Run `crew-sweep` with `run_in_background` (it waits up to 900 seconds for an item file to change, or takes the wait in seconds as its argument), act on everything it prints in the same turn, then start it again. Each worker with an `assigned` row gets a line `WORKER <name> item <id> <herdr status> on <profile>` (`on ?` until its status line first reports) followed by any of the flags below.

- `SUPERSEDED`: another session is lead now, so stop acting as lead.
- `ALL-DONE`: assign the next open work if there is any, otherwise close out.
- `ERROR <step>: <message>`: a crew-role or herdr call failed and the sweep retried it; if the sweep exited after repeated errors, tell the user what failed and start it again.
- `CHANGED <path>` or `REMOVED <path>`: read that file. `TIMEOUT` means nothing changed during the wait.
- A changed `report.md`: answer a `question` with a `[crew]` prompt and run `crew-board set <id>`, which sets `updated` to now, so the sweep watches that worker again; for `done` with a `merged` file, mark the row `done`, assign in the same turn what it unblocks, and give the worker its next item or close its tab. For a `done` report that names a leftover build dir, rerun `crew-clean-build <id>` from the repo; a refusal of the path itself (its last component, or a protected dir it is, holds or sits in) repeats, so then correct `items/<id>/build-dir` and rerun it, or delete the dir yourself under the `RESOURCE` rule below (nothing `RUNNING` or `QUEUED`, no worker building there). For `blocked`, mark the row `blocked` and log the reason, except when the item has a `merged` file whose tip is in `into`: it landed and only cleanup failed, so mark it `done`, log the error and let `LEFTOVER` clean up. Handle `rate-limited` as a usage limit under `IDLE`, and `handoff` under `LIMIT` or `CONTEXT`, whichever prompted it.
- `READY <id>`: an open item whose deps are all `done`. Assign every READY item before you start the sweep again, unless a disk, memory, load or io `RESOURCE` breach is active: give it to a `SPARE` worker without `holds` or `CONTEXT` on a profile below both soft thresholds, otherwise spawn one on a profile without `FULL`, preferring profiles whose figures are known. Count each worker you spawn or give work this turn toward its profile, which is full once that count reaches the cap. A worker's split proposal becomes new board items with deps, assigned the same way, and the original item's deliverable (`crew-board set <id> deliverable=...`) and `spec.md` narrow to the part its worker keeps.
- `POOL <profile> <crew>/<all>/<cap> session <x>% week <y>%`: this crew's live workers, every live Claude session on the profile, the cap, and its usage (`?%` when no session has reported a figure for the current window). ` FULL` means it is at the cap or a soft threshold and takes no new worker.
- `LIMIT <profile> <session|week> <x>% resets in <m> min`: a profile with your workers, or your own, reached a hard threshold. It wakes you once per window. If the reset is under 20 minutes away, let the workers run (the `IDLE` rate-limit wait covers them). Otherwise, when a target exists (a `SPARE` worker without `holds` or `CONTEXT` on a profile below both soft thresholds, or room on such a profile; a `?` profile counts, after those with known figures), prompt each worker on it that is not `MERGING` with `[crew] hand off now`, moving your own profile's workers first. On its `handoff` report, close its tab and give the item, its worktree and `items/<id>/handoff.md` to the target. With no target, let the workers run into the limit and tell the user when it is the week window. If your own profile is at a hard threshold, write the crew's state under a dated `## Handover` heading in `lead-notes.md` and tell the user to resume `/crew` from another profile.
- `CONTEXT <n>k` (a flag on `WORKER` and `SPARE` lines): the session holds at least `CREW_CONTEXT_K` thousand tokens, or 80% of its window. It wakes you once per session. Prompt the worker `[crew] hand off now` (not while `MERGING`), close its tab on the `handoff` report, and brief a fresh worker on the same profile with the worktree and `handoff.md`, unless that profile is at a hard threshold, which makes it a `LIMIT` handoff.
- `SPARE <name> <status> on <profile>`: a live worker with no `assigned` row, ` holds <id>` when it owns a `blocked` one. Give it a READY item when its profile is below both soft thresholds and it has no `CONTEXT`, otherwise close its tab; one that `holds` an item blocked on the user keeps its tab until the answer comes. `SPARE <label> no agent`: a worker tab whose Claude exited; close it. A `SPARE` line can be older than your latest spawn or assignment, so right before acting on one, check with `crew-board show` that the name still owns no `assigned` row and, for `no agent`, that `herdr agent get <label>` still finds none; leave alone only a worker you are spawning in this same turn.
- `LEFTOVER <id> <worktree|branch|build-dir> <path or ref>`: a landed item whose worktree, `w/<id>` branch or build dir is still there. From the main checkout run `git -C "$main" worktree remove <path>`, `git -C "$main" update-ref -d refs/heads/w/<id> <tip from items/<id>/merged>` and `crew-clean-build <id>`, and log any refusal in `rulings.md`; each leftover is printed once.
- `DEPS <id> <problem>`: an open item that can never start, because a dep `names unknown` id, it `waits on blocked` item, `is in a cycle` or `waits on stuck` item. Fix the order on the board or mark the row `blocked`, logging in `rulings.md` which dep blocked it; for `waits on stuck`, fix the stuck dep's own DEPS line instead. When a dep you logged as a cause can finish again (reopened, added to the board or its order fixed), reopen the rows you blocked because of it.
- `GONE <name>`: its Claude exited or its pane closed (herdr drops a name 10 to 15 seconds after exit). Close its tab by label, then give the item to a fresh worker that takes over the same worktree.
- `IDLE`: read its screen. "Usage limit reached" means it is rate-limited and cannot write its own report. When the reset it shows is under 20 minutes away, keep the worker: run the next sweep with the seconds left until the reset as its wait, then prompt the worker with `[crew]` to continue. Otherwise replace it on another profile. Any other idle screen: prompt it or replace it.
- `QUIET`: the item shows no progress (row update, report, notes, merging file or commit on its branch) for an hour. Read the worker's screen and `items/<id>/notes.md`, then prompt it, split the item or replace the worker. A note counts as progress for only an hour, so when the last `notes.md` line names a long run still inside its expected length and the screen shows it running, leave the worker alone. A worker with an unanswered `question`, `blocked` or `handoff` report is never QUIET.
- `DIALOG`: read the screen it shows, then answer with `send-keys` within the same limits as at spawn or replace the worker, and log the call in `rulings.md`.
- `STALE-MERGE <id>`: a `crew-merge` run died (a kill, crash or reboot) and left its marker. Run `crew-merge --settle <id>`. If it reports the item landed, the item now has a `merged` file, so mark it `done`; otherwise prompt its worker, if it is live, to rerun `crew-merge`.
- `MERGING`: the worker's `crew-merge` is running or queued for the merge lock. Leave it alone, and never close or replace a worker while it merges. `MERGING QUIET` means its merge has run for an hour, possibly a hung `check` holding the merge lock for every item: read `check-<id>.log` in `${CREW_RUNS_DIR:-$HOME/.cache/crew-runs}/$slug` and tell the user, without closing the worker.
- `RESOURCE <line>`: `crew-resources` found low free disk (`disk <mount> <N> GB free (<path>)`, under `CREW_DISK_MIN_GB`, default 20, and `critical` under a quarter of that), low memory (`memory`, under `CREW_MEM_MIN_MB`, default 1024), a 5-minute `load` above `CREW_LOAD_PER_CPU` (default 2) per CPU, or I/O stalls (`io <x>% full over 60 s (D state: <names>)`, Linux only, above `CREW_IO_FULL_PCT`, default 30), where tasks wait on disk while the CPU idles: pause builds rather than add workers. Set lasting thresholds in `$crew/thresholds`. A new breach ends the sweep's wait, and one that lasts wakes you again every 10 minutes. In the same turn free space, or tell workers with a `[crew]` prompt to stop building until you say. Before you delete a build or runs dir, `crew-merge --status` must list nothing `RUNNING` or `QUEUED` and no worker may be building there, since deleting it under a merge gate or a build breaks that run. `RESOURCE failed: <message>` means a probe itself broke, such as a hung mount named in `watch-paths`; fix it.
- `REFLECT`: run a reflection round with `references/reflect.md`. It may arrive up to one wait late.
- `CHECK <line>`: output from `sweep-check`; act on what it flags. `CHECK failed: <message>` means the check itself failed or timed out after 30 seconds, so fix it.

When you replace a worker, close its tab first, then spawn the new one and brief it with the worktree it takes over.

## Your rules

- Decide product, scope and performance calls yourself and log each in `rulings.md`. Ask the user only for authority, in plain text at the end of a turn, and keep the other items moving meanwhile.
- Read reports and capped tails only. Never write feature code, run builds or suites, push or deploy, because your profile hits its weekly cap first.
- Each item has one owner, assigned only by you; workers never hand each other work.

## Stop

When the user says to stop the crew, close every worker tab (waiting for any `MERGING` worker to finish first), list each open item's branch and worktree for the user, and delete `$crew/lead`. A later `/crew` starts fresh.

## Close-out

1. Close every `$slug-w<N>` tab, then run a last reflection round with `references/reflect.md`, saving user preferences and cross-crew gotchas to project memory as it says, then delete `$crew/lead`, which also ends the question guard for you.
2. For every `w/<id>` whose tip is already in its target, run `git -C "$main" worktree remove <path>` and then `git -C "$main" branch -d w/<id>`, never with `--force`, then `crew-clean-build <id>`, and list any that refuse.
3. Write one devlog entry for the crew's outcomes.
4. Tell the user the list under `## Proposed /crew changes` in `lead-notes.md`, then remove the entries you told, so the next crew does not repeat them.
5. For each `blocked` item, tell the user the branch it is left on if that branch still exists, and `.git/worktree-salvage/` if the SessionStart worktree sweep salvaged its worktree. That sweep may remove a worktree after a day idle but keeps unlanded branches.
