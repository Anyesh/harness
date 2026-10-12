# Method

## Storyboarding

Print the word timeline once and keep it beside you:

```sh
python3 -c "
import json; d=json.load(open('audio/vo_timeline.json'))
for l in d['lines']: print(l['id'], round(l['start'],2), round(l['end'],2), ' '.join(f\"{w['w']}@{w['s']:.2f}\" for w in l['words'] if any(c.isalpha() for c in w['w'])))"
```

Then write the storyboard as one block per scene: time range, setting, and each beat with its cue word. Good beats are physical and a little absurd (a wardrobe avalanche on "nothing to wear", a washing machine spinning the hoodie on "in the wash", two garments holding hands on "match"). A product film opens on the relatable problem, introduces the brand on a dark panel, then gives one visual gag per feature, and ends on a logo card with tagline and URL.

Scene boundaries sit in the pauses between narration lines. Torn wipes (`WIPES`) of 0.4 s cover cuts; a long camera pan inside one scene is the alternative and gets automatic motion smear.

## Scene structure

```js
function bedroom() {
  const doorT = wd('nothing', 'closet');        // word start time, case-insensitive
  sfx(doorT, 'thump', 0.5, 0.35);                // cues are registered at build time
  scene(0, 7.95, (ctx, t, cam) => {              // t is global film time
    A.cabinet.draw(ctx, 1320, 900);
    if (t >= doorT) { const L = landing(t, doorT, 0.2, 1.6); A.x.draw(ctx, x, y, { scale: L.s, lift: L.lift }); }
  }, { cam: [[0, [880, 540, 1.12]], [7.95, [800, 520, 1.12]]], table: '#e9dcc6' });
}
```

A scene must draw correctly for its whole range plus any wipe that overlaps it (the incoming scene is drawn during the wipe before its own `t0`). World coordinates are 1920x1080 at zoom 1; `cam` keys are `[t, [cx, cy, zoom]]`.

## Cheat sheet

Timing and motion (`stage.js`, `engine.js`):
- Film globals in `scenes.js`: `DURATION`, `POSTER_T`, `WIPES`, `PAPER_TEXTURE` (paper grain strength, default 1), and `GRADE(t)` returning `{ wash, vignette, cool, warm }` (`wash` defaults to 0.18 and `vignette` to 0.85, the vintage look).
- `wd(id, word, nth)`, `kf(t, keys)`, `prog(t, a, b)`, `lerp`, `clamp`, `ease.{out,in,inOut,outBack,outElastic,outBounce,inOutSine}`
- `stepped(t)` quantizes to 12 fps "twos"; use it for character motion, not for the camera.
- `landing(t, t0, d, fromScale)` returns `{ s, lift }` for a drop-in; `fly(t, t0, t1, from, to, arc, spin)` returns `{ x, y, rot, lift, p }`; `boilIndex(t)` picks the ink boil frame.
- `burst(ctx, x, y, p, r, n, r0, r1, color)`, `sparkle(ctx, x, y, size, r, color)`.

Paper and ink (`engine.js`):
- `makePaper({ shape | shapes, color, edge: 'cut'|'torn', pattern, post(g), ink(g, r, v), seed })` returns a `Sprite`; `sprite.draw(ctx, x, y, { scale, sx, sy, rot, lift, alpha, v, shadow })`. The anchor is the shape's origin.
- Shapes: `rectPts`, `roundRectPts`, `ellipsePts`, `arcPts`, `starPts`, `spline(pts, closed)`, `shapeFromDraw(box, g => ...)`, `textShapes(str, font, size, { weight })` (centered, returns `{ shapes, w }`).
- `ink(ctx, pts, r, { w, color, closed, taper, alpha })`, `inkDot`, `crayon(ctx, pts, r, { w, color })`, `handText(ctx, str, x, y, r, { size, font, align })`, `PATTERNS.{stripes,dots,gingham,grid,halftone,speckle,newsprint,chain}`.
- Per-frame randomness for ink must be seeded by boil frame: `rng(hash(key, boilIndex(t)))`, otherwise lines flicker every frame.

Characters (`character.js`):
- `makePerson({ seed, body, bodyPattern, hairShape: HAIR.curly|bob|tuft|bangs, hair, skin, pants: { color, w }, size, buttons })`; `makeTorso(spec)` builds an outfit top on the same cut. Optional: `hairBack` (shapes behind the head, shaded darker than `hair`; `longHairBack()` gives long wavy hair with a top bun), `lashes: true`, `freckles: true`, `adorn(ctx, r, v)` drawn after the front hair for clips and bows.
- `drawPerson(ctx, P, pose, t)` with pose `{ x, y (feet), scale, flip, armL/armR/legL/legR: [angleFromDown, elbow], expr, eyes, mouth, look: [x, y], blink, head: { rot, dx, dy }, body, pants, shoe }`; returns world `handL`, `handR`, `head` for attaching props. An arm at `[2.9, 0.1]` points straight up.
- Height is about 312 units times `scale`; at `scale` 1.8 a character fills about 45 percent of a 1080 frame.

## Product film specifics

- Recreate the logo as paper (a rounded tile plus dot sprites) and the wordmark with `textShapes` in the brand font; add the font to `web/fonts` and `index.html` (main.js loads every `@font-face` it finds).
- Brand colours for brand moments (logo panel, end card), playful saturated colours everywhere else.
- UI moments (notifications, cards, tags) are paper props with real text drawn in the brand font, large enough to read at 1080p (27 px minimum after camera zoom).
