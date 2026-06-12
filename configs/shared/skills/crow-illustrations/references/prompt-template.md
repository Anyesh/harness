# Prompt template

Fill one of these per shot and hand it to the image tool (native `image_gen`) or to
`scripts/generate.py` via `--prompt-file`. Replace every `{brace}`. Keep the character
block verbatim so the crow stays on-model across shots.

## Generation prompt

    Generate one standalone 16:9 horizontal article illustration.

    Visual DNA:
    Pure white background. Minimalist black hand-drawn line art, slightly wobbly pen
    lines. Lots of empty white space. A few short English handwritten annotations in
    red, orange, or blue. Deadpan whiteboard-sketch feeling. No gradients, no shadows, no
    paper texture, no commercial vector style, no PPT infographic look, no cute mascot
    poster, no children's illustration, no realistic UI.

    Recurring character (keep consistent across all images):
    A small crow, solid black fill, two white dot eyes, a short triangular beak, two thin
    twig legs. Deadpan and focused, never cute, no facial expression beyond the dot eyes.
    The crow must perform the core action of the scene, not stand beside it.

    Theme:
    {one-line topic of this image}

    Structure type:
    {Workflow | System cutaway | Before/after | Role/state | Concept metaphor | Layered
    method | Map/route | Mini comic}

    Core idea:
    {the single thing this image must communicate}

    Composition:
    {where the crow is, what it is doing, the main objects, how information flows}

    Suggested elements:
    {element 1} / {element 2} / {element 3} / {element 4}

    Annotation labels (English, 2-6 words each):
    {label 1} / {label 2} / {label 3} / {optional label 4}

    Color use:
    Black for line art and the crow. Orange for the main flow or arrows. Red only for a
    warning, problem, or key result. Blue only for a secondary note.

    Constraints:
    One image, one core structure. Main subject 40-60% of the canvas, at least 35% blank
    white space. At most 5-8 short handwritten labels. No title in the top-left corner.
    Do not write the structure type on the image. Not a formal diagram, course slide, or
    dense explainer. Invent a fresh visual metaphor for this content, do not reuse earlier
    compositions. Clear but not instructional, interesting but not childish, strange but
    clean.

## Edit prompt (remove an accidental title or garbled label)

    Edit this image. Remove only the handwritten text "{text to remove}" and its
    underline. Fill with matching clean white background. Preserve everything else
    exactly: the crow, the labels, the paths, the line style, the composition, the aspect
    ratio.

## Iteration prompt (picture came back generic or decorative)

    Regenerate with the same core meaning, but make the crow central to the action: the
    crow should be doing the strange work that explains the idea, not standing beside the
    diagram. Keep it sparse, hand-drawn, deadpan, not cute.
