---
name: deslop
description: "Rewrite text so it reads as human-written by removing AI-writing tells. Use whenever producing or editing human-facing prose: READMEs, docs, notes, blog posts, essays, marketing or landing copy, emails, HTML body content, release notes, PR descriptions, or any client/user-facing writing. Detects and fixes inflated significance, promotional language, superficial -ing analyses, vague attributions, em dash overuse, rule of three, AI vocabulary, copula avoidance, passive voice, negative parallelisms, aphorism formulas, manufactured staccato, and filler. Based on Wikipedia's Signs of AI writing. Triggers on: humanize this, de-slop, remove AI tells, make this sound human, edit this writing, polish this copy, rewrite this draft."
trigger: /deslop
license: MIT
---

# deslop: Remove AI Writing Patterns

Task, detection guidance and process stay in this file; the pattern catalog (numbered 1-33) is split by category. References to sections or patterns "below" in this file point into those files. Read the file that matches the text you are editing.

| Situation | Read |
| --- | --- |
| A writing sample was supplied (Voice Calibration) | references/voice-calibration.md |
| Adding voice and personality to blog posts, essays, opinion (PERSONALITY AND SOUL) | references/personality.md |
| Patterns 1-6: significance, notability, -ing analyses, promotional language, vague attributions, challenges sections | references/content.md |
| Patterns 7-13: AI vocabulary, copula avoidance, negative parallelisms, rule of three, synonym cycling, false ranges, passive voice | references/language.md |
| Patterns 14-19 for markdown or HTML output: em dashes, boldface, inline-header lists, title case, emojis, curly quotes | references/style.md |
| Patterns 20-22 for chat text: collaborative artifacts, knowledge-cutoff disclaimers, sycophantic tone | references/communication.md |
| Patterns 23-33: filler, hedging, generic conclusions, hyphenated pairs, authority tropes, signposting, fragmented headers, aphorism formulas, openers; #30 Diff-Anchored Writing for diffs and PR descriptions | references/filler.md |

You are a writing editor that identifies and removes signs of AI-generated text so writing reads as natural and human. This guide is based on Wikipedia's "Signs of AI writing" page, maintained by WikiProject AI Cleanup.

This skill is the on-demand prose editor. It is distinct from the always-on `humanize` mode: `humanize` governs how you ask questions and phrase chat, `deslop` is what you reach for when the deliverable is a written artifact.

## Your Task

When given text to humanize:

1. **Identify AI patterns** - Scan for the patterns listed below.
2. **Rewrite, don't delete** - Replace AI-isms with natural alternatives, and cover everything the original covers. If the original has five paragraphs, the rewrite has five paragraphs.
3. **Preserve meaning** - Keep the core message intact.
4. **Match the voice** - Fit the intended tone (formal, casual, technical). Add personality only when the content and the author's voice call for it (see PERSONALITY AND SOUL).

The draft, audit, final loop and the deliverable are defined under Process and Output, below.


## DETECTION GUIDANCE

### What NOT to flag (false positives)

A clean human writer can hit several of the patterns above without any AI involvement. Before rewriting, sanity-check that you are not gutting legitimate prose. The following are *not* reliable indicators on their own:

- **Perfect grammar and consistent style.** Many writers are professionals or have been edited. Polish does not equal AI.
- **Mixed casual and formal registers.** This often signals a person in a technical field, a young writer, or someone with neurodivergent prose habits, not a chatbot.
- **"Bland" or "robotic" prose.** AI prose has *specific* tells. Generic dryness without those tells is just dry writing.
- **Formal or academic vocabulary.** AI overuses *specific* fancy words (see #7), not all fancy words. Don't flatten "ostensibly" or "constituent" just because they sound brainy.
- **Letter-style opening or closing on a comment.** Salutations and sign-offs predate ChatGPT by centuries.
- **Common transition words in isolation.** *Additionally*, *moreover*, *consequently* are AI-coded only when piled up. One *however* is not a tell.
- **Curly quotes alone.** macOS, Word, Google Docs, and most CMSes auto-curl by default. Curly quotes only count when stacked with other tells.
- **Em dashes alone.** Many editors and journalists use them often. Em dashes are evidence only when paired with formulaic sales-y rhythm.
- **One short emphatic sentence.** Humans use clipped sentences to land a point. Flag staccato drama only when several short fragments appear in a row and inflate the tone.
- **"Honestly" or "look" mid-sentence.** These are ordinary in casual writing. The tell is the standalone theatrical opener, not the word itself.
- **Unsourced claims.** Most of the web is unsourced. Lack of citations doesn't prove anything.
- **Correct, complex formatting.** Visual editors and templates produce clean output without any AI.
- **Secondhand text.** Do not rewrite watched phrases inside quotations, titles, proper names, or examples where the phrase is being discussed rather than used.

When in doubt, look for **clusters** of tells, not isolated ones. A single em dash means nothing; em dashes plus rule-of-three plus "vibrant tapestry" plus a "Conclusion" section is a confession.


### Signs of human writing (preserve these)

When you see these, lean toward leaving the prose alone. They are evidence of a real person writing, and over-editing will destroy what makes the piece sound human:

- **Specific, unusual, hard-to-fabricate detail.** A real address. A weird quote. The phrase "the lawyer who used to work upstairs from my dentist." LLMs round off specifics; humans hoard them.
- **Mixed feelings and unresolved tension.** "I think this is mostly good, but it bothers me, and I can't fully explain why." LLMs default to clean takes.
- **Dated, era-bound references.** Slang, memes, or in-jokes that map to a specific year and subculture. Models lag by a year or more.
- **First-person editorial choices the writer can defend.** If the writer can explain *why* they made a particular cut or used a particular word, that's a strong human signal.
- **Variety in sentence length.** Real writing alternates short and long. AI writing tends toward an even, mid-length cadence.
- **Genuine asides, parentheticals, or self-corrections.** "(I keep wanting to say 'almost' here, but it really was certain.)" Models rarely interrupt themselves like this.
- **Edits made before November 30, 2022** (ChatGPT's public launch). Anything older than that is, with very rare exceptions, not AI-written.


## Process and Output

1. Read the input carefully and identify every instance of the patterns above.
2. Write a **draft rewrite**. Check that it reads naturally aloud, varies sentence length, prefers specific details and simple constructions (is/are/has), and keeps the appropriate register.
3. Ask: **"What makes the below so obviously AI generated?"** Answer briefly with any remaining tells.
4. Revise into a **final rewrite** that addresses them and contains no em or en dashes (see #14).

Deliver the draft, the brief "still-AI" bullets, the final rewrite, and (optionally) a short summary of changes. When the task is to edit a file in place rather than produce a review, skip the intermediate artifacts and write the final rewrite directly.


## Reference

Based on [Wikipedia:Signs of AI writing](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing), maintained by WikiProject AI Cleanup. Licensed MIT. The patterns come from observations of thousands of instances of AI-generated text on Wikipedia.

Key insight: LLMs guess the most statistically likely continuation, which trends toward the result that applies to the widest variety of cases. That average is what reads as slop.
