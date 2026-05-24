---
name: converge
description: >
  Iteratively refine a piece of writing or design until N independent fresh
  reviewers all signal green, or the loop honestly detects it is chasing taste
  and stops. Use when the user wants to converge a deliverable (paper abstract,
  README, plan, design doc, commit message, marketing copy, agent description,
  function signature, prompt) through structured multi-perspective critique.
  Triggers on: "converge", "iterate to green", "review until green",
  "polish this", "tighten this", "make this airtight", "iterate this with reviewers".
trigger: /converge
---

# /converge

A research-grade iterative-refinement loop for any short-form artifact (paper section, README, plan, design doc, commit message, ad copy, agent description, function signature, prompt template). Spawns multiple fresh, parallel, isolated reviewer subagents per round, synthesizes their critiques into convergent-red signals, applies the smallest edit that addresses the convergent reds, and either converges to all-green or honestly surfaces that the loop is hitting a structural ceiling rather than fixable defects.

The core insight: fresh-each-round reviewers have orthogonal priors, so convergence is genuinely harder than with iterated reviewers, but the convergence that is reached is more robust. This skill bakes that lesson in by defaulting to fresh-per-round and refusing to let the loop drift into chase-the-last-reviewer's-taste.

## Usage

```
/converge <path-or-pasted-text>
/converge <path> --type paper|readme|code|plan|commit|copy|prompt
/converge <path> --personas <p1>,<p2>,<p3>,<p4>,<p5>
/converge <path> --rounds 5            # hard cap on rounds (default 5)
/converge <path> --stop 5/5            # stop criterion (default all-green)
/converge <path> --in-scope "..." --out-of-scope "..."
```

If artifact type is omitted, infer from extension and content (`.md` README pattern vs paper abstract vs commit), and confirm the inferred type in the first round summary.

## When to Use

- Tightening a paper abstract, intro, or conclusion before submission.
- Polishing a README for a tool whose first impression matters.
- Hardening a design doc or PRD before stakeholder review.
- Refining a commit message or PR description that has to land cleanly.
- Pressure-testing marketing copy, agent descriptions, or skill triggers.
- Iterating a prompt template against multiple personas of consumer.

## When NOT to Use

- Long-form artifacts (full papers, multi-page docs) — reviewer panels lose focus past ~500 words. Section by section instead.
- Anything where the bottleneck is missing information rather than expression — go gather the evidence first.
- Code logic correctness — use tests and the code-review skill instead; converge is for *expression*, not behavior.
- A first draft from scratch — converge polishes; it does not generate.

## The Loop (Authoritative Protocol)

### Step 0 — Anchor the artifact (run once)

Before any reviewers spawn, establish and write down for the remainder of the loop:

1. **The artifact**: paste it verbatim into the working state. If a file path, read it now.
2. **In-scope**: what evidence, claims, and constraints the artifact is allowed to make. What it owns.
3. **Out-of-scope**: things reviewers must not demand (e.g. "the abstract cannot include the full ablation table — the body owns that").
4. **Length budget**: the artifact's structural cap (word count, line count, character count). Reviewers asking for additions must respect this; the synthesis step will reject convergent reds that would violate the budget.
5. **Format constraints**: any non-negotiable structural rules (e.g. "must end with a call to action", "must mention library X", "must fit in 280 chars").

If the user did not specify in-scope / out-of-scope, ask once with an `AskUserQuestion`-style structured prompt. Do not start spawning reviewers until both are pinned.

### Step 1 — Select the reviewer panel

Five reviewers per round, each with one sharp orthogonal lens. Defaults by artifact type:

- **Paper / academic abstract**: skeptic, domain-expert, cold-reader, prose-critic, devil's-advocate
- **README / tool docs**: new-user, returning-user, integrator (API consumer), skeptic, copywriter
- **Code (function signature, API surface)**: security, performance, readability, API-design, edge-cases
- **Plan / design doc**: scope-skeptic, architecture-critic, ops-reviewer, stakeholder-proxy, devil's-advocate
- **Commit / PR message**: reviewer-time-poor, future-bisect-user, prose-critic, scope-checker, copywriter
- **Marketing copy / ad**: target-audience-proxy, brand-voice-critic, skeptic-buyer, copywriter, devil's-advocate
- **Agent description / skill trigger**: cold-router (does the trigger fire correctly?), domain-skeptic, prose-critic, false-positive-hunter, copywriter
- **Prompt template**: instruction-clarity, edge-case-input, downstream-consumer, prose-critic, devil's-advocate

