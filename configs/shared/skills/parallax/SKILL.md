---
name: parallax
description: "Design and build parallax and scroll-driven pages that read as depth and craft rather than gimmick. Covers layered depth systems (speed ratios, layer budgets), the pure-CSS perspective technique, native scroll-driven animations (animation-timeline: scroll/view), GSAP ScrollTrigger and Lenis, sticky scrollytelling, compositor-only performance rules, prefers-reduced-motion fallbacks, mobile strategy, and copy rules for scroll pages. Use whenever building, redesigning, or polishing a landing page, marketing page, homepage, hero section, product or launch page, campaign page, or portfolio, even if the user did not say the word parallax. Triggers on: landing page, marketing page, homepage, hero section, parallax, scroll animation, scroll effects, scrollytelling, product launch page, promo page."
---

# Parallax and Scroll-Driven Pages

Parallax is a depth cue, not a decoration. Layers that move at different speeds tell the eye there is a world behind the page, and that only works when the motion is subtle, physically consistent, and rare. The 2013 failure mode (every section sliding, spinning, and fading at once) died for a reason; the modern form is one or two committed depth moments that the rest of the page stays calm around.

This skill owns the scroll dimension. If a broader design skill is active (impeccable, frontend-design), its rules on color, type, and register still govern; apply this skill on top for anything that moves with scroll.

## When parallax earns its place

Use it when the page has a spatial or narrative story: a hero that establishes atmosphere, a product that benefits from being walked through step by step, a brand where craft is the message. Skip it when the page is dense with information the visitor came to extract (docs, pricing tables, dashboards), when the content is mostly text, or when you cannot keep it smooth on mid-range hardware. A static page that loads fast beats a janky deep one every time.

Budget the motion. One hero depth treatment plus at most one scrollytelling section per page is the default; a third scroll effect needs a reason you can say out loud. Fade-and-rise reveals on every section are the current AI tell, not choreography.

## The depth system

Treat layers like a stage set, farthest moves least:

- **Background** (sky, texture, ambient shapes): 0.2x to 0.4x of scroll speed.
- **Midground** (supporting imagery, large decorative elements): 0.6x to 0.8x.
- **Content** (headline, copy, CTA): always 1.0x. Text rides with native scroll so reading is never disturbed.
- **Foreground accents** (small overlapping details that slide slightly faster than 1.0x): optional, use sparingly, they sell the depth more than any background does.

Keep the differential between adjacent layers at or below 0.5x; larger gaps read as detachment and can trigger motion discomfort. Two to four layers total. Depth must stay consistent within a scene: an element cannot be behind in one section and in front in the next without a visible transition.

## Choosing the technique

Work down this list and stop at the first that fits; each step down adds capability and cost.

**1. Pure CSS perspective (no JS, works everywhere).** The scroll container gets `perspective: 1px; overflow-y: auto`, layers get `transform: translateZ(-Npx) scale(S)` with `S = 1 + N / perspective`. Depth maps to speed: translateZ(-1px) scale(2) moves at 0.5x, -2px scale(3) at 0.33x, -3px scale(4) at 0.25x. Constraints to respect, because the browser enforces them: the perspective ancestor becomes the containing block, so `position: fixed` descendants break; an intermediate element without `transform-style: preserve-3d` flattens the effect; the page must scroll inside that container, not the body. On iOS Safari prefer `position: sticky` compositing inside the container so the effect survives touch scrolling. Two more constraints show up only in practice: content that follows the hero must join the 3D rendering context (`transform: translateZ(0)` on `main`), because the depth sort paints negative-z layers over later siblings and no `z-index` can win that fight; and the scaled layers inflate the container's `scrollWidth` even though the projected paint fits the viewport exactly, so give the container `overflow-x: hidden` and do not treat `scrollWidth` as evidence of visible overflow.

**2. Native scroll-driven animations (CSS only, richer control).** `animation-timeline: scroll()` maps an animation to scroll progress; `view()` maps it to an element's journey through the viewport, with `animation-range: entry 0% cover 50%` style clamping. Shipped in Chrome/Edge (2023) and Safari 26; Firefox stable is still flag-only as of mid-2026, so always gate:

```css
@supports (animation-timeline: scroll()) {
  .hero-bg { animation: drift linear both; animation-timeline: scroll(root); }
}
```

Design so the ungated page is complete and attractive; the timeline is enhancement, never load-bearing layout.

