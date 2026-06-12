# QA checklist

Run every rendered image through this before saving. A "must pass" miss means regenerate
or edit. A fail signal means the same.

## Must pass
- [ ] 16:9 horizontal.
- [ ] Clean white background: no texture, gradient, shadow, or off-white tone.
- [ ] The crow is present.
- [ ] The crow performs the core action (passes the removal test in `character.md`).
- [ ] Fresh metaphor, not a recycled earlier composition.
- [ ] Reads as strange-but-legible, not generic.
- [ ] Subject is no more than ~60% of the canvas.
- [ ] One core structure only.
- [ ] Labels are sparse, short, English, legible.
- [ ] Orange only on the main path or arrows.
- [ ] Red only on a warning, problem, or key result.
- [ ] Blue only on a secondary note or system state.

## Fail signals (fix and regenerate)
- [ ] A title in the top-left corner.
- [ ] The crow looks like a cute cartoon, emoji, or mascot poster.
- [ ] Reads as a PPT slide, course slide, or formal flowchart.
- [ ] Too many elements, arrows, or nodes.
- [ ] Labels became multi-sentence explanation blocks.
- [ ] Background has texture, shadow, gradient, or a non-white tone.
- [ ] Real UI chrome or a screenshot look.
- [ ] Garbled or misspelled annotation text.
- [ ] No metaphor, the image is purely a diagram.
- [ ] Composition too close to an earlier image in the set.

## The one-second test
First reaction is "that's a bit strange", then within a second the structure is clear. If
it reads like a tutorial page instead of a whiteboard sketch, it fails.
