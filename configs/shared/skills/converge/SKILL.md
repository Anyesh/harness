---
name: converge
description: >
  Iterate a single atomic task to done through a worker-critic loop: the agent
  does the work, a panel of fresh independent reviewers and a set of hard
  verifiable gates judge it against criteria you set, the agent revises, and the
  loop repeats until every hard gate passes and the reviewers converge green, or
  it honestly surfaces a structural ceiling and stops. Works for code changes,
  refactors, research answers, configs, designs, and any short-form artifact
  (README, plan, abstract, commit message, copy, prompt). Use when the user
  wants to converge or iterate a task to a defined bar of acceptance.
  Triggers on: "converge", "iterate to green", "iterate until done", "review
  until green", "polish this", "tighten this", "make this airtight", "iterate
  this with reviewers", "run this through converge".
trigger: /converge
---

# /converge

A worker-critic convergence loop for **one atomic task**. You hand converge a small, self-contained task (or a finished artifact to harden). It runs a short interactive setup to pin down who the reviewers are, what the acceptance criteria are, and which hard gates must pass, then it loops:

1. **Work** — the agent does or revises the task.
2. **Judge** — a panel of fresh, parallel, isolated reviewer subagents critique the result, and every declared hard gate (a command that objectively passes or fails) is run.
3. **Synthesize** — convergent reviewer signals and failing gates become the revision list.
4. **Revise** — the agent applies the smallest change that addresses them.
5. **Stop** — when every hard gate passes **and** the reviewer panel converges green, or when the loop honestly hits a structural ceiling it cannot fix in scope.

## Why it is built this way

Two ideas carry the whole skill, and they are non-negotiable:

- **Fresh reviewers each round.** Reviewers are spawned new every round and never see prior rounds, the diff, or each other. Fresh orthogonal priors make convergence genuinely harder to fake and more robust when reached. Iterated reviewers drift into rubber-stamping the last round's edit.
- **Hard gates outrank soft taste.** A reviewer panel alone is an opinion machine. Real work usually has at least one objectively checkable property (tests pass, build succeeds, output matches, benchmark hits a number). Those are declared as hard gates and the loop **refuses to report converged while any hard gate is red**, no matter how green the reviewers are. Soft reviewer signals shape quality; hard gates define done.

A third idea makes the first two work: **the task must be atomic.** The reviewer panel is only meaningful if reviewers can hold the entire work product in view. If the change is too large to review in one panel, converge stops and asks you to split it. This is a feature, not a limitation: small atomic units are what make the loop converge instead of thrash.

## Usage

```
/converge <task description, file path, or pasted artifact>
/converge <task> --reviewers 5
/converge <task> --personas <p1>,<p2>,<p3>
/converge <task> --gates "pytest -q","ruff check ."
/converge <task> --rounds 5             # hard cap on rounds (default 5)
/converge <task> --stop 5/5             # reviewer stop ratio (default all-green)
/converge <task> --in-scope "..." --out-of-scope "..."
/converge <task> --no-interview         # accept all proposed defaults, skip setup Q&A
```

If no flags are given, converge runs the interactive setup (Step 0) and proposes
defaults you can accept wholesale.

## When to use

- A bounded code change, fix, or refactor with a checkable definition of done.
- A research question whose answer must survive adversarial fact-checking.
- A config, schema, or infrastructure snippet that must satisfy concrete rules.
- Hardening a short-form artifact (README, abstract, plan, PRD, commit message,
  agent description, prompt, marketing copy) against a reviewer panel.

## When NOT to use

- **Non-atomic work.** A multi-file feature, a sprawling migration, or anything
  whose work product cannot be reviewed in a single panel. Decompose first, then
  converge each atomic piece. Converge will refuse and tell you to split.
- **Open-ended generation from nothing.** Converge iterates toward a bar; it does
  not invent the first draft or the task definition. Give it a concrete task.
- **Tasks whose bottleneck is missing information**, not execution or expression.
  Gather the evidence first, then converge the result.
- **Whole-program correctness.** Converge verifies the atomic unit you scope to
  it. It is not a substitute for a full test suite or a security audit.

## The Loop (Authoritative Protocol)

### Step 0 — Interactive setup (run once, before any agent spawns)

Pin down the contract for the run. Where the user has not specified a value, ask
with a structured `AskUserQuestion`-style prompt (one decision at a time) and
propose a sensible default so the user can accept quickly. Capture and write down
for the rest of the loop:

