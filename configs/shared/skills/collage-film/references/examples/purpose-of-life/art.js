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
    g.textBaseline = 'alphabetic';
    const chars = [...str];
    let x = -w / 2;
    for (const ch of chars) {
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
    ink: (g, r) => {
      handText(g, text, 0, size * 0.36, r, { size, font, align: 'center', color: o.ink ?? INK, weight: 400, jit: 0.8 });
    },
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
  const gh = asc + desc;
  const pw = gw + rr(r, 22, 44);
  const ph = gh + rr(r, 22, 40);
  const schemes = [
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
      g.save();
      g.font = `400 ${size}px ${font}`;
      g.fillStyle = fg;
      g.textBaseline = 'alphabetic';
      g.fillText(ch, -gw / 2 + tm.actualBoundingBoxLeft, (asc - desc) / 2);
      g.restore();
    },
  });
  sprite.cw = pw;
  sprite.chh = ph;
  sprite.tilt = (r() - 0.5) * 0.22;
  sprite.dy = (r() - 0.5) * 12;
  return sprite;
}

function ransomWord(str, o = {}) {
  return [...str].map((ch, i) => (ch === ' ' ? null : ransomChip(ch, i, o)));
}

function buildHats() {
  const leaf = (g, x, y, a, s) => {
    g.save();
    g.translate(x, y);
    g.rotate(a);
    g.beginPath();
    g.ellipse(0, -s, s * 0.42, s, 0, 0, TAU);
    g.fill();
    g.restore();
  };
  const laurelBox = { x: -80, y: -110, w: 160, h: 110 };
  const laurelShapes = shapeFromDraw(laurelBox, (g) => {
    g.lineWidth = 7;
    for (const side of [-1, 1]) {
      for (let i = 0; i < 6; i++) {
        const a = Math.PI * (0.98 - i * 0.085);
        const x = Math.cos(a) * 56 * side;
        const y = -Math.sin(a) * 50 - 28;
        leaf(g, x, y, side * (-1.25 + i * 0.27), 15);
        leaf(g, x * 1.03, y + 4, side * (-0.4 + i * 0.27), 12);
      }
    }
  }, 2);
  A.laurel = makePaper({ shapes: laurelShapes, color: PAL.leaf, edge: 'cut', seed: 301, maxSeg: 8, jitter: 0.4, shadowBlur: 3 });

  A.beret = makePaper({
    shape: spline([
      [-66, -38],
      [-50, -70],
      [0, -88],
      [62, -76],
      [82, -52],
      [60, -36],
      [0, -40],
    ], true, 8),
    color: '#8c2d3c',
    edge: 'cut',
    seed: 302,
    ink: (g, r) => ink(g, spline([
      [-58, -44],
      [0, -48],
      [60, -42],
    ]), r, { w: 2.5, alpha: 0.5 }),
  });
  A.feather = makePaper({
    shape: spline([
      [0, 0],
      [-14, -40],
      [-8, -100],
      [10, -150],
      [26, -120],
      [22, -60],
      [8, -10],
    ], true, 8),
    color: PAL.white,
    edge: 'torn',
    rim: 2,
    amp: 3,
    freq: 9,
    seed: 303,
    ink: (g, r) => {
      ink(g, spline([
        [2, 0],
        [4, -60],
        [12, -140],
      ]), r, { w: 2.4 });
      for (let i = 0; i < 9; i++) {
        const y = -18 - i * 13;
        ink(g, [
          [5 + i * 0.6, y],
          [-8 + i * 0.4, y - 10],
        ], r, { w: 1.2, alpha: 0.6 });
        ink(g, [
          [6 + i * 0.7, y],
          [18 + i * 0.3, y - 9],
        ], r, { w: 1.2, alpha: 0.6 });
      }
    },
  });
  A.topHat = makePaper({
    shape: [
      [-80, -36],
      [-48, -40],
      [-46, -168],
      [46, -172],
      [48, -40],
      [80, -36],
      [76, -24],
      [-76, -22],
    ],
    color: '#2b2730',
    edge: 'cut',
    seed: 304,
    post: (g) => {
      g.fillStyle = PAL.red;
      g.fillRect(-48, -72, 96, 22);
    },
    ink: (g, r) => ink(g, [
      [-30, -160],
      [-32, -50],
    ], r, { w: 3, color: 'rgba(255,255,255,0.25)' }),
  });
  A.beanie = makePaper({
    shapes: [
      spline([
        [-60, -22],
        [-60, -60],
        [-36, -96],
        [0, -106],
        [36, -96],
        [60, -60],
        [60, -22],
      ], false, 8).concat([[0, -16]]),
    ],
    color: PAL.red,
    edge: 'cut',
    seed: 305,
    pattern: PATTERNS.chain((g, b) => {
      g.fillStyle = PAL.white;
      g.fillRect(b.x, -48, b.w, 20);
    }, PATTERNS.stripes('rgba(0,0,0,0.08)', 4, 0)),
  });
  A.pompom = makePaper({ shape: ellipsePts(0, 0, 22, 21, 30), color: PAL.white, edge: 'torn', rim: 2, amp: 4, freq: 10, seed: 306 });
  A.helmet = makeInkSprite({ x: -78, y: -78, w: 156, h: 156 }, (g, r) => {
    g.fillStyle = 'rgba(190,225,240,0.28)';
    g.beginPath();
    g.arc(0, 0, 72, 0, TAU);
    g.fill();
    ink(g, ellipsePts(0, 0, 72, 72, 48), r, { w: 4.2, closed: true, taper: 0 });
    ink(g, arcPts(0, 0, 58, 58, Math.PI * 1.1, Math.PI * 1.45, 10), r, { w: 7, color: 'rgba(255,255,255,0.85)' });
    ink(g, arcPts(0, 0, 58, 58, Math.PI * 1.55, Math.PI * 1.62, 4), r, { w: 6, color: 'rgba(255,255,255,0.85)' });
  }, { seed: 307 });
  A.helmetRing = makePaper({ shape: roundRectPts(-62, 56, 124, 26, 10), color: '#d8d6d0', edge: 'cut', seed: 308, pattern: PATTERNS.stripes('rgba(0,0,0,0.1)', 6, 1.57) });

  const years = ['399 BC', '1641', '1887', '1969', 'TODAY'];
  A.years = years.map((y, i) => {
    const w = measure(y, FONTS.type, 46, 400) + 40;
    return makePaper({
      shape: rectPts(-w / 2, -34, w, 68),
      color: i === 4 ? PAL.mustard : PAL.white,
      edge: 'cut',
      seed: 320 + i,
      post: (g) => {
        g.font = `400 46px ${FONTS.type}`;
        g.fillStyle = i === 4 ? INK : '#3a2f2a';
        g.textAlign = 'center';
        g.fillText(y, 0, 16);
      },
    });
  });
}

