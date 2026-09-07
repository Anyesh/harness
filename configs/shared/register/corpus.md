# Register corpus

One question, applied to every sentence:

**Does this sentence exist to say something, or to produce an effect?**

Sentences that exist to produce an effect get flagged. The effect is usually interest (a hook), organisation (an enumeration), emphasis (an intensifier or a tacked-on clause), or profundity (a slogan or a balanced contrast).

The entries below calibrate that question. They are not the rule. A construction that avoids every one of them can still fail the question, and a construction that matches one can still pass when it carries meaning.

Target register: one engineer explaining something to another at a desk.

Confidence counts how many times a pattern has been confirmed. At 3 or above it is settled and gets reported without asking. At 1 or 2 it is provisional and becomes a question. At 0 the entry moves to Keeps.

## Patterns

### hook or promise
effect: interest
confidence: 2
rejected: "By the end of this you should be able to look at an answer that went wrong and work out which one it was."
accepted: "All three have a cause you can go and find."
note: also covers show-of-hands beats, pauses for effect, and telling the audience how much to care ("This is probably the most useful slide here"). A plain opening for comparison: "So this is LLM 101, for people who are in Cursor and Glean all day but haven't had a reason to look at what's going on underneath."

### spoken enumeration
effect: organisation
confidence: 1
rejected: "Four parts: what the model does, what Cursor and Glean build on top of it, why context costs you, what people get wrong."
accepted: "We start with what the model does when it answers you. Then the stuff Cursor and Glean build around it, which turns out to be most of it."

### intensifier
effect: emphasis
confidence: 2
rejected: "The first part is genuinely basic."
accepted: "The first bit is basic."
note: actually, genuinely, really, truly, literally, filler "just", and "every single" where "every" does the work.

### slogan in the title slot
effect: profundity
confidence: 2
rejected: "Rules files are the note taped to the monitor"
accepted: "Rules files get pasted in on every request"
note: the metaphor itself is fine, it belongs in the body where it explains a mechanism. Also covers thesis lines in body copy, such as "The window is the only lever you have over what the model does" sitting under a heading that already made the point.

### tacked-on clause for emphasis
effect: emphasis
confidence: 4
rejected: "The model guesses the next token, and that's all it does"
accepted: "The model guesses the next token"

### negative parallelism
effect: profundity
confidence: 2
rejected: "Nearly everything people get wrong is about the wrapper, not the model"
accepted: "Most misconceptions are about the wrapper"

### balanced two-part contrast
effect: profundity
confidence: 1
rejected: "A metaphor that explains a mechanism is doing work. A metaphor sitting in the title slot is decoration."
accepted: say the one thing you mean and stop.

### content-free labels
effect: organisation
confidence: 1
rejected: agenda lines reading "what the model does", "what Cursor and Glean add"
accepted: "The model guesses the next token", "The rest of Cursor and Glean is text in a window"
note: a slide is what the audience stares at while the speaker talks, so every line has to carry something they can hold. Topic labels waste that.

### signposting frame
effect: emphasis
confidence: 4
rejected: "What I want you to take from this is what isn't happening."
accepted: delete the frame and let the next sentence stand.
note: also "The bit worth noticing is that...", which turned into a tic when used twice in one document.

## Keeps

Constructions that look like tells but were accepted. Do not flag these.

- The "Think of it as" analogy boxes. A metaphor that explains a mechanism to a non-expert audience earns its place. Only a metaphor sitting in a title is decoration.
- "and that's the whole mechanism" after describing rules files. It tells the reader to stop looking for something cleverer.
- "@mention the file, not the folder" and "should be a skill, not an always-on rule". The contrast is the instruction.
- "Put that in a loop where the model picks its own next step, and that's all agentic means." The plainest way to say the point.
- Ordinary connected speech such as "and it's less exotic than it sounds". Flag a flourish, not a conjunction.

## What the reviewer returns

For each location, either nothing or the specific sentences that exist to produce an effect, with the effect named and a plainer replacement. Say nothing about text that passes. Rank by confidence. Report register only, never content, accuracy or structure. A short honest report is the correct output when the text is clean.
