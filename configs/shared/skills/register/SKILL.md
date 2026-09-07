---
name: register
description: "Review a document against the user's own corpus of rejected and accepted phrasings, then extend that corpus where the reviewer was unsure. Checks writing register only: whether each sentence exists to say something or to produce an effect. Not a content, accuracy or structure review. Use when the user asks to check how something reads, whether it sounds like them, or whether it reads as LLM-written. Triggers on: check the register, does this sound like me, review how this reads, run register on this."
trigger: /register
license: MIT
---

# register

Review one named document for writing register. The user invokes this deliberately on a specific file. Never run it unasked.

The corpus of the user's own rejected and accepted phrasings lives in the harness repo, not in deployed config, so that every pair it learns shows up as a git diff and a bad lesson can be reverted.

## Locate the corpus

```
REG="${HARNESS_ROOT:-$(grep -E '^DATA_ROOT=' ~/.harness.env 2>/dev/null | cut -d= -f2)/harness}/configs/shared/register"
[ -d "$REG" ] || REG=/mnt/data/harness/configs/shared/register
```

`$REG` holds `corpus.md`, `extract.py` and `corpus.py`.

## Run

**1. Build the prompt.** `extract.py` pulls reviewable text out of the target and prepends the corpus. It handles HTML (slide sections, or the body) and markdown (split on headings).

```
uv run --no-project python "$REG/extract.py" <path> [more paths]
```

Write the output to a file in your scratchpad. Do not paste it into your own context, it is large and you do not need to read it.

**2. Spawn a fresh reviewer.** Use the Agent tool with `subagent_type: "general-purpose"`. Fresh context is the whole point: applying the rule while generating competes with holding the content together, and a reviewer that only reviews does not have that problem. Never review the document yourself, and never use a fork.

Tell the agent to read the prompt file you wrote and follow the corpus in it, and add these constraints:

- Report only sentences that fail. Say nothing about text that passes, and do not summarise what the document is about.
- Give the location, the exact sentence, which effect it reaches for, and a plainer replacement.
- Respect the Keeps section. Disputing a keep is allowed once, at the end, under its own heading with reasoning.
- Rank findings by confidence, most confident first.
- If there are fewer than five real failures, say so plainly rather than padding. A short report is correct when the text is clean.
- Do not edit any files.

**3. Sort what comes back.** Match each finding against the corpus entries.

- Matches an entry at confidence 3 or above: settled. Report these as a list for the user to accept or skip in bulk. Do not ask about them individually.
- Matches an entry at confidence 1 or 2, or matches nothing: provisional. These become the questions.

**4. Ask only about the provisional ones**, one at a time, using AskUserQuestion. Give the sentence, the effect it reaches for, and your suggested replacement. The user is deciding whether this is a rule of theirs, not whether the rewrite is nice.

**5. Write the answers back.**

```
uv run --no-project python "$REG/corpus.py" --confirm "<entry name>"
uv run --no-project python "$REG/corpus.py" --overrule "<entry name>"
uv run --no-project python "$REG/corpus.py" --add "<name>" --effect <interest|organisation|emphasis|profundity> \
    --rejected "<the sentence>" --accepted "<the replacement>" [--note "<when this applies>"]
```

Confirming increments. Overruling decrements, and at zero the entry moves into Keeps so the reviewer stops raising it. A finding that matches no existing entry and the user confirms becomes a new entry at confidence 1.

`corpus.py --show` lists every entry with its confidence and whether it is settled.

**6. Apply the accepted findings** to the document, then tell the user what changed in the corpus. They should be able to see the learning as a diff:

```
git -C "${REG%/configs/*}" diff configs/shared/register/corpus.md
```

## Judgement this skill cannot make

Whether a construction carries meaning or is decoration depends on what the author meant. When a finding is arguable, put it to the user rather than deciding. The corpus grows by their answers, so guessing on their behalf corrupts the thing that makes this work at all.

## Known limits, state these if asked

The corpus was authored in one sitting. Pairs accumulated one at a time may overlap or contradict, and nobody has seen what it reads like past twenty entries. The confidence thresholds assume patterns recur often enough to accumulate, which occasional use may not deliver. And a language model's self-reported confidence is not calibrated, so the banding is a heuristic rather than a measurement.
