---
name: procedural-film
description: Create short emotional or explanatory films entirely in code, with no stock assets and no video editor. Renders frames procedurally with Pillow and numpy, synthesizes the soundtrack from scratch, and muxes both through ffmpeg in one pass. Covers two visual languages (dark glow-scene films and typed-letter paper films), self-drawing ink illustrations, typewriter mechanics with sound, and a verification loop. Triggers on requests to make a video, animation, film, motion piece, video letter, animated letter, or "what it feels like" video.
---

# Procedural Film

Make a finished .mp4 with sound using only Python (Pillow + numpy), ffmpeg, and a font file. Nothing is downloaded except optionally a font; every pixel and every sample of audio is generated. This works because short films live or die on writing, pacing, and restraint, not on rendering technology.

Three worked examples of this skill are bundled in `references/examples/` (`render.py` for a dark glow film, `letter.py` for a typed letter with sound, `letter_animated.py` for the letter plus self-drawing margin illustrations and a night coda). Read one before writing your own; they are each a single self-contained script.

## Method, in order

1. **Write the film before writing code.** Decide the emotional arc as a list of scenes or stanzas with durations and exact caption text. The words carry the film; the graphics accompany them. A 70 second film wants 5 or 6 scenes; a typed letter wants 30 to 45 short lines. Personal beats generic: use the recipient's name, their projects, their machines, things only they would recognize.
2. **Set up.** `uv venv && uv pip install pillow numpy`. Confirm `which ffmpeg`. Pick fonts with `fc-list` (DejaVu is always present on Linux). For typewriter aesthetics fetch Special Elite: `curl -sL -o SpecialElite.ttf "https://github.com/google/fonts/raw/main/apache/specialelite/SpecialElite-Regular.ttf"`.
3. **One script, one pass.** Build the audio first inside the script, then stream raw RGB frames straight into ffmpeg's stdin. Never write thousands of PNGs. Start from `templates/film_template.py`.
4. **Render, then look.** Extract 5 to 8 frames across the runtime with `ffmpeg -ss T -i out.mp4 -frames:v 1 f.png` and view them with the Read tool. You will catch layout collisions, illegible text, and clustering bugs that the code cannot tell you about. Fix and re-render; a 3 minute 720p film renders in about 2 minutes.
5. **Deliver with a description** of what happens in the film and when, so the recipient knows to watch with sound on.

## Core pipeline (both visual languages)

```python
cmd = ["ffmpeg", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
       "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-", "-i", "score.wav",
       "-c:v", "libx264", "-preset", "medium", "-crf", "18",
       "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k",
       "-shortest", "out.mp4"]
proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.DEVNULL)
for i in range(int(DURATION * FPS)):
    proc.stdin.write(render_frame(i / FPS).tobytes())
proc.stdin.close(); proc.wait()
```

- 1280x720 at 30fps is the sweet spot for render time vs quality. Dimensions must be even for yuv420p.
- Drive everything from a single time value `t` in seconds. Scene functions take `t` and draw; they must be pure functions of `t` wherever possible so any frame is reproducible.
- Seed every `random.Random(n)` and `np.random.default_rng(n)` so re-renders are identical.
- Timing helpers you will need constantly: `smooth(t)` (smoothstep, clamped) and `fade(t, t0, t1, edge)` returning 0..1 with eased edges. Every element fades in and out through these; nothing pops.

## Visual language A: dark scenes

Near-black background (6, 7, 10). Text never glows: every caption, headline, and typed line renders as clean antialiased type, exactly like normal UI text, on a separate RGBA overlay alpha-composited last. Anyesh rejected glowing and shimmering text outright, so never blur text and never pulse its opacity. Draw graphic marks (points, lines, rings) crisp straight onto the background by default. If a piece genuinely calls for neon marks, glow only those graphics: draw them on a black RGB layer, `layer.filter(GaussianBlur(7))`, then `ImageChops.add` the blur and the crisp layer over the background, keeping all text off that layer. Palette: one warm accent (amber 255,196,130), one cool (cyan 140,190,255), near-white ink for text. Good scene vocabulary: blinking cursor, typed prompt, constellation of nodes with pulsing edges, a dot trail whose lights dim behind a moving "context limit" line.

## Visual language B: typed letter on paper

See `references/techniques.md` for the full recipes. The essentials:

- **Paper**: cream base plus gaussian grain plus block-scaled fiber noise plus a horizontal vignette, built once as one tall image (page height = all lines + one screen height). Text is stamped into it permanently; each frame is just a crop.
- **Typewriter text**: build an event schedule first (list of `{t, kind, ...}` dicts), then both the audio and the frames consume the same schedule, which keeps sound and picture in perfect sync for free. Per character: interval about 1/13.5 s with jitter, occasional 0.4 to 1.0 s hesitations, pauses after commas and periods, a ding plus carriage sound per line. Stamp each glyph with position jitter of about 1px and random ink strength 0.66 to 1.0; fake ink-on-paper by lerping the ink color toward the paper color rather than using alpha (ImageDraw on RGBA replaces the alpha channel instead of compositing).
- **The strikeout**: type a word, pause, draw a wavy line through it, continue on the next line. One struck word ("goodbye" becomes "thank you") does more emotional work than any graphic.
- **Camera**: exponential scroll toward the current line, `scroll += (target - scroll) * 0.06` per frame.
- **Self-drawing illustrations**: shapes as lists of polylines in local coordinates, revealed by drawing only the first `frac` of total points, anchored to a stanza and triggered a beat after that stanza starts typing. Keep them animated after reveal (bobbing boat, curling steam, twinkling star, beating heart). A shape library (stamp, sun, constellation, boat, envelope, teacup, server tower, heart, flourish) lives in `letter_animated.py`.
- **Fresh ink**: for 0.55 s after each keystroke, overdraw the glyph darker with fading strength. Reads as ink drying.
- **Coda**: crossfade the paper into a night scene reusing the same stroke shapes in moonlight color on near-black, with one final line typed in the same font. Ending in a different world than you started lands hard.

## Audio

Full recipes in `references/audio.md`. Everything is numpy sine waves, filtered noise, and exponential decays written to a wav with the stdlib `wave` module. Minimum viable score: two or three detuned drones with slow LFOs, sparse pentatonic bells, soft convolved-noise texture, and a global fade-in/fade-out envelope. Typing sounds are driven by the same event schedule as the video; use the mechanical keyboard kit for on-screen typing (Anyesh's preference), and reserve the typewriter kit for the paper-letter language where the aesthetic demands it. Normalize to 0.85 peak before writing int16.

## Pitfalls actually hit while building the reference films

- `random.Random(9).uniform(...)` inside a comprehension gives every element the same value. Create the rng once outside.
- ImageDraw text with an alpha fill on RGBA writes the alpha channel instead of blending. Lerp colors toward the background instead.
- Don't verify by trusting the render log. Extract frames and look at them; the one real bug in the reference films (stars stacked in a column) was only visible in a frame.
- Gaussian blur per frame is affordable; per-glyph sprite stamping in Python loops is not needed at 720p.
- Keep per-frame cost O(what changed): stamp permanent marks into a persistent image once, redraw only animated elements.