function buildTitle() {
  A.titleRows = [
    { word: 'WHAT IS THE', size: 92, y: 150 },
    { word: 'PURPOSE', size: 176, y: 330 },
    { word: 'OF LIFE', size: 120, y: 510 },
  ].map((row, k) => ({ ...row, chips: ransomWord(row.word, { size: row.size, salt: k }) }));
  const q = textShapes('?', '"Abril Fatface"', 470);
  A.bigQ = makePaper({ shapes: q.shapes, color: PAL.red, edge: 'torn', rim: 8, amp: 3, seed: 41 });
}

function buildAnswers() {
  const sunR = 132;
  A.sun = makePaper({
    shape: ellipsePts(0, 0, sunR, sunR, 70),
    color: PAL.mustard,
    edge: 'torn',
    rim: 6,
    seed: 51,
    ink: (g, r) => {
      ink(g, arcPts(-44, -14, 18, 15, Math.PI * 1.1, Math.PI * 1.9, 10), r, { w: 6 });
      ink(g, arcPts(44, -14, 18, 15, Math.PI * 1.1, Math.PI * 1.9, 10), r, { w: 6 });
      ink(g, arcPts(0, 14, 48, 40, Math.PI * 0.15, Math.PI * 0.85, 16), r, { w: 6.5 });
      blush(g, -72, 26, 20, r, PAL.tomato, 0.6);
      blush(g, 72, 26, 20, r, PAL.tomato, 0.6);
    },
  });
  const rays = [];
  for (let i = 0; i < 14; i++) {
    const a = (i / 14) * TAU;
    const w = 0.13;
    const r0 = 150;
    const r1 = i % 2 ? 228 : 258;
    rays.push([
      [Math.cos(a - w) * r0, Math.sin(a - w) * r0],
      [Math.cos(a) * r1, Math.sin(a) * r1],
      [Math.cos(a + w) * r0, Math.sin(a + w) * r0],
    ]);
  }
  A.rays = makePaper({ shapes: rays, color: PAL.orange, edge: 'cut', seed: 52, maxSeg: 30 });
  A.cloud = makePaper({
    shape: spline([
      [-120, 30],
      [-130, -6],
      [-90, -40],
      [-40, -48],
      [-10, -80],
      [50, -76],
      [80, -40],
      [126, -30],
      [140, 14],
      [110, 34],
    ], true, 8),
    color: PAL.white,
    edge: 'torn',
    rim: 4,
    seed: 53,
  });

  A.halo = makePaper({ shapes: [ellipsePts(0, 0, 66, 17, 50), ellipsePts(0, 0, 48, 9, 40)], color: '#f4c542', edge: 'cut', seed: 54, maxSeg: 12, shadowBlur: 6 });
  A.heart = makePaper({ shapes: shapeFromDraw({ x: -40, y: -40, w: 80, h: 80 }, (g) => {
    heartPath(g, 0, 0, 28);
    g.fill();
  }, 2), color: PAL.red, edge: 'cut', seed: 55, maxSeg: 10 });
  A.heartPink = makePaper({ shapes: shapeFromDraw({ x: -40, y: -40, w: 80, h: 80 }, (g) => {
    heartPath(g, 0, 0, 28);
    g.fill();
  }, 2), color: PAL.pink, edge: 'cut', seed: 56, maxSeg: 10 });
  A.flower = makePaper({
    shapes: shapeFromDraw({ x: -40, y: -40, w: 80, h: 80 }, (g) => {
      for (let i = 0; i < 6; i++) {
        const a = (i / 6) * TAU;
        g.beginPath();
        g.ellipse(Math.cos(a) * 18, Math.sin(a) * 18, 12, 9, a, 0, TAU);
        g.fill();
      }
    }, 2),
    color: PAL.pink,
    edge: 'cut',
    seed: 57,
    maxSeg: 8,
    ink: (g, r) => inkDot(g, 0, 0, 9, r, PAL.mustard),
  });

  const handBox = { x: -170, y: -230, w: 340, h: 420 };
  const hs = shapeFromDraw(handBox, (g) => {
    g.beginPath();
    g.ellipse(0, 50, 98, 112, 0, 0, TAU);
    g.fill();
    g.lineWidth = 50;
    const f = [
      [-86, 52, -158, -26],
      [-56, -40, -82, -172],
      [-8, -52, -8, -206],
      [40, -46, 62, -182],
      [80, -20, 116, -118],
    ];
    for (const [x0, y0, x1, y1] of f) {
      g.beginPath();
      g.moveTo(x0, y0);
      g.lineTo(x1, y1);
      g.stroke();
    }
    for (let i = 0; i < 14; i++) {
      const a = (i / 14) * TAU;
      g.beginPath();
      g.arc(Math.cos(a) * (150 + (i % 3) * 18), 20 + Math.sin(a) * (170 + (i % 2) * 20), 4 + (i % 4) * 2.5, 0, TAU);
      g.fill();
    }
  }, 1);
  A.handprint = makePaper({
    shapes: hs,
    color: PAL.red,
    edge: 'cut',
    jitter: 1.6,
    seed: 58,
    shadow: false,
    post: (g, r) => crayonMask(g, r, 0.45, 0.9),
  });
  A.iWasHere = crayonText('I was here!', FONTS.gochi, 78, PAL.blue);

  const bun = (top) => spline(top ? [
    [-150, 10],
    [-142, -36],
    [-100, -70],
    [0, -84],
    [100, -70],
    [142, -36],
    [150, 10],
  ] : [
    [-148, -18],
    [148, -18],
    [140, 14],
    [100, 26],
    [-100, 26],
    [-140, 14],
  ], true, 6);
  A.breadTop = makePaper({
    shape: bun(true),
    color: '#e3a85c',
    edge: 'cut',
    seed: 61,
    ink: (g, r) => {
      for (let i = 0; i < 9; i++) {
        const x = -96 + i * 24 + (r() - 0.5) * 10;
        const y = -46 + Math.abs(x) * 0.18 + (r() - 0.5) * 16;
        ctxSeed(g, x, y, r);
      }
    },
  });
  A.breadBot = makePaper({ shape: bun(false), color: '#e3a85c', edge: 'cut', seed: 62 });
  const lettuce = [];
  for (let i = 0; i <= 14; i++) lettuce.push([-170 + i * 24.3, -12 + (i % 2 ? -14 : 8)]);
  for (let i = 14; i >= 0; i--) lettuce.push([-170 + i * 24.3, 14 + (i % 2 ? 10 : -4)]);
  A.lettuce = makePaper({ shape: spline(lettuce, true, 3), color: PAL.leaf, edge: 'cut', seed: 63, maxSeg: 12 });
  A.cheese = makePaper({
    shapes: [
      [
        [-150, -20],
        [150, -20],
        [162, 26],
        [128, 44],
        [108, 12],
        [-120, 14],
        [-136, 48],
        [-162, 30],
      ],
      ellipsePts(-60, -4, 10, 7, 12),
      ellipsePts(40, -2, 13, 8, 12),
      ellipsePts(132, 22, 6, 5, 10),
    ],
    color: '#f6cf45',
    edge: 'cut',
    seed: 64,
  });
  A.tomato = makePaper({
    shapes: [-90, 0, 90].map((x) => ellipsePts(x, 0, 52, 16, 30)),
    color: PAL.red,
    edge: 'cut',
    seed: 65,
  });
  A.snacks = ransomWord('SNACKS!', { size: 96, salt: 9 });
  A.lblHappy = makeLabel('happy', { color: PAL.white });
  A.lblGood = makeLabel('good', { color: PAL.white });
  A.lblMark = makeLabel('a mark', { color: PAL.white });
}

