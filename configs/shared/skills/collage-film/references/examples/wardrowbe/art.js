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

const BRAND = { tile: '#262626', tile2: '#1a1a1a', dot: '#fafafa', table: '#f5f4f1', denim: '#4a6fa5', coral: '#f07a5f', mint: '#8fd3b6', rain: '#f2c230', lilac: '#b9a3d6', pink: '#f4a6b8' };

const GARMENT = {
  tee: [[-38, -128], [0, -110], [38, -128], [110, -92], [86, -36], [60, -54], [60, 122], [-60, 122], [-60, -54], [-86, -36], [-110, -92]],
  shirt: [[-36, -132], [0, -112], [36, -132], [96, -110], [128, 40], [100, 48], [68, -46], [66, 132], [-66, 132], [-68, -46], [-100, 48], [-128, 40], [-96, -110]],
  coat: [[-40, -140], [0, -118], [40, -140], [100, -116], [134, 60], [104, 66], [74, -40], [84, 176], [-84, 176], [-74, -40], [-104, 66], [-134, 60], [-100, -116]],
  pants: [[-64, -124], [64, -124], [74, 146], [20, 146], [0, -30], [-20, 146], [-74, 146]],
  skirt: [[-52, -70], [52, -70], [96, 80], [-96, 80]],
  sock: [[-22, -90], [24, -90], [24, 20], [66, 28], [70, 62], [-22, 64]],
};

const FABRIC = {
  stripes: (c) => PATTERNS.stripes(c, 9, 0),
  pinstripe: (c) => PATTERNS.stripes(c, 3, 0),
  plaid: (c) => PATTERNS.chain(PATTERNS.gingham(c, 18, 0.28), PATTERNS.stripes('rgba(255,255,255,0.18)', 2, 0)),
  dots: (c) => PATTERNS.dots(c, 26, 5),
  denim: () => PATTERNS.chain(PATTERNS.stripes('rgba(255,255,255,0.07)', 2, 0.8), PATTERNS.speckle('rgba(255,255,255,0.35)', 500, 0.5)),
  knit: (c) => (g, b) => {
    g.save();
    g.strokeStyle = c;
    g.lineWidth = 3;
    for (let y = b.y; y < b.y + b.h; y += 16) {
      g.beginPath();
      for (let x = b.x; x < b.x + b.w; x += 12) g.lineTo(x, y + ((x / 12) % 2 ? 6 : 0));
      g.stroke();
    }
    g.restore();
  },
  floral: () => (g, b, r) => {
    g.save();
    for (let i = 0; i < (b.w * b.h) / 2600; i++) {
      const x = b.x + r() * b.w;
      const y = b.y + r() * b.h;
      g.fillStyle = ['#f6d24a', '#ffffff', '#ff9a8b'][i % 3];
      for (let k = 0; k < 5; k++) {
        const a = (k / 5) * TAU + i;
        g.beginPath();
        g.ellipse(x + Math.cos(a) * 9, y + Math.sin(a) * 9, 8, 5, a, 0, TAU);
        g.fill();
      }
      g.fillStyle = '#2f7d4f';
      g.beginPath();
      g.ellipse(x + 18, y + 14, 14, 6, 0.6, 0, TAU);
      g.fill();
    }
    g.restore();
  },
};

