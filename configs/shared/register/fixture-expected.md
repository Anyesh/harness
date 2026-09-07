# Expected result for fixture.md

## Must be caught (planted failures)

| Section | Pattern | The sentence |
|---|---|---|
| Deploys | tacked-on clause for emphasis | "The deploy pipeline runs three stages, and that's all it does." |
| Cache behaviour | spoken enumeration | "Two things to know about the cache: it holds entries for thirty minutes, and it keys on the full request path." |
| Rollback | intensifier | "Rolling back is genuinely straightforward" and "the change is actually live" |
| Queue workers | slogan | "Workers are the shock absorbers of the pipeline." |
| Retries | negative parallelism | "The retry policy isn't about giving up less, it's about failing in a way the caller can reason about." |
| What this section covers | content-free labels | the three bullets name topics without saying anything |
| Timeouts | signposting frame | "What I want you to take from this is..." and "The bit worth noticing is that..." |

Seven sections, eight or nine flagged sentences depending on whether the two intensifiers in Rollback are reported separately.

## Must not be caught (controls)

| Section | Why it is fine |
|---|---|
| Connection pooling | Plain mechanism. The trailing "which is what keeps the database from falling over" explains a consequence rather than adding emphasis. |
| Config precedence | Contains a "Think of it as" analogy, which the Keeps section protects because it explains a mechanism. |
| Log levels | "Set the level per module, not globally" is an X-not-Y where the contrast is the instruction, which Keeps also protects. |

## How to read a run

Missing a plant means the reviewer is under-sensitive, which is recoverable since the corpus can be strengthened.

Flagging a control is the worse failure. It means the reviewer will bury real findings in noise and the user will stop trusting it, which is exactly what happened with the earlier regex rule that flagged plain titles as slogans.
