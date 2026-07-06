# Visual techniques

Concrete, tested recipes. All coordinates assume 1280x720 at 30fps. `t` is seconds.

## Timing primitives

```python
def smooth(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)

def fade(t, t0, t1, edge=0.8):
    if t < t0 or t > t1:
        return 0.0
    return smooth((t - t0) / edge) * smooth((t1 - t) / edge)
```

`fade` is the workhorse: every caption, node, and illustration gets `alpha = fade(t, appear, vanish)`. Overlap fades by a second or two so the film breathes instead of cutting.

## Glow compositing (dark films)

```python
art = Image.new("RGB", (W, H), 0)
# ... draw crisp points/lines/text into art ...
glow = art.filter(ImageFilter.GaussianBlur(7))
frame = ImageChops.add(Image.new("RGB", (W, H), BG),
                       ImageChops.add(glow, art))
```

Brightness is controlled by scaling fill colors, `scale_color(color, alpha)`, since additive drawing has no alpha. Captions are drawn on an RGBA overlay and `alpha_composite`d after the glow so text stays sharp.

## Paper texture

```python
base = np.ones((height, W, 3)) * np.array(PAPER)          # (242, 234, 216)
grain = rng.standard_normal((height, W, 1)) * 3.2
fibers = rng.standard_normal((height // 4, W // 4, 1)) * 4.0
fibers = np.kron(fibers, np.ones((4, 4, 1)))[:height, :W]  # coarse blotches
xs = np.abs(np.arange(W) - W / 2) / (W / 2)
shade = 1 - 0.06 * xs ** 2                                 # side vignette
paper = Image.fromarray(np.clip((base + grain + fibers) * shade[None, :, None],
                                0, 255).astype(np.uint8))
```

Build it once at full page height (`TOP_Y + rows * LINE_H + H`); never regenerate per frame.

## Ink without alpha

```python
def ink_on(bg, ink, strength):
    return tuple(int(i * s + p * (1 - s)) for i, p in zip(ink, bg))
```

Vary `strength` 0.66 to 1.0 per glyph for the uneven typewriter look. 4% of glyphs also get a faint offset double-strike ghost at `strength * 0.35`.

## Event schedule (sync backbone)

Walk the text once, emitting timed events; feed the same list to the audio synth and the frame loop.

```python
events = [{"t": 12.31, "kind": "char", "ch": "a", "x": 431.0, "y": 570, "space": False},
          {"t": 14.90, "kind": "ding", "row": 9},
          {"t": 60.02, "kind": "strike", "x0": 300, "x1": 452, "y": 588}]
```

Timing that feels human: base interval `(1/13.5) * uniform(0.7, 1.6)`; 3% chance of an extra 0.4 to 1.0 s hesitation; +0.30 s after commas, +0.55 s after `.?:`; +0.35 s then a ding event at line end, +0.55 s carriage pause; +0.9 s for blank lines. Track x with `font.getlength(ch)` because display faces like Special Elite are not metrically monospace.

## Scrolling camera

```python
target = max(0.0, min(current_line_y - 330.0, tall_h - H))
scroll += (target - scroll) * 0.06
frame = paper.crop((0, int(scroll), W, int(scroll) + H))
```

## Self-drawing stroke illustrations

A shape is a function of `t` returning a list of polylines in a roughly 100x130 local box, so shapes can animate (bob, steam, twinkle) even while being revealed. Reveal by point budget:

```python
def draw_strokes(d, strokes, frac, ox, oy, scale, color, width=2):
    total = sum(len(s) for s in strokes)
    budget = int(total * min(1.0, frac))
    for stroke in strokes:
        if budget <= 0:
            break
        take = min(len(stroke), budget)
        budget -= take
        if take >= 2:
            d.line([(ox + x * scale, oy + y * scale)
                    for x, y in stroke[:take]], fill=color, width=width,
                   joint="curve")
```

Anchor each illustration to a line of text; trigger at `row_start_time + delay` (about 1 s) with a 2.5 to 3.5 s reveal. Put them in the right margin (x around 1000 when text ends near 910) at about scale 1.0 for a 100-unit shape, ink strength about 0.52 so they sit quieter than the text.

Shape building blocks: `arc_pts(cx, cy, r, a0, a1)` point sampler, parametric heart (`16 sin^3 a`, `13 cos a - 5 cos 2a - 2 cos 3a - cos 4a`, y negated), 5-point star as a 10-vertex polyline, sine-wave water `y + 3.2 * sin(x * 0.14 + 1.8 t)`, steam wisps `x0 + 4.5 * sin(0.22 y + 2.2 t)` rising. For a boat that bobs, rotate hull/mast/sail points around a pivot by `0.06 * sin(1.3 t + 0.7)` and offset y by `2.5 * sin(1.3 t)`.

## Small life

- Dust motes: 30-ish particles, `x = (x0 + t * speed) % (W + 40) - 20`, gentle sine sway in y, radius 1 to 2.4, ink strength 0.04 to 0.11.
- Fresh ink: keep events from the last 0.55 s, overdraw each glyph with `strength = (1 - age) * 0.55` in a darker ink.
- Twinkle: any star or signal glyph gets `0.5 + 0.5 * sin(2.4 t + phase)` on strength or size.
- Cursor: filled rect, visible when `int(t * 2) % 2 == 0`; stop the blink (leave it off) a beat before the final fade.

## Endings

Crossfade worlds with `Image.blend(frame_a, frame_b, mix)` over about 2.5 s. Reuse motifs from earlier scenes at a larger scale in the coda (the margin sailboat becomes the hero crossing a moonlit sea). Global envelope: fade from black over 2 s at the start, to black over 3 to 4 s at the end, via `Image.blend(black, frame, a)`.