If the artifact type is mixed or unusual, propose a custom panel with rationale per persona, and let the user override.

### Step 2 — Spawn the round (parallel, fresh, isolated)

For each round, dispatch five `Agent` calls in a **single message** (parallel batch). Each reviewer must receive:

- The artifact verbatim (post-edit if past round 1).
- The in-scope / out-of-scope block, re-pasted verbatim (re-anchoring every round prevents drift).
- The length budget and format constraints.
- The persona brief (a single sharp paragraph naming the one axis this reviewer evaluates).
- A strict response contract.

**Reviewer response contract (enforce verbatim in each persona prompt):**

```
Respond in 100-200 words. End your response with exactly one of:

  GREEN SIGNAL — no actionable issue on my axis.

  RED SIGNAL — <one-sentence diagnosis of the single strongest issue on my axis>
  FIX: <one concrete edit suggestion, no more than two sentences>

Do not return a wishlist. Identify only the single strongest issue on your axis.
If you would normally flag multiple, pick the one with the highest expected information gain for the author and discard the rest.
```

Reviewers must not see prior rounds' critiques, must not see the diff from the previous round, and must not see each other's responses. This is the "fresh" guarantee and it is non-negotiable.

### Step 3 — Synthesize the round

Read the five responses. Classify each red on the axis it targets and produce:

- **Convergent reds**: ≥2 reviewers flagging the same axis with substantively compatible fixes. These are real, act on them.
- **Single-reviewer reds**: one reviewer flagging one axis. Taste. Note them but do not always act; weigh against length budget and contradiction risk.
- **Contradictions**: cases where one reviewer's fix would create the issue another reviewer flagged (classic: copywriter says "tighten" while integrator says "add example"). This is the asymptote signal — surface it explicitly.
- **Out-of-scope demands**: any reviewer asking for evidence the artifact's format cannot carry. Reject these; the structural ceiling is real, do not chase it.

### Step 4 — Edit minimally

Apply only the convergent reds. Never add scope, because every addition creates new attack surfaces for the next round. If a convergent fix would violate the length budget, choose the substitution that preserves the budget (cut something equally weighted) rather than appending.

If after applying convergent reds the artifact has shifted meaningfully, re-confirm it still satisfies the in-scope claims and has not drifted into out-of-scope territory.

### Step 5 — Check stop conditions

Stop the loop if any of:

1. **5/5 green** (or whatever stop ratio the user set).
2. **Asymptote reached**: same axis flagged in 3 consecutive rounds and the response is "this is structural, not fixable in this format". Name it and stop.
3. **Contradictory churn**: two consecutive rounds where the fix from round N reopened an issue closed in round N-1. Stop and name the trade-off.
4. **Round cap hit** (default 5). If the loop never converged, surface that honestly with the round trace; do not lie about reaching green.
5. **Length-budget violation pressure**: convergent reds in two consecutive rounds would require violating the length budget. The format is the ceiling, not the editor; stop and surface.

If none of the above, increment round and go to Step 2 with the edited artifact.

### Step 6 — Final report

Output:

- The final converged artifact.
- Round count and final reviewer signal tally (e.g. `4 green / 1 red after 4 rounds`).
- The convergent-reds log (one line per round: round number, convergent axes addressed, length delta).
- An honest "we're at the asymptote" call if applicable, naming the structural property the artifact's format cannot carry.
- Any single-reviewer reds that were noted but not acted on, so the user can decide whether taste matters here.

## Anti-Drift Safeguards (Enforce Every Round)