function ctxSeed(g, x, y, r) {
  g.save();
  g.translate(x, y);
  g.rotate((r() - 0.5) * 1.6);
  g.fillStyle = '#fbf0d0';
  g.beginPath();
  g.ellipse(0, 0, 6, 3, 0, 0, TAU);
  g.fill();
  g.restore();
}

function buildLooking() {
  A.magnifier = makePaper({
    shapes: shapeFromDraw({ x: -70, y: -230, w: 140, h: 250 }, (g) => {
      g.lineWidth = 16;
      g.beginPath();
      g.arc(0, -160, 52, 0, TAU);
      g.stroke();
      g.lineWidth = 20;
      g.beginPath();
      g.moveTo(0, -104);
      g.lineTo(0, 0);
      g.stroke();
    }, 2),
    color: '#3a3238',
    edge: 'cut',
    seed: 71,
    under: (g) => {
      g.fillStyle = 'rgba(180,220,235,0.55)';
      g.beginPath();
      g.arc(0, -160, 48, 0, TAU);
      g.fill();
    },
    post: (g) => {
      g.fillStyle = PAL.brown;
      g.fillRect(-11, -70, 22, 72);
    },
    ink: (g, r) => ink(g, arcPts(0, -160, 34, 34, Math.PI * 1.15, Math.PI * 1.5, 8), r, { w: 5, color: 'rgba(255,255,255,0.8)' }),
  });
  A.nightSheet = makePaper({
    shape: rectPts(-1050, -620, 2100, 1240),
    color: PAL.night,
    edge: 'torn',
    rim: 9,
    amp: 10,
    res: 0.6,
    seed: 72,
    pattern: PATTERNS.speckle('rgba(255,250,220,0.8)', 380, 0.7),
  });
  A.stars = [0, 1, 2, 3].map((i) => makePaper({ shape: spline(starPts(0, 0, 60, 27, 5), true, 3), color: i === 2 ? '#fde59a' : '#f6c945', edge: 'cut', seed: 73 + i, maxSeg: 14 }));
  A.moon = makePaper({
    shapes: shapeFromDraw({ x: -100, y: -100, w: 200, h: 200 }, (g) => {
      g.beginPath();
      g.arc(0, 0, 90, 0, TAU);
      g.fill();
      g.globalCompositeOperation = 'destination-out';
      g.beginPath();
      g.arc(42, -26, 80, 0, TAU);
      g.fill();
    }, 1),
    color: '#f5edd2',
    edge: 'torn',
    rim: 3,
    seed: 77,
    ink: (g, r) => {
      inkDot(g, -52, -6, 4.5, r);
      ink(g, arcPts(-40, 34, 12, 8, Math.PI * 0.2, Math.PI * 0.9, 8), r, { w: 3.2 });
    },
  });
  A.ladder = makePaper({
    shapes: shapeFromDraw({ x: -90, y: -800, w: 180, h: 820 }, (g) => {
      g.lineWidth = 22;
      g.beginPath();
      g.moveTo(-62, 10);
      g.lineTo(-48, -790);
      g.moveTo(62, 10);
      g.lineTo(50, -790);
      g.stroke();
      g.lineWidth = 15;
      for (let y = -60; y > -780; y -= 84) {
        g.beginPath();
        g.moveTo(-60 - y * 0.017, y);
        g.lineTo(60 + y * 0.016, y + 3);
        g.stroke();
      }
    }, 1),
    color: PAL.kraft,
    edge: 'cut',
    seed: 78,
    res: 1,
    pattern: PATTERNS.stripes('rgba(90,50,20,0.12)', 3, 0.05),
  });
  A.net = makeInkSprite({ x: -60, y: -330, w: 120, h: 340 }, (g, r) => {
    ink(g, [
      [0, 0],
      [0, -230],
    ], r, { w: 7, color: PAL.brown, taper: 0.1 });
    g.save();
    g.beginPath();
    g.ellipse(0, -280, 48, 50, 0, 0, TAU);
    g.clip();
    for (let k = -60; k < 60; k += 11) {
      ink(g, [
        [k, -340],
        [k + 50, -220],
      ], r, { w: 1.2, alpha: 0.6, taper: 0 });
      ink(g, [
        [k + 50, -340],
        [k, -220],
      ], r, { w: 1.2, alpha: 0.6, taper: 0 });
    }
    g.restore();
    ink(g, ellipsePts(0, -280, 48, 50, 40), r, { w: 4, closed: true, taper: 0 });
  }, { seed: 79 });
  A.rock = makePaper({
    shape: spline([
      [-160, 0],
      [-150, -60],
      [-100, -110],
      [-20, -128],
      [70, -118],
      [140, -76],
      [168, -10],
      [150, 4],
    ], true, 8),
    color: PAL.stone,
    edge: 'torn',
    rim: 5,
    amp: 6,
    seed: 81,
    pattern: PATTERNS.speckle('rgba(60,55,50,0.6)', 240, 0.5),
    ink: (g, r) => {
      ink(g, [
        [-60, -96],
        [-40, -70],
        [-52, -46],
      ], r, { w: 2.6, alpha: 0.6 });
      ink(g, [
        [70, -100],
        [84, -78],
      ], r, { w: 2.6, alpha: 0.6 });
    },
  });
  A.worm = makePaper({
    shapes: shapeFromDraw({ x: -60, y: -190, w: 120, h: 200 }, (g) => {
      g.lineWidth = 30;
      g.beginPath();
      g.moveTo(0, 0);
      g.bezierCurveTo(-34, -40, 30, -80, 0, -120);
      g.bezierCurveTo(-14, -140, -6, -160, 6, -164);
      g.stroke();
    }, 2),
    color: '#f19aa8',
    edge: 'cut',
    seed: 82,
    ink: (g, r) => {
      inkDot(g, -2, -166, 3.4, r);
      inkDot(g, 12, -164, 3.4, r);
      ink(g, arcPts(6, -156, 7, 5, Math.PI * 0.15, Math.PI * 0.85, 8), r, { w: 2.4 });
      for (const y of [-30, -60, -92]) ink(g, [
        [-12, y],
        [10, y - 4],
      ], r, { w: 2, alpha: 0.45 });
    },
  });
  const grass = [];
  for (let i = 0; i <= 24; i++) grass.push([-420 + i * 35, i % 2 ? -46 - (i % 3) * 8 : -8]);
  grass.push([420, 30], [-420, 30]);
  A.grass = makePaper({ shape: grass, color: PAL.green, edge: 'cut', seed: 83, maxSeg: 30 });
  A.bookClosed = makePaper({
    shape: rectPts(-210, -560, 420, 560),
    color: '#b8433a',
    edge: 'cut',
    seed: 84,
    post: (g) => {
      g.fillStyle = 'rgba(0,0,0,0.18)';
      g.fillRect(-210, -560, 46, 560);
      g.fillStyle = '#f2c14e';
      g.fillRect(-120, -470, 290, 6);
      g.fillRect(-120, -330, 290, 6);
    },
    ink: (g, r) => {
      handText(g, 'VERY', 25, -420, r, { size: 62, font: FONTS.marker, align: 'center', color: '#f6dd8a', weight: 400 });
      handText(g, 'BIG', 25, -362, r, { size: 62, font: FONTS.marker, align: 'center', color: '#f6dd8a', weight: 400 });
      handText(g, 'BOOK', 25, -272, r, { size: 62, font: FONTS.marker, align: 'center', color: '#f6dd8a', weight: 400 });
      handText(g, 'vol. 1', 25, -200, r, { size: 40, font: FONTS.hand, align: 'center', color: '#f6dd8a' });
    },
  });
  A.bookCover = makePaper({ shape: rectPts(-430, -580, 860, 590), color: '#b8433a', edge: 'cut', seed: 85 });
  const page = (side) => makePaper({
    shape: side < 0 ? [
      [-400, -548],
      [-10, -530],
      [-10, -14],
      [-400, -24],
    ] : [
      [10, -530],
      [400, -548],
      [400, -24],
      [10, -14],
    ],
    color: '#f4ecd8',
    edge: 'cut',
    seed: 86 + side,
    pattern: (g, b, r) => {
      g.save();
      g.fillStyle = 'rgba(60,50,40,0.5)';
      for (let y = -500; y < -50; y += 26) {
        const x0 = side < 0 ? -370 : 40;
        let x = x0;
        while (x < x0 + 320) {
          const w = 14 + r() * 50;
          g.fillRect(x, y, Math.min(w, x0 + 330 - x), 6);
          x += w + 9;
        }
      }
      g.restore();
    },
    shadow: false,
  });
  A.pageL = page(-1);
  A.pageR = page(1);
  A.flipPage = makePaper({
    shape: [
      [0, -530],
      [390, -548],
      [390, -24],
      [0, -14],
    ],
    color: '#f8f1e0',
    edge: 'cut',
    seed: 89,
    pattern: PATTERNS.lined('rgba(60,50,40,0.18)', 26, false),
  });
  A.bang = crayonText('!', FONTS.marker, 140, PAL.red);
}