function garment(kind, color, o = {}) {
  const shape = o.shape ?? GARMENT[kind];
  return makePaper({
    shapes: o.shapes ?? [shape],
    color,
    pattern: o.pattern,
    edge: o.edge ?? 'cut',
    seed: o.seed ?? hash(kind, color, o.salt ?? 0),
    maxSeg: 22,
    ink: (g, r) => {
      if (kind === 'shirt' || kind === 'coat') {
        ink(g, [[0, -112], [0, kind === 'coat' ? 170 : 126]], r, { w: 2.4, alpha: 0.6 });
        for (let y = -80; y < (kind === 'coat' ? 160 : 120); y += 38) inkDot(g, 8, y, 4, r, kind === 'coat' ? '#7a5a10' : INK);
        ink(g, [[-36, -132], [-18, -96], [0, -112]], r, { w: 2.6 });
        ink(g, [[36, -132], [18, -96], [0, -112]], r, { w: 2.6 });
      }
      if (kind === 'tee') ink(g, arcPts(0, -126, 38, 18, 0.15, Math.PI - 0.15, 10), r, { w: 2.6, alpha: 0.7 });
      if (kind === 'pants') {
        ink(g, [[0, -124], [0, -30]], r, { w: 2.2, alpha: 0.6 });
        ink(g, [[-56, -100], [-30, -86]], r, { w: 2, alpha: 0.5, color: '#f2c14e' });
        ink(g, [[56, -100], [30, -86]], r, { w: 2, alpha: 0.5, color: '#f2c14e' });
      }
      if (o.cuffs) for (const [x0, x1, y] of o.cuffs) ink(g, [[x0, y], [x1, y]], r, { w: 3, alpha: 0.45 });
      if (o.ink) o.ink(g, r);
    },
  });
}

function hoodieShapes() {
  return shapeFromDraw({ x: -140, y: -200, w: 280, h: 340 }, (g) => {
    tracePath(g, GARMENT.shirt);
    g.fill();
    g.beginPath();
    g.ellipse(0, -138, 58, 52, 0, 0, TAU);
    g.fill();
  }, 1);
}

function shoeShape(boot) {
  return spline(boot ? [[-30, -96], [16, -96], [18, -20], [62, -6], [64, 12], [-34, 12]] : [[-40, -26], [-6, -34], [24, -20], [60, -8], [62, 12], [-42, 12]], true, 5);
}

function makeShoe(color, boot, seed) {
  return makePaper({
    shape: shoeShape(boot),
    color,
    edge: 'cut',
    seed,
    shadowBlur: 3,
    post: (g) => {
      g.fillStyle = 'rgba(255,255,255,0.85)';
      g.fillRect(-44, 4, 108, 8);
    },
  });
}

function logoTile(size, seed = 900) {
  const h = size / 2;
  return makePaper({
    shape: roundRectPts(-h, -h, size, size, size * 0.19, 8),
    color: BRAND.tile,
    edge: 'cut',
    maxSeg: 40,
    jitter: 0.6,
    seed,
    shadowBlur: 10,
    // Shading must be clipped to the rounded tile, otherwise the square fill shows in the corners.
    post: (g, r, { inners }) => {
      g.save();
      tracePath(g, inners[0]);
      g.clip();
      const lg = g.createLinearGradient(-h, -h, h, h);
      lg.addColorStop(0, 'rgba(255,255,255,0.06)');
      lg.addColorStop(1, 'rgba(0,0,0,0.22)');
      g.fillStyle = lg;
      g.fillRect(-h, -h, size, size);
      g.fillStyle = 'rgba(255,255,255,0.05)';
      tracePath(g, roundRectPts(-h + size * 0.024, -h + size * 0.024, size * 0.952, size * 0.476, size * 0.17, 8));
      g.fill();
      g.restore();
    },
  });
}

// Braille "W" (dots 2, 4, 5, 6) in logo units where the tile spans -50..50.
const LOGO_DOTS = [[-15, 0], [15, -22], [15, 0], [15, 22]];

