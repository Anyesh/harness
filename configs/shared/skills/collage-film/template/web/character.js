'use strict';

const HEAD_R = 50;
const SHOULDER = [36, -192];
const HIP = [21, -100];
const UPPER = 50;
const FORE = 46;
const THIGH = 50;
const SHIN = 50;

function makePerson(spec) {
  const seed = spec.seed ?? 1;
  const r = rng(seed);
  const torso = spec.torso ?? TORSO;
  const body = makeTorso({ ...spec, torso, seed: seed + 1 });
  const head = makePaper({
    shape: ellipsePts(0, 0, HEAD_R, HEAD_R * 1.02, 60),
    color: spec.skin ?? PAL.skin,
    edge: 'cut',
    seed: seed + 2,
    maxSeg: 18,
    ink: (g, rr2) => {
      blush(g, -29, 16, 12, rr2, PAL.blush, 0.55);
      blush(g, 29, 16, 12, rr2, PAL.blush, 0.55);
    },
    variants: 1,
  });
  const hair = spec.hairShape ? makePaper({ shape: spec.hairShape, color: spec.hair ?? '#3b2a20', edge: 'cut', seed: seed + 3, shadowBlur: 3, ink: spec.hairInk }) : null;
  const hairBack = spec.hairBack ? makePaper({ shapes: spec.hairBack, color: shadeColor(spec.hair ?? '#3b2a20', -0.08), edge: 'cut', seed: seed + 6, shadowBlur: 3, ink: spec.hairBackInk }) : null;
  const hand = makePaper({ shape: ellipsePts(0, 0, 9.5, 9, 20), color: spec.skin ?? PAL.skin, edge: 'cut', seed: seed + 4, shadowBlur: 2, maxSeg: 8 });
  const shoe = makePaper({
    shape: spline([
      [-14, -2],
      [-10, -12],
      [6, -13],
      [22, -6],
      [20, 2],
      [-12, 3],
    ], true, 5),
    color: spec.shoe ?? '#3a2f33',
    edge: 'cut',
    seed: seed + 5,
    shadowBlur: 2,
  });
  return { spec, body, head, hair, hairBack, hand, shoe, seed, r };
}


const TORSO = [
  [-30, -208],
  [30, -208],
  [44, -196],
  [50, -170],
  [60, -98],
  [-60, -98],
  [-50, -170],
  [-44, -196],
];

// An outfit top: same cut as the rig's torso so it can replace pose.body without shifting shoulders or hem.
function makeTorso(spec) {
  const seed = spec.seed ?? 1;
  const torso = spec.torso ?? TORSO;
  return makePaper({
    shape: torso,
    color: spec.body,
    pattern: spec.bodyPattern,
    edge: 'cut',
    seed,
    ink: (g, rr2) => {
      ink(g, [
        [-12, -206],
        [0, -188],
        [12, -206],
      ], rr2, { w: 3.2, jit: 0.8 });
      if (spec.buttons !== false) {
        inkDot(g, 0, -168, 3.6, rr2);
        inkDot(g, 0, -146, 3.6, rr2);
        inkDot(g, 0, -124, 3.6, rr2);
      }
      ink(g, [
        [-56, -103],
        [-20, -101],
        [22, -104],
        [57, -102],
      ], rr2, { w: 2.2, jit: 0.8, alpha: 0.5 });
    },
  });
}

// Long wavy hair with a top bun, drawn behind the head. The notch under the chin keeps the neck clear so it never reads as a beard.
function longHairBack() {
  return shapeFromDraw({ x: -90, y: -120, w: 180, h: 220 }, (g) => {
    tracePath(g, spline([[-60, -10], [-58, -42], [-40, -62], [0, -68], [40, -62], [58, -42], [62, -10], [68, 20], [60, 42], [70, 64], [56, 82], [38, 74], [34, 40], [-34, 40], [-38, 74], [-56, 82], [-70, 64], [-60, 42], [-68, 20]], true, 6));
    g.fill();
    g.beginPath();
    g.arc(0, -84, 24, 0, TAU);
    g.fill();
  }, 1);
}