function buildMaking() {
  const blade = (side) => shapeFromDraw({ x: -80, y: -260, w: 160, h: 380 }, (g) => {
    g.beginPath();
    g.moveTo(-18 * side, 14);
    g.quadraticCurveTo(-24 * side, -120, -4 * side, -246);
    g.lineTo(6 * side, -250);
    g.quadraticCurveTo(22 * side, -130, 18 * side, 14);
    g.closePath();
    g.fill();
    g.lineWidth = 16;
    g.beginPath();
    g.moveTo(0, 0);
    g.lineTo(20 * side, 52);
    g.stroke();
  }, 2);
  const loop = (side) => [ellipsePts(30 * side, 92, 34, 40, 40), ellipsePts(30 * side, 92, 20, 26, 30)];
  A.scissorBlade = [-1, 1].map((side) => makePaper({
    shapes: blade(side),
    color: '#c4cad0',
    edge: 'cut',
    seed: 91 + side,
    maxSeg: 20,
    ink: (g, r) => ink(g, [
      [4 * side, -10],
      [8 * side, -200],
    ], r, { w: 2.2, color: 'rgba(255,255,255,0.8)' }),
  }));
  A.scissorLoop = [-1, 1].map((side) => makePaper({ shapes: loop(side), color: PAL.red, edge: 'cut', seed: 95 + side, maxSeg: 12 }));
  A.board = makePaper({
    shape: rectPts(-640, -400, 1280, 800),
    color: PAL.kraft,
    edge: 'cut',
    maxSeg: 80,
    jitter: 1.5,
    seed: 97,
    res: 0.8,
    pattern: PATTERNS.chain(PATTERNS.stripes('rgba(120,80,40,0.06)', 9, 0), PATTERNS.speckle('rgba(80,50,20,0.5)', 400, 0.4)),
    shadowBlur: 10,
  });
  const scrapPatterns = [
    ['#e9e4d6', PATTERNS.newsprint(9)],
    [PAL.pink, PATTERNS.dots('rgba(255,255,255,0.7)', 20, 4)],
    [PAL.sky, PATTERNS.stripes('rgba(255,255,255,0.55)', 8, 0.8)],
    [PAL.white, PATTERNS.gingham(PAL.red, 12, 0.35)],
    ['#f4ecd8', PATTERNS.staff()],
    [PAL.white, PATTERNS.grid()],
    [PAL.mustard, PATTERNS.halftone('rgba(180,80,20,0.35)', 8)],
    [PAL.sage, PATTERNS.dots('rgba(40,60,30,0.25)', 14, 2.5)],
    [PAL.lilac, PATTERNS.stripes('rgba(255,255,255,0.4)', 5, -0.4)],
    [PAL.white, PATTERNS.lined()],
    [PAL.teal, PATTERNS.gingham(PAL.white, 10, 0.3)],
    [PAL.tomato, PATTERNS.dots('rgba(255,240,200,0.6)', 24, 6)],
  ];
  A.scraps = scrapPatterns.map(([c, p], i) => {
    const r = rng(500 + i);
    const w = rr(r, 90, 170);
    const h = rr(r, 70, 130);
    const shape = [];
    const n = 5 + Math.floor(r() * 3);
    for (let k = 0; k < n; k++) {
      const a = (k / n) * TAU + rr(r, -0.25, 0.25);
      shape.push([Math.cos(a) * w * rr(r, 0.75, 1), Math.sin(a) * h * rr(r, 0.75, 1)]);
    }
    return makePaper({ shape, color: c, pattern: p, edge: r() < 0.6 ? 'torn' : 'cut', rim: 4, seed: 510 + i, res: 1 });
  });

  A.cupBody = makePaper({
    shapes: shapeFromDraw({ x: -150, y: -110, w: 300, h: 220 }, (g) => {
      g.beginPath();
      g.moveTo(-88, -74);
      g.lineTo(88, -74);
      g.lineTo(74, 30);
      g.quadraticCurveTo(66, 74, 0, 76);
      g.quadraticCurveTo(-66, 74, -74, 30);
      g.closePath();
      g.fill();
      g.lineWidth = 22;
      g.beginPath();
      g.ellipse(94, -6, 34, 38, 0, -Math.PI * 0.6, Math.PI * 0.55);
      g.stroke();
    }, 2),
    color: PAL.teal,
    edge: 'cut',
    seed: 101,
    pattern: PATTERNS.dots('rgba(255,255,255,0.75)', 30, 6),
    ink: (g, r) => {
      g.save();
      g.fillStyle = '#5b3622';
      g.beginPath();
      g.ellipse(0, -72, 86, 13, 0, 0, TAU);
      g.fill();
      g.restore();
      ink(g, ellipsePts(0, -72, 87, 14, 40), r, { w: 3, closed: true, taper: 0 });
    },
  });
  A.saucer = makePaper({ shape: ellipsePts(0, 0, 140, 26, 50), color: PAL.white, edge: 'cut', seed: 102, pattern: PATTERNS.stripes('rgba(47,156,149,0.25)', 6, 0) });

  A.faceA = makePaper({ shape: ellipsePts(0, 0, 70, 72, 50), color: PAL.skin, edge: 'cut', seed: 103, ink: (g, r) => {
    blush(g, -40, 22, 16, r);
    blush(g, 40, 22, 16, r);
  }, variants: 1 });
  A.faceB = makePaper({ shape: ellipsePts(0, 0, 66, 70, 50), color: PAL.skin3, edge: 'cut', seed: 104, ink: (g, r) => {
    blush(g, -38, 22, 15, r, '#c4626a');
    blush(g, 38, 22, 15, r, '#c4626a');
  }, variants: 1 });
  A.hairA = makePaper({ shape: HAIR.tuft.map(([x, y]) => [x * 1.4, y * 1.4]), color: '#c4632e', edge: 'cut', seed: 105 });
  A.hairB = makePaper({ shape: HAIR.curly.map(([x, y]) => [x * 1.3, y * 1.3]), color: '#241a18', edge: 'cut', seed: 106 });
  A.ha1 = crayonText('HA', FONTS.marker, 74, PAL.red);
  A.ha2 = crayonText('HA!', FONTS.marker, 64, PAL.blue);
  A.ha3 = crayonText('ha', FONTS.marker, 54, PAL.teal);

  const q = textShapes('?', '"Shrikhand"', 300);
  A.curlyQ = makePaper({ shapes: q.shapes, color: PAL.orange, edge: 'cut', seed: 107, pattern: PATTERNS.stripes('rgba(255,255,255,0.25)', 7, 0.7) });

  A.dog = makePaper({
    shapes: shapeFromDraw({ x: -200, y: -200, w: 420, h: 280 }, (g) => {
      g.beginPath();
      g.ellipse(-20, 0, 120, 58, 0, 0, TAU);
      g.fill();
      g.beginPath();
      g.ellipse(110, -66, 62, 56, 0, 0, TAU);
      g.fill();
      g.beginPath();
      g.ellipse(164, -48, 34, 26, 0.2, 0, TAU);
      g.fill();
    }, 1),
    color: '#fbf3e3',
    edge: 'cut',
    seed: 108,
    post: (g) => {
      g.fillStyle = PAL.brown;
      g.beginPath();
      g.ellipse(-50, -14, 44, 34, 0.3, 0, TAU);
      g.fill();
      g.beginPath();
      g.ellipse(86, -94, 26, 22, 0.3, 0, TAU);
      g.fill();
    },
    ink: (g, r) => {
      inkDot(g, 124, -78, 7, r);
      g.save();
      g.fillStyle = 'rgba(255,255,255,0.9)';
      g.beginPath();
      g.arc(126, -81, 2, 0, TAU);
      g.fill();
      g.restore();
      inkDot(g, 194, -56, 9, r);
      ink(g, arcPts(170, -38, 18, 12, Math.PI * 0.1, Math.PI * 0.8, 8), r, { w: 3.2 });
      blush(g, 136, -46, 12, r);
    },
  });
  A.dogEar = makePaper({
    shape: spline([
      [0, 0],
      [22, 6],
      [26, 50],
      [10, 82],
      [-8, 70],
      [-12, 30],
    ], true, 6),
    color: PAL.brown,
    edge: 'cut',
    seed: 109,
  });
  A.tongue = makePaper({ shape: spline([
    [-10, 0],
    [10, 0],
    [12, 18],
    [0, 26],
    [-12, 18],
  ], true, 5), color: PAL.tomato, edge: 'cut', seed: 110, shadowBlur: 2 });
}