function buildArt() {
  A.tape = makeTape(140, 38, 5);
  A.tapes = [0, 1, 2, 3, 4, 5].map((i) => makeTape(110 + (i % 3) * 18, 34, 150 + i));
  A.hero = makePerson({
    seed: 57,
    body: '#c3b1e1',
    bodyPattern: (g, bb, r) => {
      g.save();
      g.fillStyle = 'rgba(255,255,255,0.75)';
      for (let i = 0; i < (bb.w * bb.h) / 900; i++) {
        tracePath(g, starPts(bb.x + r() * bb.w, bb.y + r() * bb.h, 6, 2.6, 5, r() * TAU));
        g.fill();
      }
      g.restore();
    },
    hairShape: HAIR.bangs,
    hairBack: longHairBack(),
    hair: '#b5532e',
    skin: PAL.skin,
    pants: { color: '#c3b1e1', w: 24 },
    shoe: '#f4a6b8',
    buttons: false,
    lashes: true,
    freckles: true,
    adorn: (g, r) => {
      g.save();
      g.fillStyle = BRAND.coral;
      g.beginPath();
      g.ellipse(0, -64, 22, 8, 0, 0, TAU);
      g.fill();
      g.restore();
      for (let i = -2; i <= 2; i++) ink(g, [[i * 8, -70], [i * 8 + 1, -58]], r, { w: 1.6, alpha: 0.45, color: '#8a3a2a' });
      g.save();
      g.fillStyle = PAL.mustard;
      tracePath(g, starPts(34, -36, 11, 5, 5, -0.3));
      g.fill();
      g.restore();
      ink(g, starPts(34, -36, 11, 5, 5, -0.3), r, { w: 1.6, closed: true, taper: 0, alpha: 0.7 });
    },
  });
  A.raincoatTop = makeTorso({ seed: 61, body: BRAND.rain, bodyPattern: null });
  A.tealTop = makeTorso({ seed: 62, body: PAL.teal, bodyPattern: FABRIC.dots('rgba(255,255,255,0.5)') });
  A.hawaiiTop = makeTorso({ seed: 63, body: '#3fa7c9', bodyPattern: FABRIC.floral() });
  A.sweaterTop = makeTorso({ seed: 64, body: '#c8553d', bodyPattern: FABRIC.knit('rgba(255,255,255,0.28)'), buttons: false });
  A.boot = makeShoe('#2f5d50', true, 71);
  A.sneaker = makeShoe('#f2f2f2', false, 72);
  A.snowBoot = makeShoe('#7b5b3a', true, 73);
  A.rigBoot = makePaper({ shape: shoeShape(true).map(([x, y]) => [x * 0.42, y * 0.42]), color: '#2f5d50', edge: 'cut', seed: 74, shadowBlur: 2 });
  A.friend = makePerson({ seed: 81, body: BRAND.coral, bodyPattern: FABRIC.dots('rgba(255,240,210,0.6)'), hairShape: HAIR.tuft, hair: '#2b1d16', skin: PAL.skin2, pants: { color: BRAND.denim, w: 25 } });
  A.kid = makePerson({ seed: 91, body: BRAND.mint, hairShape: HAIR.tuft, hair: '#e6c26a', skin: PAL.skin3, pants: { color: '#3a3a44', w: 22 }, size: 0.72, buttons: false });

  A.clothes = [
    garment('tee', BRAND.coral, { pattern: FABRIC.stripes('rgba(255,255,255,0.5)') }),
    garment('pants', BRAND.denim, { pattern: FABRIC.denim() }),
    garment('shirt', '#f4f1ea', { pattern: FABRIC.pinstripe('rgba(74,111,165,0.35)') }),
    garment('skirt', PAL.mustard, { pattern: FABRIC.plaid('#a0522d') }),
    garment('tee', BRAND.mint, {}),
    garment('sock', BRAND.pink, { pattern: FABRIC.stripes('rgba(255,255,255,0.6)') }),
    garment('shirt', '#3fa7c9', { pattern: FABRIC.floral() }),
    garment('pants', '#3a3a44', { pattern: FABRIC.pinstripe('rgba(255,255,255,0.12)') }),
    garment('tee', PAL.lilac, { pattern: FABRIC.dots('rgba(255,255,255,0.55)') }),
    garment('skirt', BRAND.coral, { pattern: FABRIC.dots('rgba(255,255,255,0.6)') }),
    garment('sock', PAL.mustard, {}),
    garment('shirt', '#8a9a5b', { pattern: FABRIC.plaid('#3d4a2a') }),
    garment('tee', '#f4f1ea', {}),
    garment('pants', '#b5651d', { pattern: FABRIC.pinstripe('rgba(0,0,0,0.12)') }),
    garment('sock', BRAND.mint, { pattern: FABRIC.dots('rgba(255,255,255,0.7)') }),
    garment('tee', '#2f2f35', {}),
    garment('skirt', BRAND.denim, { pattern: FABRIC.denim() }),
    garment('shirt', BRAND.pink, {}),
  ];
  A.stripedShirt = garment('shirt', '#7fa9d9', { pattern: FABRIC.stripes('rgba(255,255,255,0.55)'), salt: 2 });
  A.hoodie = makePaper({
    shapes: hoodieShapes(),
    color: BRAND.pink,
    edge: 'cut',
    seed: 101,
    ink: (g, r) => {
      ink(g, ellipsePts(0, -132, 34, 30, 30), r, { w: 3, closed: true, taper: 0, alpha: 0.6 });
      ink(g, [[-40, 60], [40, 60], [48, 110], [-48, 110], [-40, 60]], r, { w: 2.6, alpha: 0.5 });
      ink(g, [[-12, -100], [-14, -40]], r, { w: 2.2 });
      ink(g, [[12, -100], [14, -40]], r, { w: 2.2 });
    },
  });
  A.sweater = garment('shirt', '#c8553d', { pattern: FABRIC.knit('rgba(255,255,255,0.3)'), shape: GARMENT.shirt, salt: 9, cuffs: [[-128, -100, 30], [100, 128, 30], [-66, 66, 116]] });
  A.blouse = garment('tee', PAL.teal, { pattern: FABRIC.dots('rgba(255,255,255,0.55)'), salt: 4 });
  A.matchSkirt = garment('skirt', PAL.mustard, { pattern: FABRIC.plaid('#a0522d'), salt: 5 });
  A.candidates = [garment('tee', '#b5651d', { salt: 6 }), garment('tee', PAL.lilac, { salt: 7, pattern: FABRIC.stripes('rgba(255,255,255,0.4)') }), garment('tee', '#3fa7c9', { pattern: FABRIC.floral(), salt: 8 })];

  const cabW = 560;
  const cabH = 800;
  A.cabinet = makePaper({
    shape: rectPts(-cabW / 2, -cabH, cabW, cabH),
    color: '#b98a5e',
    edge: 'cut',
    maxSeg: 60,
    seed: 111,
    res: 0.9,
    pattern: PATTERNS.stripes('rgba(90,50,20,0.1)', 4, 1.57),
    post: (g) => {
      g.fillStyle = '#3a2a22';
      g.fillRect(-cabW / 2 + 24, -cabH + 70, cabW - 48, cabH - 110);
      g.fillStyle = '#7a5a3a';
      g.fillRect(-cabW / 2 + 24, -cabH + 110, cabW - 48, 10);
      g.fillStyle = '#9c7048';
      g.fillRect(-cabW / 2 - 10, -cabH - 10, cabW + 20, 46);
    },
  });
  A.doorL = makePaper({ shape: rectPts(0, -cabH + 60, cabW / 2 - 18, cabH - 90), color: '#d9b48a', edge: 'cut', seed: 112, res: 0.9, post: (g) => {
    g.strokeStyle = 'rgba(90,50,20,0.35)';
    g.lineWidth = 4;
    g.strokeRect(22, -cabH + 100, cabW / 2 - 62, cabH - 170);
  }, ink: (g, r) => inkDot(g, cabW / 2 - 44, -cabH / 2, 9, r, '#6b4a2a') });
  A.doorR = A.doorL;
  A.hanger = makeInkSprite({ x: -70, y: -60, w: 140, h: 70 }, (g, r) => {
    ink(g, arcPts(0, -44, 10, 10, Math.PI, TAU + 0.6, 10), r, { w: 3.4, color: '#555' });
    ink(g, [[0, -34], [-64, 4], [64, 4], [0, -34]], r, { w: 3.4, color: '#555', taper: 0 });
  }, { seed: 113 });

  A.phone = makePaper({
    shape: roundRectPts(-70, -140, 140, 280, 24, 6),
    color: BRAND.tile,
    edge: 'cut',
    seed: 121,
    post: (g) => {
      g.fillStyle = '#f5f2ec';
      tracePath(g, roundRectPts(-58, -118, 116, 236, 12, 5));
      g.fill();
      g.fillStyle = '#555';
      g.fillRect(-14, -132, 28, 5);
    },
  });
  A.notif = makePaper({
    shape: roundRectPts(-330, -78, 660, 156, 30, 6),
    color: '#fbfaf7',
    edge: 'cut',
    seed: 122,
    maxSeg: 50,
    shadowBlur: 12,
  });
  A.notifIcon = logoTile(78, 123);
  A.window = makePaper({
    shapes: [rectPts(-230, -190, 460, 380), rectPts(-200, -160, 190, 150), rectPts(10, -160, 190, 150), rectPts(-200, 10, 190, 150), rectPts(10, 10, 190, 150)],
    color: '#f7f3ea',
    edge: 'cut',
    seed: 124,
  });
  A.sun = makePaper({ shape: ellipsePts(0, 0, 70, 70, 40), color: PAL.mustard, edge: 'torn', rim: 4, seed: 125 });
  A.cloud = makePaper({ shape: spline([[-120, 30], [-130, -6], [-90, -40], [-40, -48], [-10, -80], [50, -76], [80, -40], [126, -30], [140, 14], [110, 34]], true, 8), color: '#d7dbe0', edge: 'torn', rim: 4, seed: 126 });
  A.skyCloud = makePaper({ shape: spline([[-120, 30], [-130, -6], [-90, -40], [-40, -48], [-10, -80], [50, -76], [80, -40], [126, -30], [140, 14], [110, 34]], true, 8), color: '#d6ecfa', edge: 'torn', rim: 4, seed: 128, ink: (g, r) => ink(g, arcPts(-30, -30, 34, 18, Math.PI * 1.1, Math.PI * 1.6, 8), r, { w: 3, color: '#ffffff', alpha: 0.8 }) });
  A.drop = makePaper({ shape: spline([[0, -18], [8, -2], [7, 8], [0, 12], [-7, 8], [-8, -2]], true, 4), color: '#6fa8dc', edge: 'cut', seed: 127, shadowBlur: 2 });

  A.tagShape = (text, i) => {
    const size = 46;
    const w = measure(text, '"DM Sans"', size, 600) + 70;
    return makePaper({
      shapes: [[[-w / 2 + 26, -34], [w / 2, -34], [w / 2, 34], [-w / 2 + 26, 34], [-w / 2, 0]], ellipsePts(-w / 2 + 24, 0, 7, 7, 12)],
      color: ['#fbf8f0', '#f6e7b8', '#d8ecf6', '#f9d9cf', '#dff1e6'][i % 5],
      edge: 'cut',
      seed: 130 + i,
      post: (g) => {
        g.font = `600 ${size}px "DM Sans"`;
        g.fillStyle = '#2a2a2a';
        g.textAlign = 'center';
        g.fillText(text, 14, 16);
      },
    });
  };
  A.tags = ['shirt', 'light blue', 'striped', 'cotton', 'casual'].map((t, i) => A.tagShape(t, i));

  const card = (seed, tint) => makePaper({ shape: rectPts(-190, -250, 380, 500), color: '#fbfaf6', edge: 'cut', seed, post: (g) => {
    g.fillStyle = tint;
    g.fillRect(-166, -226, 332, 380);
  } });
  A.cardA = card(141, '#dfeee8');
  A.cardB = card(142, '#f6e2dc');
  A.check = makePaper({ shape: ellipsePts(0, 0, 70, 70, 40), color: '#3e9b5f', edge: 'cut', seed: 143, ink: (g, r) => ink(g, [[-30, 2], [-8, 26], [32, -24]], r, { w: 13, color: '#fbfaf6', taper: 0.3 }) });
  A.cross = makePaper({ shape: ellipsePts(0, 0, 70, 70, 40), color: '#d64545', edge: 'cut', seed: 144, ink: (g, r) => {
    ink(g, [[-26, -26], [26, 26]], r, { w: 13, color: '#fbfaf6', taper: 0.3 });
    ink(g, [[26, -26], [-26, 26]], r, { w: 13, color: '#fbfaf6', taper: 0.3 });
  } });
  A.heart = makePaper({ shapes: shapeFromDraw({ x: -40, y: -40, w: 80, h: 80 }, (g) => {
    heartPath(g, 0, 0, 28);
    g.fill();
  }, 2), color: PAL.red, edge: 'cut', seed: 145, maxSeg: 10 });
  A.noted = crayonText('noted!', FONTS.gochi, 70, '#3e9b5f');
  A.nothing = crayonText('nothing to wear?!', FONTS.gochi, 84, PAL.red);
  A.inWash = crayonText('in the wash', FONTS.gochi, 62, '#2a6f9e');
  A.match = ransomWord('MATCH!', { size: 92, salt: 3 });

  A.washer = makePaper({
    shape: roundRectPts(-190, -470, 380, 470, 18, 6),
    color: '#f4f2ee',
    edge: 'cut',
    seed: 151,
    post: (g) => {
      g.fillStyle = '#d9d6d0';
      g.fillRect(-190, -470, 380, 70);
      g.fillStyle = '#5b8fb9';
      g.fillRect(70, -446, 90, 22);
      g.fillStyle = '#9a958c';
      g.beginPath();
      g.arc(-120, -435, 16, 0, TAU);
      g.fill();
      g.beginPath();
      g.arc(-200 + 0, -200, 0, 0, TAU);
      g.fillStyle = '#b8b4ad';
      g.beginPath();
      g.arc(0, -210, 140, 0, TAU);
      g.fill();
      g.fillStyle = '#7d97ad';
      g.beginPath();
      g.arc(0, -210, 112, 0, TAU);
      g.fill();
    },
  });
  A.bubble = makeInkSprite({ x: -14, y: -14, w: 28, h: 28 }, (g, r) => {
    g.fillStyle = 'rgba(255,255,255,0.55)';
    g.beginPath();
    g.arc(0, 0, 11, 0, TAU);
    g.fill();
    ink(g, ellipsePts(0, 0, 11, 11, 16), r, { w: 1.6, closed: true, taper: 0, color: 'rgba(255,255,255,0.9)' });
  }, { seed: 152 });
  A.cobweb = makeInkSprite({ x: -80, y: -80, w: 160, h: 160 }, (g, r) => {
    for (let i = 0; i < 6; i++) ink(g, [[0, 0], [Math.cos(i * 0.5 - 0.3) * 110, Math.sin(i * 0.5 - 0.3) * 110]], r, { w: 1.4, color: '#777', alpha: 0.7 });
    for (const rad of [30, 55, 80]) {
      const pts = [];
      for (let i = 0; i < 6; i++) pts.push([Math.cos(i * 0.5 - 0.3) * rad, Math.sin(i * 0.5 - 0.3) * rad]);
      ink(g, spline(pts, false, 4), r, { w: 1.2, color: '#777', alpha: 0.7 });
    }
  }, { seed: 153 });
  A.star = makePaper({ shape: spline(starPts(0, 0, 40, 18, 5), true, 3), color: '#f6c945', edge: 'cut', seed: 154, maxSeg: 12 });
  A.starOff = makePaper({ shape: spline(starPts(0, 0, 40, 18, 5), true, 3), color: '#d8d2c6', edge: 'cut', seed: 155, maxSeg: 12 });
  A.ratingCard = makePaper({ shape: roundRectPts(-130, -50, 260, 100, 16, 5), color: '#fbfaf6', edge: 'cut', seed: 156 });

  A.house = makePaper({
    shapes: shapeFromDraw({ x: -340, y: -620, w: 680, h: 640 }, (g) => {
      g.fillRect(-270, -360, 540, 370);
      g.beginPath();
      g.moveTo(-330, -340);
      g.lineTo(0, -600);
      g.lineTo(330, -340);
      g.closePath();
      g.fill();
      g.fillRect(150, -560, 60, 140);
    }, 1),
    color: BRAND.coral,
    edge: 'cut',
    seed: 161,
    res: 0.9,
    post: (g) => {
      g.fillStyle = BRAND.tile;
      g.beginPath();
      g.moveTo(-336, -336);
      g.lineTo(0, -604);
      g.lineTo(336, -336);
      g.lineTo(336, -318);
      g.lineTo(-336, -318);
      g.closePath();
      g.fill();
      g.fillStyle = '#ffe9a8';
      g.fillRect(-210, -270, 200, 170);
      g.fillStyle = '#5a3b2a';
      g.fillRect(70, -200, 130, 210);
    },
  });
  A.houseDoor = makePaper({ shape: rectPts(0, -210, 130, 210), color: '#8a5a3b', edge: 'cut', seed: 162, ink: (g, r) => inkDot(g, 106, -100, 7, r, '#f2c14e') });
  A.miniTile = logoTile(70, 163);
  A.puff = makePaper({ shape: spline([[-40, 10], [-36, -14], [-10, -26], [16, -22], [38, -6], [36, 14], [0, 22]], true, 6), color: '#f4f2ee', edge: 'torn', rim: 3, seed: 164 });

  A.tileBig = logoTile(252, 171);
  A.dot = makePaper({ shape: ellipsePts(0, 0, 27, 27, 64), color: BRAND.dot, edge: 'cut', seed: 172, minSeg: 3, maxSeg: 4, jitter: 0.25, shadowBlur: 4 });
  const wm = textShapes('wardrowbe', '"DM Sans"', 150, { weight: 700 });
  A.wordmark = makePaper({ shapes: wm.shapes, color: BRAND.dot, edge: 'cut', seed: 173, maxSeg: 10, jitter: 0.5 });
  A.wordmarkW = wm.w;
  A.wordmarkDark = makePaper({ shapes: wm.shapes, color: BRAND.tile, edge: 'cut', seed: 174, maxSeg: 10, jitter: 0.5 });
  A.tagline = ['Snap.', 'Organize.', 'Wear.'].map((t, i) => makeLabel(t, { font: '"DM Sans"', size: 62, color: ['#fbf8f0', '#f6e7b8', '#d8ecf6'][i], padX: 50 }));
  A.rowCard = makePaper({ shape: roundRectPts(-118, -118, 236, 236, 26, 6), color: '#fbfaf6', edge: 'cut', seed: 175, maxSeg: 40, shadowBlur: 6 });
  A.panel = makePaper({ shape: roundRectPts(-880, -470, 1760, 940, 90, 8), color: BRAND.tile, edge: 'cut', seed: 176, maxSeg: 80, res: 0.7, shadowBlur: 14, pattern: PATTERNS.speckle('rgba(255,255,255,0.25)', 600, 0.4) });
  A.floor = makePaper({ shape: rectPts(-1300, 0, 2600, 260), color: '#e3d2b8', edge: 'torn', rim: 6, amp: 6, seed: 177, res: 0.6, pattern: PATTERNS.stripes('rgba(90,60,30,0.06)', 30, 0) });
  A.frame = makePaper({ shape: rectPts(-120, -90, 240, 180), color: '#f7f3ea', edge: 'cut', seed: 178, post: (g) => {
    g.fillStyle = '#9fd0e3';
    g.fillRect(-100, -70, 200, 140);
    g.fillStyle = '#7cae5a';
    g.beginPath();
    g.moveTo(-100, 70);
    g.lineTo(-30, -10);
    g.lineTo(20, 40);
    g.lineTo(60, 0);
    g.lineTo(100, 70);
    g.fill();
  } });
  A.clock = makePaper({ shape: ellipsePts(0, 0, 58, 58, 40), color: '#fbfaf6', edge: 'cut', seed: 179, ink: (g, r) => {
    ink(g, ellipsePts(0, 0, 50, 50, 36), r, { w: 3, closed: true, taper: 0 });
    ink(g, [[0, 0], [0, -34]], r, { w: 4 });
    ink(g, [[0, 0], [22, 8]], r, { w: 4 });
  } });
}