const HAIR = {
  bangs: spline([[-55, 2], [-54, -30], [-36, -52], [-6, -60], [26, -56], [48, -38], [56, -8], [52, 6], [44, -12], [32, -22], [20, -16], [10, -28], [-4, -20], [-16, -32], [-30, -22], [-42, -28], [-48, -10]], true, 5),
  tuft: [
    [-50, -8],
    [-46, -30],
    [-30, -46],
    [-6, -54],
    [18, -52],
    [38, -42],
    [50, -20],
    [50, -6],
    [36, -22],
    [20, -28],
    [8, -22],
    [-6, -30],
    [-24, -24],
    [-38, -14],
  ],
  bob: [
    [-56, 30],
    [-58, -10],
    [-46, -40],
    [-20, -56],
    [12, -56],
    [42, -42],
    [56, -12],
    [56, 32],
    [42, 30],
    [40, -8],
    [24, -24],
    [0, -26],
    [-22, -20],
    [-40, -6],
    [-42, 32],
  ],
  curly: (() => {
    const pts = [];
    const n = 11;
    for (let i = 0; i <= n; i++) {
      const a = Math.PI + (i / n) * Math.PI;
      const rad = 56 + (i % 2 ? 9 : 0);
      pts.push([Math.cos(a) * rad, Math.sin(a) * rad * 0.95 + 4]);
    }
    pts.push([46, 2], [30, -22], [6, -28], [-20, -24], [-40, -8], [-48, 6]);
    return pts;
  })(),
};

function limb(base, a1, a2, l1, l2, side) {
  const e = [base[0] + Math.sin(a1) * l1 * side, base[1] + Math.cos(a1) * l1];
  const h = [e[0] + Math.sin(a1 + a2) * l2 * side, e[1] + Math.cos(a1 + a2) * l2];
  return [base, e, h];
}

function rotPt(p, a) {
  const c = Math.cos(a);
  const s = Math.sin(a);
  return [p[0] * c - p[1] * s, p[0] * s + p[1] * c];
}

/*
 * Pose fields (all optional): x, y, scale, flip, rot, bob, armL/armR/legL/legR as [hipAngle, kneeAngle],
 * head: {rot, dx, dy}, expr, look [x,y], blink, hat(ctx, t, r) drawn in head space, front(ctx, hands) drawn after arms.
 * Outfits: body (a makeTorso sprite), pants {color, w, length}, shoe (sprite) override the person's defaults.
 * Returns world positions of both hands so props can be attached to them.
 */
