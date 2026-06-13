---
name: crow-illustrations
description: >
  Turn an article, post, or single concept into 4-8 deadpan hand-drawn 16:9
  explanatory illustrations starring a recurring crow that performs the idea.
  White background, sparse black line art, a few short red/orange/blue handwritten
  labels. One image explains exactly one structure, action, or metaphor. Use when
  the user wants article illustrations, explanatory figures, a hand-drawn diagram
  with a character, or a shot list for illustrating writing. Triggers on:
  "illustrate this", "make illustrations", "article illustration", "explanatory
  figure", "hand-drawn diagram", "crow illustration", "shot list for illustrations".
---

# Crow Illustrations

Turn writing into memorable hand-drawn explanatory pictures. Each picture takes one
cognitive anchor from the text (a judgment, a before/after, a loop, a failure mode, a
metaphor) and draws it as a deadpan whiteboard sketch where a recurring crow performs
the core action.

This is not a general illustration prompt, a PPT infographic generator, or a flowchart
tool. The goal is one strange-but-legible picture per idea.

## When to use

- Someone wrote an article, blog post, README, or thread and wants inline figures.
- A single concept needs one explanatory picture.
- The user wants a shot list (illustration plan) before any rendering.

## When not to use

- Commercial illustration, brand key visuals, or polished flat art.
- Formal architecture diagrams, dense flowcharts, or course slides.
- Cute mascots, stickers, or children's art.
- Cramming long body text into one image.

## The character

Every picture stars the same crow (working name Kaag): a solid black silhouette, two
white dot eyes, a short beak, thin twig legs, deadpan. The crow must perform the
picture's core action, not stand beside it as decoration. Full spec and the removal
test live in `references/character.md`.

## Workflow

1. Digest the source. Pull the core claim and the cognitive anchors: judgments,
   before/after turns, input/output loops, branch points, failure modes, role or state
   changes. (`references/style-dna.md` sets the visual bar.)
2. Build a shot list. 4-8 briefs (1-3 for short pieces, cap at 9). Each brief carries
   placement, topic, core meaning, structure type, what the crow does, suggested
   elements, suggested English labels. This is strategy, no images yet.
3. Pick a structure type per shot from `references/composition-patterns.md`, then
   invent a fresh low-tech physical metaphor for this specific content. Do not reuse a
   metaphor from an earlier shot or from the examples.
4. Fill the prompt template (`references/prompt-template.md`) for one shot.
5. Render one image per shot (see Rendering). Never composite multiple shots into one
   picture.
6. Run `references/qa-checklist.md`. On a fail, either edit (remove an accidental
   title) or regenerate with a revised prompt.
7. Save PNGs to `assets/<article-slug>-illustrations/` as `01-topic.png`,
   `02-topic.png`, and so on. Do not overwrite existing assets without being asked.

## Rendering

Run the bundled script once per shot. It has two backends:

- **Local ComfyUI + Z-Image-Turbo (default).** Renders on your own GPU box, no API key, no cost:

      uv run scripts/generate.py --prompt-file shot01.txt --out assets/<slug>/01-topic.png

  It injects the prompt into the bundled `scripts/z-image-workflow.json` (Z-Image-Turbo, 8
  steps, cfg 1), POSTs it to ComfyUI, polls for the result, and saves the PNG. Point it at
  your server with `--comfyui-url` or `CROW_COMFYUI_URL` (default `http://10.0.0.10:8188`).
  Size is 16:9 `1536x864`; override with `--size WIDTHxHEIGHT` (keep both divisible by 16).

- **OpenAI `gpt-image-1`** (`--backend openai`, or set `CROW_BACKEND=openai`). Stronger at
  the deadpan line-art look and at legible labels, but needs a key:

      OPENAI_API_KEY=... uv run scripts/generate.py --backend openai \
        --prompt-file shot01.txt --out assets/<slug>/01-topic.png

  Size `1536x1024` (closest landscape; true 16:9 `1536x864` needs `gpt-image-2`). Use
  `--edit-image <png>` with the edit sub-prompt to remove an accidental title or label.

- If your agent has a native image tool (for example Codex's `image_gen`), you can call it
  directly with the filled prompt instead of the script.

Z-Image-Turbo is a diffusion model, so on the local backend expect weaker label legibility
and less character consistency across shots than `gpt-image-1`. The Qwen-3-4B text encoder
handles our long prompts well, so adherence is decent; if labels garble, cut them to 2-3
words or fall back to `--backend openai`.

## Notes

- Shorter labels render more reliably. Prefer 2-6 word handwritten labels.
- If a label comes back garbled, drop labels and regenerate rather than fighting it.
- The example metaphors exist to calibrate line density and restraint, never to copy.
