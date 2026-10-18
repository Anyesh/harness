---
name: team
description: "Walk the admin through everything the agent team is waiting on (decisions, branches ready to merge, blocked cards, merges waiting for a deploy), one item at a time, and act only on their word. Use when the user types /team or asks what the team or the agents need from them, what is ready to merge, or what is waiting to deploy."
trigger: /team
---

# /team

The agent team works cards on its boards by itself and stops for the admin at exactly four kinds of thing: a decision only the admin makes, a branch to merge, a card parked for them, and merged work waiting for a deploy. This skill reads what is waiting, puts each item in front of the admin with what they need to judge it, and posts their answer where the dispatcher will act on it. It never decides anything itself.

## Before anything

Run `command -v teamctl`. If it is missing, say this machine does not run the team dispatcher and stop.

## 1. Read the report

```bash
teamctl report --json
```

Lead with one line of counts, for example "2 decisions, 4 to merge, nothing blocked, 1 repo to deploy". Mention anything in `activity` worth knowing: a paused dispatcher, a long Backlog or open `flags` (surfaces the verifier could not prove).

## 2. Walk the items

Go section by section in the report's order (`decisions`, `ready_to_merge`, `blocked`, `deploy_pending`), one item per question with the structured question tool, and never more than one question at a time. Every question offers "Skip for now", which leaves the card untouched.

For each item, read the card before asking:

```bash
teamctl card show <CARD>
```

Its `description` holds the contract (expected behaviour, acceptance checks, surfaces), `comments` hold the agents' reports and questions, and `publication` holds the branch.

**Decisions** (Needs input). Show the agent's question and the options it gives, in the agent's terms, and offer those options. When the card is `held`, the question is a product or direction call: present it and take the admin's pick, but never suggest a pick of your own unless asked. Post the answer, then lift the hold if it had one:

```bash
teamctl card say <CARD> "<the admin's answer>"
teamctl card release <CARD>
```

**Ready to merge** (Awaiting approval). Summarise the contract, the panel verdicts, the verification (`verify.surfaces`, `acceptance`) and any `flags`, then the change itself:

```bash
git -C "<repo>" fetch -q origin
git -C "<repo>" diff --stat "origin/HEAD...origin/<branch>"
```

Read the diff further if the admin asks. Then:

- `merged_by` is `admin`: agents never open or merge pull requests on these repos. Give the admin the `link` to open the pull request and merge it on GitHub themselves; the card moves on by itself once it lands. Do not post `merge`.
- `merged_by` is `gate`: on the admin's word, `teamctl card say <CARD> merge`.
- Either way, a change request goes back to the builder: `teamctl card say <CARD> "change <what to change>"`.

**Blocked**. Show `why`. Whatever the admin answers goes back to the builder with their comment: `teamctl card say <CARD> "<answer>"`.

**Deploy pending**. Show the repo's cards and its `notes` (migrations, environment, containers, dependencies, the repo's own steps). Agents never deploy, and neither does this skill on its own: a deploy runs only when the admin explicitly says to deploy, step by step, with them watching. Once the admin says it is deployed, record it, and every pending card the deploy covers closes:

```bash
teamctl card say <CARD> "deployed <commit>"
```

## Rules

- Post only what the admin chose, in their words. If an answer is ambiguous, ask again rather than guess.
- A skipped item is left exactly as it was.
- Finish with what was done (posted, released, merged, deployed) and what is still waiting.