function drawPerson(ctx, P, pose, t) {
  const s = (pose.scale ?? 1) * (P.spec.size ?? 1);
  const flip = pose.flip ? -1 : 1;
  const v = boilIndex(t, 3, P.seed % 3);
  const r = rng(hash(P.seed, v));
  const armL = pose.armL ?? [0.18, 0.1];
  const armR = pose.armR ?? [0.18, 0.1];
  const legL = pose.legL ?? [0.05, 0];
  const legR = pose.legR ?? [0.05, 0];
  const bob = pose.bob ?? 0;
  const lw = 6.2;

  ctx.save();
  ctx.translate(pose.x, pose.y);
  ctx.scale(s * flip, s * (pose.squash ?? 1));
  ctx.rotate(pose.rot ?? 0);
  const out = {};

  for (const [leg, side] of [
    [legL, -1],
    [legR, 1],
  ]) {
    const hip = [HIP[0] * side, HIP[1] + bob];
    const pts = limb(hip, leg[0], leg[1], THIGH, SHIN, side);
    ink(ctx, spline(pts, false, 6), r, { w: lw, jit: 0.9, taper: 0.15 });
    const pants = pose.pants ?? P.spec.pants;
    if (pants) {
      const k = pants.length ?? 0.78;
      const knee = pts[1];
      const cuff = [lerp(knee[0], pts[2][0], k), lerp(knee[1], pts[2][1], k)];
      const leg = spline([[hip[0] * 0.8, hip[1] - 6], knee, cuff], false, 6);
      ink(ctx, leg, r, { w: (pants.w ?? 26) + 3, color: shadeColor(pants.color, -0.35), jit: 0.5, taper: 0 });
      ink(ctx, leg, r, { w: pants.w ?? 26, color: pants.color, jit: 0.5, taper: 0 });
    }
    const f = pts[2];
    (pose.shoe ?? P.shoe).draw(ctx, f[0] + side * 4, f[1] + 2, { v, sx: side, rot: (pose.footRot ?? 0) * side, shadowAlpha: 0.3 });
  }

  ctx.save();
  ctx.translate(0, bob);
  (pose.body ?? P.body).draw(ctx, 0, 0, { v, rot: pose.bodyRot ?? 0, shadowAlpha: 0.35 });
  ctx.restore();

  const hands = [];
  for (const [arm, side] of [
    [armL, -1],
    [armR, 1],
  ]) {
    const sh = [SHOULDER[0] * side, SHOULDER[1] + bob];
    const pts = limb(sh, arm[0], arm[1], UPPER, FORE, side);
    ink(ctx, spline(pts, false, 6), r, { w: lw, jit: 0.9, taper: 0.15 });
    hands.push(pts[2]);
  }

  const hd = pose.head ?? {};
  ctx.save();
  ctx.translate((hd.dx ?? 0) + 0, -262 + bob + (hd.dy ?? 0));
  ctx.rotate(hd.rot ?? 0);
  if (pose.behindHead) pose.behindHead(ctx, t, r);
  if (P.hairBack) P.hairBack.draw(ctx, 0, 0, { v, shadowAlpha: 0.3 });
  P.head.draw(ctx, 0, 0, { v: 0, shadowAlpha: 0.38 });
  drawFace(ctx, pose, t, r, P);
  if (P.hair) P.hair.draw(ctx, 0, 0, { v, shadowAlpha: 0.3 });
  if (P.spec.adorn) P.spec.adorn(ctx, r, v);
  if (pose.hat) pose.hat(ctx, t, r);
  ctx.restore();

  for (let i = 0; i < 2; i++) {
    const h = hands[i];
    if (!(pose.hideHand && pose.hideHand[i])) P.hand.draw(ctx, h[0], h[1], { shadowAlpha: 0.3 });
  }
  if (pose.front) pose.front(ctx, hands, t, r);

  ctx.restore();
  const rot = pose.rot ?? 0;
  for (let i = 0; i < 2; i++) {
    const p = rotPt(hands[i], rot);
    out[i ? 'handR' : 'handL'] = [pose.x + p[0] * s * flip, pose.y + p[1] * s];
  }
  const hp = rotPt([0, -262 + bob], rot);
  out.head = [pose.x + hp[0] * s * flip, pose.y + hp[1] * s];
  return out;
}