function buildGlue() {
  const cells = { x: -250, y: -190, cw: 71, ch: 74 };
  A.calendar = makePaper({
    shape: rectPts(-270, -330, 540, 640),
    color: PAL.white,
    edge: 'cut',
    seed: 121,
    maxSeg: 60,
    post: (g) => {
      g.fillStyle = PAL.red;
      g.fillRect(-270, -330, 540, 110);
      g.font = `400 64px "Bowlby One"`;
      g.fillStyle = PAL.white;
      g.textAlign = 'center';
      g.fillText('OCTOBER', 0, -250);
      g.font = `400 26px ${FONTS.type}`;
      g.fillStyle = '#5a4a40';
      'MTWTFSS'.split('').forEach((d, i) => g.fillText(d, cells.x + cells.cw * (i + 0.5), -200));
      g.strokeStyle = 'rgba(60,50,40,0.35)';
      g.lineWidth = 1.5;
      for (let i = 0; i <= 7; i++) {
        g.beginPath();
        g.moveTo(cells.x + i * cells.cw, cells.y);
        g.lineTo(cells.x + i * cells.cw, cells.y + cells.ch * 6);
        g.stroke();
      }
      for (let j = 0; j <= 6; j++) {
        g.beginPath();
        g.moveTo(cells.x, cells.y + j * cells.ch);
        g.lineTo(cells.x + cells.cw * 7, cells.y + j * cells.ch);
        g.stroke();
      }
      g.textAlign = 'left';
      g.font = `400 22px ${FONTS.courier}`;
      g.fillStyle = '#3a2f2a';
      for (let d = 1; d <= 31; d++) {
        const k = d + 2;
        const col = k % 7;
        const row = Math.floor(k / 7);
        g.fillText(String(d), cells.x + col * cells.cw + 6, cells.y + row * cells.ch + 24);
      }
    },
  });
  A.calCells = cells;
  const pieces = [];
  const r = rng(122);
  for (let i = 0; i < 4; i++) {
    const shape = spline([
      [-58, -50],
      [10, -64],
      [60, -40],
      [52, 30],
      [8, 58],
      [-56, 40],
    ].map(([x, y]) => [x * rr(r, 0.9, 1.1), y * rr(r, 0.9, 1.1)]), true, 4);
    pieces.push(makePaper({
      shape,
      color: PAL.white,
      edge: 'cut',
      seed: 130 + i,
      pattern: PATTERNS.grid('rgba(60,50,40,0.28)', 71),
      post: (g) => {
        g.font = `400 34px ${FONTS.courier}`;
        g.fillStyle = '#3a2f2a';
        g.fillText(String([12, 14, 19, 27][i]), -36, -10);
      },
      ink: (g, rr2) => {
        if (i === 1) ink(g, spline(ellipsePts(-12, -20, 36, 28, 10)), rr2, { w: 3.5, color: PAL.red, closed: true, taper: 0 });
        if (i === 2) ink(g, [
          [-30, 20],
          [-10, 34],
          [30, -6],
        ], rr2, { w: 4, color: PAL.blue });
      },
    }));
  }
  A.dayPieces = pieces;
  A.glueStick = makePaper({
    shapes: [roundRectPts(-36, -150, 72, 210, 12)],
    color: PAL.white,
    edge: 'cut',
    seed: 141,
    post: (g) => {
      g.fillStyle = PAL.orange;
      g.fillRect(-40, -150, 80, 64);
      g.fillStyle = PAL.blue;
      g.fillRect(-40, -40, 80, 56);
      g.font = `400 34px "Bowlby One"`;
      g.fillStyle = PAL.white;
      g.textAlign = 'center';
      g.fillText('GLUE', 0, 0);
    },
  });
  A.tapeRoll = makePaper({ shapes: [ellipsePts(0, 0, 58, 58, 40), ellipsePts(0, 0, 34, 34, 30)], color: 'rgba(236,222,180,0.92)', edge: 'cut', seed: 142, maxSeg: 14 });
  A.tapes = [0, 1, 2, 3, 4, 5].map((i) => makeTape(110 + (i % 3) * 18, 34, 150 + i));
  A.friendTeal = makePerson({ seed: 21, body: PAL.teal, hairShape: HAIR.bob, hair: '#7a3b22', skin: PAL.skin2, bodyPattern: PATTERNS.stripes('rgba(255,255,255,0.22)', 9, 0), size: 0.95 });
  A.friendRed = makePerson({ seed: 31, body: PAL.tomato, hairShape: HAIR.curly, hair: '#241a18', skin: PAL.skin3, bodyPattern: PATTERNS.dots('rgba(255,240,210,0.6)', 22, 4.5), size: 0.88 });
  A.friendLilac = makePerson({ seed: 41, body: PAL.lilac, hairShape: HAIR.tuft, hair: '#e6c26a', skin: PAL.skin, size: 0.72, buttons: false });
}