1. **The task.** Restate the atomic task in one sentence, or read the artifact
   verbatim if a path/text was given. If the task is not atomic (cannot be
   reviewed whole in one panel), stop here and ask the user to split it; name the
   seams you would cut along.
2. **Reviewer count.** How many reviewers per round (default 5; floor 3, ceiling
   7). More reviewers means stronger convergence signal and higher cost.
3. **Reviewer personas.** Propose a panel from the task-type defaults below, each
   persona being one sharp orthogonal lens. Let the user rename, drop, add, or
   re-brief any seat. Pin the final panel.
4. **Soft acceptance criteria.** What "good" means on the judgment axes the
   reviewers own (clarity, correctness of reasoning, API ergonomics, prose
   quality). These shape reviewer briefs.
5. **Hard gates.** The objectively checkable conditions, expressed as commands
   that must exit zero or output that must match (e.g. `pytest -q`,
   `ruff check .`, `npm run build`, `test "$(cmd)" = expected`). Zero gates is
   allowed (pure-judgment artifacts like prose), but say so explicitly. Any
   non-zero gate is a hard red that blocks convergence.
6. **Scope.** In-scope: what the work owns and may change. Out-of-scope: what
   reviewers must not demand and the worker must not touch (other modules,
   evidence the artifact's format cannot carry, adjacent refactors).
7. **Budget and format constraints.** Length cap for artifacts (words/lines/
   chars); for code, the blast radius (which files/functions may change). The
   synthesis step rejects convergent reds that would violate these.
8. **Stop criterion and round cap.** Reviewer stop ratio (default all-green) and
   max rounds (default 5).

Do not spawn the first worker step or any reviewer until the task is confirmed
atomic and the gates + scope are pinned.

### Step 1 — Select the reviewer panel

Each reviewer carries exactly one orthogonal lens. Defaults by task type (the
user can override any seat in Step 0):

- **Code change / fix / refactor**: correctness, edge-cases, security,
  readability, API/interface-design. Use `feature-dev:code-reviewer` as the
  subagent type for the correctness and edge-case seats when available.
- **Research answer**: fact-checker (every claim sourced), steel-man (strongest
  opposing reading), gap-hunter (what's missing), logic-critic (does the
  reasoning hold), clarity-critic.
- **Config / schema / infra**: failure-mode, security, portability,
  least-surprise, ops-reviewer.
- **README / tool docs**: new-user, returning-user, integrator (API consumer),
  skeptic, copywriter.
- **Plan / design doc**: scope-skeptic, architecture-critic, ops-reviewer,
  stakeholder-proxy, devil's-advocate.
- **Paper / abstract**: skeptic, domain-expert, cold-reader, prose-critic,
  devil's-advocate.
- **Commit / PR message**: reviewer-time-poor, future-bisect-user, prose-critic,
  scope-checker, copywriter.
- **Marketing copy**: target-audience-proxy, brand-voice-critic, skeptic-buyer,
  copywriter, devil's-advocate.
- **Agent description / skill trigger**: cold-router (does it fire correctly?),
  domain-skeptic, prose-critic, false-positive-hunter, copywriter.
- **Prompt template**: instruction-clarity, edge-case-input, downstream-consumer,
  prose-critic, devil's-advocate.

For mixed or unusual tasks, propose a custom panel with one-line rationale per
seat and let the user adjust.

### Step 2 — Do or revise the work (worker step)

The parent agent performs the task to the current best of its ability, scoped
strictly to in-scope. On round 1 this produces the first result; on later rounds
it applies the revision list from Step 5.

- Keep the work product atomic and within the declared blast radius / length
  budget. Never expand scope to satisfy a reviewer; scope growth is the main way
  these loops fail to converge.
- For file-backed work use `Edit` on the target files. For pasted artifacts hold
  the working version in state.
- If the work product is large enough to threaten the parent's context, delegate
  the execution to a single worker subagent and bring back only the result and a
  short change summary; the parent stays the orchestrator. The constraint that
  the task is atomic should keep this rare.

### Step 3 — Run the hard gates

Run every declared gate. Record each as pass/fail with the relevant output line
(not the full log). A failing gate is a **hard red** and goes to the top of the
revision list with its error. If a gate is flaky or environment-broken (cannot
run at all), say so explicitly and treat it as unknown, not as passed.

If all gates currently fail and the worker has not yet made the work runnable,
that is fine on early rounds; the loop exists to drive them green.

### Step 4 — Spawn the reviewer round (parallel, fresh, isolated)

Dispatch all reviewer `Agent` calls in a **single message** (parallel batch).
Each reviewer receives:

- The current work product verbatim (the diff or the artifact, plus the minimal
  surrounding context needed to judge it).
- The in-scope / out-of-scope block, re-pasted verbatim every round.
- The soft acceptance criteria and any budget/format constraints.
- The persona brief: one sharp paragraph naming the single axis this reviewer
  evaluates.
- The current hard-gate status (so a reviewer does not waste its signal on
  something a gate already covers).
- The strict response contract below.

**Reviewer response contract (embed verbatim in each persona prompt):**

```
Respond in 100-200 words. Judge ONLY your assigned axis. End with exactly one of:

  GREEN SIGNAL — no actionable issue on my axis.

  RED SIGNAL — <one-sentence diagnosis of the single strongest issue on my axis>
  SEVERITY: <blocking | major | moderate | minor>
  FIX: <one concrete change, no more than two sentences>

Severity is required on every RED SIGNAL. Pick exactly one:
  blocking: a core claim or behavior is false or broken; the work cannot ship as is.
  major: a core claim or behavior is unsupported or misleading; the work needs a
         substantive change on my axis, not a wording change.
  moderate: a secondary claim, case, or section is wrong or missing; the core holds.
  minor: precision, sourcing of an example, phrasing, or style; nothing depends on it.

Do not return a wishlist. Identify only the single strongest issue on your axis.
If you would flag several, pick the one with the highest expected information gain
and discard the rest. Do not demand anything declared out of scope.
```

Reviewers must not see prior rounds, the round-over-round diff, or each other's
responses. This is the fresh guarantee and it is non-negotiable. Issue the calls
in parallel, never sequentially: sequential calls leak the parent's stale
anchoring across reviewers.

### Step 5 — Synthesize the round

Combine failing gates and reviewer responses into one revision list:

- **Failing hard gates** — always actionable, always top priority. Done is
  impossible while any is red.
- **Blocking or major reds**: any reviewer, any count. Severity outranks
  convergence, so a single blocking or major red is actionable before a
  convergent moderate or minor one. Order the list by severity first, then by
  count.
- **Convergent reds** — the same axis flagged by ≥2 reviewers with compatible
  fixes. Real; act on them.
- **Single-reviewer reds** — one reviewer, one axis, moderate or minor. Taste.
  Note them; act only if cheap and non-contradictory, weighed against budget.
- **Contradictions** — where one reviewer's fix reopens another's issue (e.g.
  "tighten" vs "add an example"). This is an asymptote signal; surface it.
- **Out-of-scope demands** — reject; name what owns that concern instead. Never
  fabricate evidence or widen blast radius to satisfy a reviewer.

### Step 6 — Revise minimally

Apply the failing-gate fixes and the convergent reds, smallest change first.
Never add scope; every addition is new attack surface for the next round. If a
fix would breach the length budget or blast radius, substitute (cut something of
equal weight) rather than append. After revising, confirm the work still honors
in-scope and has not drifted out of scope, then loop back to Step 2/3.

### Step 7 — Check stop conditions

**Converged** requires BOTH:
- every hard gate passes, AND
- the reviewer panel meets the stop ratio (default all-green).

Stop and report (converged or not) if any of:

1. **Converged** — both conditions above met.
2. **Gate-blocked asymptote** — a hard gate cannot be made to pass within scope
   (the fix would require out-of-scope changes). Stop; name the gate and the
   scope wall. This is a not-converged stop and must be reported as such.
3. **Taste asymptote** — the same soft axis is flagged 3 rounds running and the
   honest reading is "structural, not fixable in this format/scope". Name it,
   stop.
4. **Contradictory churn** — two consecutive rounds where round N's fix reopened
   an issue closed in round N-1. Stop; name the trade-off.
5. **Round cap hit** (default 5). If not converged, say so plainly with the round
   trace. Never report green that was not reached.

### Step 8 — Final report

- The final work product (or the committed diff / artifact).
- Converged or not, with the deciding reason.
- Hard-gate tally (e.g. `gates: 3/3 pass`) and reviewer signal tally with the
  severity breakdown of every red across all rounds (e.g. `3 green / 22 red
  (7 blocking or major, 5 moderate, 10 minor) after 5 rounds`), plus the final
  round's own tally (e.g. `round 5: 4 green / 1 red (1 major)`).
- The round log: one line per round listing failing gates fixed, convergent axes
  addressed, and length/blast-radius delta.
- Any single-reviewer reds noted but not acted on, so the user can judge whether
  that taste matters.
- An explicit asymptote call when applicable, naming the structural property the
  task's scope or format cannot satisfy.

## Anti-Drift Safeguards (enforce every round)

- **Re-anchor scope every round.** Re-paste in-scope / out-of-scope into every
  reviewer prompt verbatim; do not assume prior-round context persists.
- **Gates outrank reviewers, always.** Never report converged with a red gate,
  however green the panel. A green panel over a failing gate is a louder reason
  to keep going, not to stop.
- **Hold the blast radius.** Track which files/functions (or words/lines) changed.
  If the work is growing round over round, prefer "cut/simplify" reds over "add"
  reds and surface the delta.
- **Reject demands the work cannot satisfy in scope.** Evidence that lives
  elsewhere, adjacent refactors, features beyond the atomic task: name the owner,
  do not chase.
- **AI-tic detection on any prose.** Scan for contrastive-negation ("X this, not
  Y", "not just X but Y"), em-dashes / double dashes, hedge words ("might be
  worth", "perhaps", "arguably"), and marketing register ("comprehensive",
  "robust", "elegant", "production-ready"). These are house-style reds regardless
  of reviewer feedback; require a positive rewrite.
- **Refuse to undersell verified evidence.** If the result is weaker than what the
  in-scope evidence supports, bring the claim up to the evidence rather than
  hedging to placate a skeptic who lacks context.

## Prose-refinement mode (the degenerate case)

A short-form artifact with **zero hard gates** is just the worker-critic loop with
the worker step reduced to a minimal text edit. Everything else holds: fresh
reviewer panel, scope re-anchoring, asymptote honesty, AI-tic detection. This is
the original converge behavior, preserved. When the task is pure expression and
there is nothing to execute, do not invent a gate; run reviewers only and converge
on the stop ratio.

## Spawn pattern (concrete)

Per round, the parent issues one message containing all reviewer `Agent` calls in
parallel, each with a self-contained prompt (work product + scope block + gate
status + persona brief + response contract). Use `general-purpose` as the subagent
type, or a specialized type where it fits a seat (e.g. `feature-dev:code-reviewer`
for correctness/edge-cases). The parent waits for all reviewers, then synthesizes.
The parent is the worker and the orchestrator; it does not critique, and reviewers
never critique each other.

## Examples

**Code fix converging in 3 rounds (gates + reviewers):**

```
Task: fix the off-by-one in paginate() so the last page is never dropped.
Gates: `pytest tests/test_paginate.py -q`, `ruff check pagination.py`
Panel: correctness, edge-cases, readability, API-design, security

Round 1: gate pytest FAIL (test_last_page), 2 reviewer red
         (edge-cases: empty list returns one phantom page;
          correctness: ceil division wrong for exact multiples)
         -> rewrite page-count as ceil(n/size), guard n==0.
Round 2: gates 2/2 pass. 1 reviewer red
         (readability: page math duplicated in two branches)
         -> extract _page_count() helper.
Round 3: gates 2/2 pass. 5/5 green.
Converged: 3 rounds, +1 helper, blast radius 1 file.
```

**Research answer hitting a gate-blocked asymptote:**

```
Task: state the current SOTA latency number for X and cite it.
Gates: every numeric claim must carry a resolvable source URL (manual check).
Panel: fact-checker, steel-man, gap-hunter, logic-critic, clarity-critic

Round 1: gate FAIL (the headline number has no primary source, only a blog
         restating it). fact-checker red, gap-hunter red.
         -> trace to the primary paper, replace number with the paper's figure.
Round 2: gate still FAIL (primary paper reports a range, not the single number
         the task assumed). The task's premise (one number) is unsupported.
         Asymptote: cannot satisfy the gate in scope without changing the claim
         from a point to a range.
Stop: NOT converged. Surfaced that the question assumes a precision the evidence
      does not support; user must accept a range or pick a benchmark condition.
```

## Notes for the agent running this skill

- You are the parent: you set up, do the work, spawn reviewers, run gates,
  synthesize, revise, and stop. You do not review.
- Run the full loop autonomously and report the trace at the end, unless the user
  asked for per-round checkpoints. The exception: stop and ask if convergence
  requires going out of scope or breaking a gate's premise.
- Never report converged while a hard gate is red. Done is gates-green AND
  panel-green, or an honestly-named asymptote.
- Keep the task atomic. If it stops being atomic mid-loop (the work is sprawling),
  stop and tell the user to split it; do not push a non-atomic change through.
- For file-backed work, commit the final converged result with a brief message
  naming what converged (e.g. `fix: converge paginate off-by-one, 3 rounds,
  gates green`). Do not commit intermediate rounds.