**3. Sticky scrollytelling (pin plus steps).** For walkthroughs: a `position: sticky` graphic pinned inside a tall section, with step text scrolling past and an IntersectionObserver swapping the graphic's state per step. Native sticky does the pinning; JS only flips classes. This is the dominant scrollytelling architecture and needs no library.

**4. GSAP ScrollTrigger, optionally Lenis.** Reach for it only when you need scrubbed multi-step timelines, pinning with sequenced choreography, or scroll-scrubbed video, which native timelines still cannot sequence reliably. GSAP and all its plugins (ScrollTrigger, SplitText, ScrollSmoother) are free since v3.13. Lenis wraps native scroll rather than replacing it, so sticky and anchors keep working; sync with `lenis.on('scroll', ScrollTrigger.update)`. Never adopt a library for an effect one of the levels above already does.

Scrolljacking (overriding scroll distance, speed, or direction to force pacing) is banned at every level. The user's scroll position is theirs.

## Performance rules

- Animate `transform` and `opacity` only; they are the compositor-only properties. Anything that triggers layout or paint (top, height, background-position, box-shadow spread) will jank at scroll speed.
- Never drive continuous effects from scroll event handlers; scroll events are delivered best-effort, not per frame. Native timelines and the perspective technique run on the compositor; if JS must be involved, read scroll position inside a single `requestAnimationFrame` loop.
- `background-attachment: fixed` is banned: iOS Safari does not support it reliably and elsewhere it forces full repaints every frame. Use a transformed layer instead.
- `will-change: transform` only on the few actual moving layers, never sprayed across sections; each promoted layer costs memory.
- `content-visibility: auto` on below-the-fold sections cuts initial render work dramatically and is Baseline.
- Images inside layers: explicit dimensions, `loading="lazy"` below the fold, and oversize background layers by the scale factor so they stay sharp.

## Motion accessibility

Parallax is a named trigger for vestibular disorders and WCAG 2.3.3 expects interaction-triggered motion to be disableable. `prefers-reduced-motion: reduce` support is mandatory, not optional:

```css
@media (prefers-reduced-motion: reduce) {
  .layer { animation: none; transform: none; }
}
```

The reduced page must remain a finished design: layers settle into a composed static layout, opacity-only crossfades may stay, nothing is missing or broken. Build and screenshot this mode, do not just add the media query and hope.

## Mobile

Small screens get less depth, not scaled-down desktop depth: cut to at most two layers, halve translation distances, and prefer the static composition if frame rate drops. Test with touch scrolling, not just wheel emulation, and watch for horizontal overflow from scaled background layers (`overflow-x: clip` on the container plus oversized layers positioned from center).

## Copy and layout on scroll pages

Scroll room is not license for filler. Landing copy stays short: a headline of ten words or fewer that states what the product does, one supporting line, a CTA. Each section earns its viewport height with one idea; if a section's text exceeds roughly 60 words, it is a wall, split it or cut it. No AI-slop patterns: no emoji bullet features, no default three-column feature grid, no "Unlock/Unleash/Elevate/Empower" verbs, no purple-gradient-on-dark default theme. If a deslop or copy-editing skill is available, run the final copy through it.

Text never sits directly on a moving layer without a contrast guarantee: put copy on the 1.0x content layer and back it with a scrim, panel, or gradient that keeps contrast passing at every scroll position, including mid-transition.

## Verify before shipping

Screenshots at rest prove nothing about parallax. Serve the page and drive it:

1. Screenshot at 3 or more scroll offsets (0%, mid, deep) and confirm the layers actually moved at different rates by comparing element positions between frames.
2. Re-run with `prefers-reduced-motion: reduce` emulated and confirm the static composition is complete.
3. Prove horizontal containment by attempting a horizontal scroll (wheel with `deltaX`, or touch pan) and confirming `scrollLeft` stays 0, plus a visual check of the edges. A raw `scrollWidth <= innerWidth` comparison false-positives under the perspective technique because scrollable overflow is computed from pre-projection boxes. Confirm text contrast at mid-scroll positions, not just at section rest points, and hit-test key text with `document.elementFromPoint` to catch layers painting over content.
4. Test a mobile viewport (390px wide) for the reduced layer strategy.

If Playwright or a browser tool is available, do all four in one scripted pass rather than eyeballing single screenshots.