function buildFinale() {
  A.fish = makePaper({
    shapes: shapeFromDraw({ x: -150, y: -80, w: 300, h: 160 }, (g) => {
      g.beginPath();
      g.ellipse(-10, 0, 100, 52, 0, 0, TAU);
      g.fill();
      g.beginPath();
      g.moveTo(80, 0);
      g.lineTo(140, -48);
      g.lineTo(130, 0);
      g.lineTo(140, 48);
      g.closePath();
      g.fill();
    }, 1),
    color: PAL.blue,
    edge: 'cut',
    seed: 161,
    pattern: PATTERNS.chain((g) => {
      g.fillStyle = 'rgba(255,255,255,0.18)';
      for (let x = -60; x < 80; x += 26) for (let y = -40; y < 50; y += 22) {
        g.beginPath();
        g.arc(x + (y % 44 ? 13 : 0), y, 10, 0, Math.PI);
        g.fill();
      }
    }),
    ink: (g, r) => {
      inkDot(g, -72, -10, 7, r);
      ink(g, arcPts(-92, 14, 12, 8, Math.PI * 0.1, Math.PI * 0.7, 8), r, { w: 3 });
      ink(g, arcPts(-30, 0, 30, 44, -Math.PI * 0.4, Math.PI * 0.4, 10), r, { w: 3, alpha: 0.6 });
    },
  });
  A.mine = crayonText('mine', FONTS.gochi, 96, PAL.red, { bite: 0.5 });
  A.soWhat = null;
}

