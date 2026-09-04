---
name: middle-out
description: >
  Opportunity-search method for finding products or applications built on top
  of one fixed, genuinely differentiated capability (a library, algorithm,
  dataset, or piece of infrastructure the user already owns) rather than
  brainstorming generic startup ideas from scratch. Enforces two rules: the
  primitive stays fixed and gets grounded in real evidence before any
  ideation starts, and idea generation is a multi-pass investigative process
  with adversarial filtering, never a single prompt expected to return a
  finished answer. Use when the user wants to find business, product, or
  monetization ideas for something they've already built. Triggers on:
  "what could I build with", "product ideas for", "monetize this", "bring in
  money with", "enterprise ideas for", "b2c ideas for", "find applications
  for", "middle-out".
trigger: /middle-out
---

# /middle-out

Opportunity-search method for one fixed primitive, named after two references
worth keeping in mind while running it. Pied Piper's compression algorithm
was one core asset reused across many products, and Tony Stark still had to
model navigation math himself with JARVIS: knowledge and tools do not replace
the iteration, and no one-shot "invent me a time machine" prompt exists.

## The Two Rules

1. **The primitive is fixed, not up for debate.** Before any idea generation,
   name the exact capability being leveraged: a library, an algorithm, a
   dataset, infrastructure, a skill. If it isn't clear yet, stop and
   establish it first. Ideas get evaluated by whether they need *this
   specific* primitive's edge, not by whether they sound good in general. An
   idea any commodity tool could satisfy is not a finding, it's noise.

2. **No one-shot.** A single prompt asking "give me ideas" returns the
   median of the training corpus, because that prompt shape is one of the
   most represented in it. The value comes from grounding, multi-angle
   generation, and adversarial filtering across several passes, not from a
   smarter phrasing of the same one-shot ask.

## Process

### Phase 0: Name the primitive
State plainly what is fixed, the specific capability, not the project name.
If the user hasn't said what makes it genuinely differentiated yet, ask
before proceeding, since ideation on a vague primitive just produces vague
ideas. Also establish the operator's actual starting resources when known
(team size, funding status, whether raising money later is on the table),
since Phase 3's fit check depends on it and defaults to "assume no funding
yet" if the user hasn't said otherwise.

### Phase 1: Ground it in evidence
Before generating a single idea, pull real facts about the primitive by
reading the actual code, docs, and benchmarks rather than relying on a
generic mental model of "a thing like this." Delegate the reading to a
subagent or fork when it's read-heavy, so the grounding comes from evidence
instead of priors. Note explicitly what the primitive can't do yet, because
the edge of a capability filters ideas just as well as the capability
itself.

### Phase 2: Generate wide, then kill hard
Run several independent generation passes from different angles (enterprise
versus consumer, adjacent markets, unconventional users), and parallel
forks or agents work well here since the passes shouldn't contaminate each
other. Then kill fast: for every surviving idea, check whether it already
exists by searching first instead of guessing, and whether it's the generic
median answer any LLM would give for "ideas for X." Cut anything that
doesn't specifically need the primitive from Phase 0.

### Phase 3: Reality-check the survivors
Four separate questions have to be answered here, and none of them
substitutes for another. Feasibility: what breaks the idea against the
primitive's actual limits from Phase 1. Market size now: roughly how many
buyers exist at the target size today, what they'd realistically pay, and
how long the sales cycle to a first paying customer runs. Ceiling: how big
this could realistically get if it fully succeeds, the total addressable
scale, not the cautious near-term number. Fit: what this candidate is
achievable to *without* assuming resources the operator doesn't have, given
the starting resources from Phase 0, and what specifically about the
operator (existing access, credibility, an asset, a relationship) this
candidate leverages versus a generic competitor with the same primitive.
"Needs nothing the primitive doesn't already ship" answers feasibility, not
market size, ceiling, or fit, and a candidate that's easiest to build or
fastest to first revenue is not automatically the one worth pursuing.
Report a rough number for buyer count, price point, sales-cycle length, and
ceiling even when the estimate is loose, plus the specific milestone
reachable on the operator's actual starting resources before any
fundraising, treated as the real near-term ceiling; the bigger funded-scale
number is upside once that milestone is proven, not the pitch itself. Flag
any candidate whose ceiling is small, whose path assumes resources the
operator doesn't have, or that any well-funded competitor could pursue just
as easily. Keep the modeling lightweight: just enough to tell a real
opportunity from a plausible-sounding one, not a full business plan.

### Phase 4: Converge, don't menu
Present the strongest one to three candidates with the specific evidence
behind each, matching the user's standing preference for one recommendation
over a spread of options. Rank by the achievable-without-funding path
first, not the theoretical funded ceiling: the goal is the best idea this
operator can actually start on and prove with their stated resources, with
the bigger ceiling reported as real upside once that milestone lands, not
as the sort key itself. A candidate whose only credible path assumes
funding, a team, or years the operator doesn't have loses to a smaller
candidate that's genuinely startable now, unless the user says otherwise.
Feasibility gaps and slow sales cycles are risk to name and weigh, not
automatic disqualifiers against a candidate with a genuinely larger
ceiling; only cut a high-ceiling candidate if the feasibility gap is a real
wall (the primitive would need a capability it fundamentally cannot get
to), not just more work than a smaller candidate needs. If genuinely torn
between two, say so and pick a current best guess rather than punting the
choice back.

## Interaction with Other Modes

- **With humanize:** phase transitions and any clarifying question still go
  through one-question-at-a-time structured choices.
- **With ownit:** no hand-waving on Phase 3 validation. "Sounds plausible"
  is not a substitute for actually checking prior art and market signal.
- **Handoff to /converge:** once a candidate is picked, /converge is the
  right tool for hardening it into a spec, pitch, or plan through further
  review rounds. /middle-out finds the candidate, /converge polishes it.

## Activation

- `/middle-out` starts the process fresh.
- It also triggers on natural language matching the description above,
  without the user having to type the slash command.