function drawFace(ctx, pose, t, r, P) {
  const expr = pose.expr ?? 'smile';
  const lx = (pose.look?.[0] ?? 0) * 7;
  const ly = (pose.look?.[1] ?? 0) * 5;
  const ex = 17;
  const ey = -4;
  const blink = pose.blink ?? false;
  const eyes = pose.eyes ?? (expr === 'joy' ? 'happy' : 'dot');
  for (const side of [-1, 1]) {
    const x = side * ex + lx;
    const y = ey + ly;
    if (blink || eyes === 'closed') {
      ink(ctx, [
        [x - 6, y + 1],
        [x, y + 2.5],
        [x + 6, y + 1],
      ], r, { w: 3.2, jit: 0.4 });
    } else if (eyes === 'happy') {
      ink(ctx, arcPts(x, y + 4, 7, 7, Math.PI * 1.1, Math.PI * 1.9, 8), r, { w: 3.4, jit: 0.4 });
    } else if (eyes === 'heart') {
      ctx.save();
      ctx.fillStyle = PAL.red;
      ctx.translate(x, y);
      ctx.scale(0.55, 0.55);
      ctx.beginPath();
      ctx.moveTo(0, 8);
      ctx.bezierCurveTo(-18, -4, -10, -18, 0, -8);
      ctx.bezierCurveTo(10, -18, 18, -4, 0, 8);
      ctx.fill();
      ctx.restore();
    } else if (eyes === 'wide') {
      ctx.save();
      ctx.fillStyle = PAL.white;
      ctx.beginPath();
      ctx.arc(x, y, 8, 0, TAU);
      ctx.fill();
      ctx.restore();
      ink(ctx, ellipsePts(x, y, 8, 8, 16), r, { w: 2.2, jit: 0.3, closed: true, taper: 0 });
      inkDot(ctx, x + lx * 0.3, y + ly * 0.3, 4, r);
    } else {
      inkDot(ctx, x, y, 5.2, r);
      ctx.save();
      ctx.fillStyle = 'rgba(255,255,255,0.85)';
      ctx.beginPath();
      ctx.arc(x + 1.6, y - 1.8, 1.5, 0, TAU);
      ctx.fill();
      ctx.restore();
    }
  }
  if (P.spec.lashes && !blink && eyes !== 'closed' && eyes !== 'heart') {
    for (const side of [-1, 1]) {
      const x = side * ex + lx;
      const y = ey + ly - (eyes === 'happy' ? 0 : eyes === 'wide' ? 4 : 2);
      ink(ctx, [[x + side * 5, y - 2], [x + side * 10, y - 7]], r, { w: 2.2, jit: 0.3 });
      ink(ctx, [[x + side * 1, y - 4], [x + side * 3, y - 10]], r, { w: 2, jit: 0.3 });
    }
  }
  if (P.spec.freckles) {
    for (const side of [-1, 1]) {
      for (const [fx, fy] of [[24, 8], [31, 5], [28, 13]]) inkDot(ctx, side * fx, fy, 1.5, r, '#a0603f');
    }
  }
  if (pose.brows) {
    const [bl, br] = pose.brows;
    ink(ctx, [
      [-24 + lx, -18 + ly - bl],
      [-11 + lx, -20 + ly - bl * 1.3],
    ], r, { w: 3, jit: 0.3 });
    ink(ctx, [
      [11 + lx, -20 + ly - br * 1.3],
      [24 + lx, -18 + ly - br],
    ], r, { w: 3, jit: 0.3 });
  }
  const mx = lx * 0.7;
  const my = 19 + ly * 0.5;
  const mouth = pose.mouth ?? (expr === 'joy' ? 'open' : expr === 'wow' ? 'o' : expr === 'flat' ? 'flat' : expr === 'sad' ? 'sad' : 'smile');
  if (mouth === 'smile') {
    ink(ctx, arcPts(mx, my - 6, 11, 8, Math.PI * 0.18, Math.PI * 0.82, 10), r, { w: 3.2, jit: 0.4 });
  } else if (mouth === 'open') {
    const pts = arcPts(mx, my - 4, 13, 12, 0, Math.PI, 12);
    ctx.save();
    ctx.fillStyle = '#5a2a2a';
    tracePath(ctx, pts);
    ctx.fill();
    ctx.fillStyle = PAL.tomato;
    ctx.beginPath();
    ctx.ellipse(mx, my + 4, 7, 4, 0, 0, TAU);
    ctx.fill();
    ctx.restore();
    ink(ctx, pts.concat([pts[0]]), r, { w: 2.6, jit: 0.3, taper: 0.2 });
  } else if (mouth === 'o') {
    ctx.save();
    ctx.fillStyle = '#5a2a2a';
    ctx.beginPath();
    ctx.ellipse(mx, my, 5.5, 7, 0, 0, TAU);
    ctx.fill();
    ctx.restore();
  } else if (mouth === 'flat') {
    ink(ctx, [
      [mx - 8, my],
      [mx + 8, my + 1],
    ], r, { w: 3, jit: 0.3 });
  } else if (mouth === 'sad') {
    ink(ctx, arcPts(mx, my + 6, 9, 6, Math.PI * 1.2, Math.PI * 1.8, 8), r, { w: 3, jit: 0.3 });
  } else if (mouth === 'chew') {
    const k = Math.sin(t * 22) * 0.5 + 0.5;
    ctx.save();
    ctx.fillStyle = '#5a2a2a';
    ctx.beginPath();
    ctx.ellipse(mx, my, 8, 2 + k * 5, 0, 0, TAU);
    ctx.fill();
    ctx.restore();
  }
}

function walkPose(phase, amt = 1) {
  const s = Math.sin(phase * TAU);
  const c = Math.cos(phase * TAU);
  return {
    legL: [0.42 * s * amt, Math.max(0, -c) * 0.55 * amt],
    legR: [-0.42 * s * amt, Math.max(0, c) * 0.55 * amt],
    armL: [0.12 - 0.42 * s * amt, 0.25],
    armR: [0.12 + 0.42 * s * amt, 0.25],
    bob: -Math.abs(c) * 7 * amt,
  };
}

function blinkAt(t, seed = 0) {
  const period = 3.1 + (seed % 7) * 0.23;
  const ph = (t + seed * 0.37) % period;
  return ph < 0.12;
}