function buildArt() {
  A.bgCream = makeBackdrop(2600, 1500, PAL.paper, 3);
  A.bgWarm = makeBackdrop(2600, 1500, '#f1dcc0', 4);
  A.bgEnd = makeBackdrop(2200, 1300, '#ece0c6', 5, { pattern: PATTERNS.lined('rgba(80,130,200,0.18)', 46, false) });
  A.panels = [
    makePaper({ shape: rectPts(-980, -560, 1960, 1120), color: PAL.sky, edge: 'torn', rim: 8, amp: 8, res: 0.6, seed: 201, shadowBlur: 12 }),
    makePaper({ shape: rectPts(-980, -560, 1960, 1120), color: PAL.pink, edge: 'torn', rim: 8, amp: 8, res: 0.6, seed: 202, pattern: PATTERNS.dots('rgba(255,255,255,0.35)', 60, 9), shadowBlur: 12 }),
    makePaper({ shape: rectPts(-980, -560, 1960, 1120), color: PAL.kraft, edge: 'torn', rim: 8, amp: 8, res: 0.6, seed: 203, pattern: PATTERNS.speckle('rgba(80,50,20,0.5)', 900, 0.4), shadowBlur: 12 }),
    makePaper({ shape: rectPts(-980, -560, 1960, 1120), color: PAL.mustard, edge: 'torn', rim: 8, amp: 8, res: 0.6, seed: 204, pattern: PATTERNS.gingham(PAL.white, 46, 0.22), shadowBlur: 12 }),
  ];
  A.groundStrip = makePaper({ shape: rectPts(-1100, -60, 2200, 300), color: '#d9c7a4', edge: 'torn', rim: 6, amp: 6, res: 0.6, seed: 205, pattern: PATTERNS.speckle('rgba(80,50,20,0.4)', 500, 0.4) });
  A.pip = makePerson({ seed: 11, body: PAL.mustard, hairShape: HAIR.tuft, hair: '#3b2a20' });
  A.tape = makeTape(140, 38, 5);
  buildHats();
  buildTitle();
  buildAnswers();
  buildLooking();
  buildMaking();
  buildGlue();
  buildFinale();
}
