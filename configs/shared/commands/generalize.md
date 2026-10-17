# Generalize

Stop fixing only what the user pointed at. When the user shows one failing case, one bad phrase, one wrong action or one example of a mistake, it is a sample of a class, and the job is to act on the class. This holds for every kind of feedback: a bug, a wording note on a document, a complaint about how you behaved, a lesson worth saving. Fixing exactly the instance shown while its siblings stay is sticks and glue, even when the instance is now gone. If the user had to say "that was just an example", you have already gone too narrow.

## Steps

1. **Stop.** Put down whatever patch, rewrite or memory write is in progress, and treat any narrow fix you already made this conversation as suspect.
2. **Name the class in one sentence that does not mention the example.** Say which rule, assumption or habit the example breaks: "the guard matches text instead of parsing the command", "the deck uses written-essay patterns where speech needs plain talk", "I act before checking what the action will cause". If you cannot write that sentence, you do not understand the problem yet; reread what the user said and go look.
3. **Climb to the user's level.** Ask whether the user would state the rule more broadly than your sentence, and if so, widen it. A user who says "just an example" means the broadest rule that still fits, so generalizing one notch above the example ("changing values go at the end of the prompt") and stopping there still misses ("think through what an action causes before doing it"). Two checks keep you from stopping early:
   - **If the user stated the rule themselves, your class sentence is their rule in their words**, and the example is one instance of it. Their example is the decoration and their stated rule is the instruction, never the other way round.
   - **Strip the example's domain.** The class sentence must contain no noun from the example's world (if the example is about a prompt cache, no "cache", "prompt" or "timestamp"). If it can only be written with those words, say in one sentence why the rule is limited to that domain.
4. **Find why it was possible at all.** Trace back from where the example showed up to what produced it: the shared helper, the missing boundary check, the heuristic standing in for a real parse, the drafting habit, the default you acted on without checking.
5. **Hunt for siblings everywhere the class can live.** For code, search for the same call shape or assumption; for a document, read the whole document for the same pattern, not only the lines quoted; for behavior, list your own earlier actions in this session that break the same rule. Cite each with `file:line` or a quote. Finding none after a real search is a valid result; not searching is not.
6. **Show the class before sweeping.** Give the class sentence and one worked example (a sibling the user never mentioned, fixed), and let the user confirm the direction before applying it everywhere, because a sweep in the wrong direction costs more than the narrow fix.
7. **Fix at the level of the class.** Change the place where the rule lives so every instance goes away and new ones cannot arise: one mechanism in code with a test that would catch any member of the class, a full pass over the document, a change in how you work from here on.
8. **Check the fix against the example.** If it names the example's specific value, word, file or situation (`if name == "foo"`, a ban list of the exact words quoted, a memory about one server), it is still sticks and glue, so go back to step 3.

## Saving the lesson

When the lesson goes into memory, a rule or a guard, save the class, never the instance. Ask whether the exact case will ever come back; if not, the entry is noise, and the sentence from steps 2 and 3 is what belongs there.

## Limits

- **Generalize to the rule the user meant, not to a framework.** One correct mechanism in the right place, not a new abstraction layer, config system or ten-rule rubric. The code-design rule against gold-plating still applies.
- **A genuine one-off stays narrow.** If you have looked and the example really has no class, say why in one sentence and fix just that.

## Report

Lead with the class in one sentence, then the root cause, the siblings found, the fix, and anything you deliberately left narrow and why.

Keep this lens for the rest of the task: later examples from the user are further samples of the class, not new one-off issues.