- **Re-anchor scope each round.** Re-paste in-scope / out-of-scope into every reviewer prompt verbatim. Do not assume the prior round's context persists.
- **Track length budget across rounds.** If round N adds 12 words, round N+1's convergent reds should preferentially be "cut" reds, not "add" reds. Surface length delta in the round summary.
- **Reject evidence demands the artifact cannot satisfy.** If a reviewer asks for a number, a citation, or an ablation that lives in the body / appendix / future work, the answer is "not in this artifact, X owns it" — not "fabricate evidence to satisfy the reviewer".
- **AI-tic detection.** Scan the artifact each round for contrastive-negation patterns ("X this, not Y", "not just X but Y", "we don't merely X, we Y") and require positive reframing if found. Same for em-dashes, double dashes, hedge words ("might be worth", "perhaps", "arguably"), and the marketing register ("comprehensive", "robust", "elegant", "production-ready") — these are house-style violations regardless of reviewer feedback.
- **Refuse to undersell verified evidence.** If the artifact's claims are weaker than what the user has stated as in-scope evidence, the editor's job is to bring the claim up to what the evidence supports — not to hedge to satisfy a skeptic reviewer who lacks context.

## Spawn Pattern (Concrete)

For each round, the parent agent must issue a single message containing five `Agent` tool calls in parallel. Each call uses `subagent_type: general-purpose` (or a more specialized type if available for the persona — e.g. `feature-dev:code-reviewer` for the code-edge-cases persona), with a self-contained prompt that includes the artifact, the scope block, the persona brief, and the response contract. The parent then waits for all five to return before proceeding to synthesis.

Do not issue reviewer calls sequentially. Parallel-batch is what makes the fresh-priors guarantee meaningful; sequential calls let stale anchoring leak across reviewers via the parent's working context.

## Asymptote Honesty

A successful run of converge is not always 5/5 green. A successful run is one that either reaches green or names the structural ceiling honestly. The skill should refuse to over-state convergence: "4 green, 1 red on length, format-bound" is a more truthful report than papering over a real structural constraint to claim full convergence.

The user is using this skill because they want a tight artifact, not because they want a green checkmark. Optimize for the former.

## Examples

**Paper abstract converging in 3 rounds:**

```
Round 1: 3 red (skeptic: overclaim on generalization;
                prose-critic: nominalization in sentence 2;
                cold-reader: jargon "transient mediator" undefined)
         → applied: hedge generalization claim, rewrite sentence 2,
           define "transient mediator" inline.
Round 2: 2 red (skeptic: still slightly overclaims; devil's-advocate: novelty
                framing weak)
         → applied: further hedge + add one comparison clause.
Round 3: 0 red. 5/5 green.
Final: -3 words from original. 3 rounds, converged.
```

**README hitting asymptote:**

```
Round 1: 3 red (new-user: install section assumes Python; integrator: no
                example of programmatic API; copywriter: opening sentence
                is buzzwordy)
         → applied: explicit Python pin, add API example, rewrite opening.
Round 2: 2 red (new-user: install still ambiguous on Windows; copywriter:
                opening still weak)
         → applied: Windows note, third opening rewrite.
Round 3: 1 red (copywriter: opening still weak — "the opening cannot do
                both 'sell' and 'orient'; you have to pick").
         Asymptote detected: same axis flagged 3 rounds, fix would require
         restructuring the README (sell-then-orient = two sections, not one).
         Stopping with 4/5 green and surfacing the structural choice.
Final: user must decide one-section vs two-section README; converge cannot
       fix this at the prose level.
```

## Notes for the Agent Running This Skill

- You are the parent. You do not critique. You spawn, synthesize, edit, and stop.
- Reviewers do not see each other. You synthesize.
- The user does not babysit each round. Run the full loop autonomously and report the trace at the end, unless the user explicitly asks for round-by-round checkpoints.
- Use the `Agent` tool with `general-purpose` (or specialized) subagent_type, all five calls in one message per round.
- Use `Edit` (not `Write`) to apply round edits to file-backed artifacts. For pasted-text artifacts, hold them in working state and return the final string.
- If the artifact is a file, commit the final converged version with a brief message naming what converged (e.g. `prose: converge abstract — 3 rounds, hedge + jargon`). Do not commit intermediate rounds.
