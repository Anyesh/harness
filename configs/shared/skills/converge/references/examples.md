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
