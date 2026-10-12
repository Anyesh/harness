'use strict';

const A = {};

function heartPath(g, cx, cy, s) {
  g.beginPath();
  g.moveTo(cx, cy + s * 0.9);
  g.bezierCurveTo(cx - s * 1.5, cy - s * 0.1, cx - s * 0.9, cy - s * 1.25, cx, cy - s * 0.45);
  g.bezierCurveTo(cx + s * 0.9, cy - s * 1.25, cx + s * 1.5, cy - s * 0.1, cx, cy + s * 0.9);
  g.closePath();
}

function crayonMask(g, r, bite = 0.7, scale = 0.6) {
  g.save();
  g.setTransform(1, 0, 0, 1, 0, 0);
  g.globalCompositeOperation = 'destination-out';
  const pat = g.createPattern(TEX.crayon, 'repeat');
  pat.setTransform(new DOMMatrix().translate(r() * 300, r() * 300).scale(scale));
  g.fillStyle = pat;
  g.globalAlpha = bite;
  g.fillRect(0, 0, g.canvas.width, g.canvas.height);
  g.restore();
}

function crayonText(str, font, size, color, o = {}) {
  const m = scratchMeasure();
  m.font = `${o.weight ?? 400} ${size}px ${font}`;
  const w = m.measureText(str).width;
  return makeInkSprite({ x: -w / 2 - 10, y: -size * 0.85, w: w + 20, h: size * 1.25 }, (g, r) => {
    g.font = `${o.weight ?? 400} ${size}px ${font}`;
    g.fillStyle = color;
    g.textAlign = 'center';
    let x = -w / 2;
    for (const ch of [...str]) {
      const cw = g.measureText(ch).width;
      g.save();
      g.translate(x + cw / 2, (r() - 0.5) * 6);
      g.rotate((r() - 0.5) * 0.12);
      g.fillText(ch, 0, 0);
      g.restore();
      x += cw;
    }
    crayonMask(g, r, o.bite ?? 0.62, 0.55);
  }, { variants: o.variants ?? 3, seed: hash(str, color), res: o.res ?? 1.25 });
}

function makeLabel(text, o = {}) {
  const size = o.size ?? 54;
  const font = o.font ?? FONTS.marker;
  const w = measure(text, font, size, 400) + (o.padX ?? 46);
  const h = size * 1.45;
  return makePaper({
    shape: rectPts(-w / 2, -h / 2, w, h),
    color: o.color ?? PAL.white,
    edge: o.edge ?? 'cut',
    pattern: o.pattern,
    seed: hash('label', text),
    maxSeg: 40,
    ink: (g, r) => handText(g, text, 0, size * 0.36, r, { size, font, align: 'center', color: o.ink ?? INK, weight: 400, jit: 0.8 }),
  });
}

function ransomChip(ch, i, o = {}) {
  const r = rng(hash('ransom', ch, i, o.salt ?? 0));
  const font = RANSOM_FONTS[Math.floor(r() * RANSOM_FONTS.length)];
  const size = (o.size ?? 120) * rr(r, 0.85, 1.12);
  const m = scratchMeasure();
  m.font = `400 ${size}px ${font}`;
  const tm = m.measureText(ch);
  const gw = tm.actualBoundingBoxLeft + tm.actualBoundingBoxRight;
  const asc = tm.actualBoundingBoxAscent;
  const desc = tm.actualBoundingBoxDescent;
  const pw = gw + rr(r, 22, 44);
  const ph = asc + desc + rr(r, 22, 40);
  const schemes = o.schemes ?? [
    [PAL.white, INK],
    [PAL.red, PAL.white],
    [PAL.mustard, INK],
    [PAL.navy, PAL.cream],
    ['#e9e4d6', INK, 'news'],
    [PAL.teal, PAL.white],
    [PAL.pink, '#5a2a2a'],
    [PAL.cream, PAL.red],
    [INK, PAL.mustard],
    [PAL.sky, PAL.navy],
  ];
  const [bg, fg, kind] = schemes[Math.floor(r() * schemes.length)];
  const sprite = makePaper({
    shape: rectPts(-pw / 2, -ph / 2, pw, ph),
    color: bg,
    edge: r() < 0.35 ? 'torn' : 'cut',
    rim: 3,
    amp: 1.5,
    pattern: kind === 'news' ? PATTERNS.newsprint(9, 'rgba(40,35,30,0.25)') : r() < 0.2 ? PATTERNS.halftone('rgba(0,0,0,0.12)', 7) : null,
    seed: hash('rchip', ch, i, o.salt ?? 0),
    maxSeg: 30,
    shadowBlur: 3,
    post: (g) => {
      g.font = `400 ${size}px ${font}`;
      g.fillStyle = fg;
      g.fillText(ch, -gw / 2 + tm.actualBoundingBoxLeft, (asc - desc) / 2);
    },
  });
  sprite.cw = pw;
  sprite.tilt = (r() - 0.5) * 0.22;
  sprite.dy = (r() - 0.5) * 12;
  return sprite;
}

function ransomWord(str, o = {}) {
  return [...str].map((ch, i) => (ch === ' ' ? null : ransomChip(ch, i, o)));
}

function buildArt() {
  A.hero = makePerson({ seed: 11, body: PAL.mustard, hairShape: HAIR.tuft, hair: '#3b2a20' });
  A.title = ransomWord('HELLO', { size: 150 });
  A.tape = makeTape(140, 38, 5);
}
