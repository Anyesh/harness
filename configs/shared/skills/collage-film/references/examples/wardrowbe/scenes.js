'use strict';

const END_T = wd('end', 'wardrobe');
const HOST_T = wd('self', 'host');
const DURATION = Math.round(END_T + 7.3);
const POSTER_T = 6.8;
const PAPER_TEXTURE = 0.4;
const WIPES = [
  { a: 0, b: 1, t0: 7.55, t1: 7.95, dir: 1, seed: 21 },
  { a: 1, b: 2, t0: 12.5, t1: 12.9, dir: -1, seed: 22 },
  { a: 2, b: 3, t0: 18.45, t1: 18.85, dir: 1, seed: 23 },
  { a: 3, b: 4, t0: 24.0, t1: 24.4, dir: -1, seed: 24 },
  { a: 4, b: 5, t0: 28.2, t1: 28.6, dir: 1, seed: 25 },
  { a: 5, b: 6, t0: 33.25, t1: 33.65, dir: -1, seed: 26 },
  { a: 6, b: 7, t0: 36.55, t1: 36.95, dir: 1, seed: 27 },
  { a: 7, b: 8, t0: END_T - 0.53, t1: END_T - 0.13, dir: -1, seed: 28 },
];

function GRADE(t) {
  // Clean product look: no vintage warm wash and a light vignette, so brand monochrome and fabric colours stay true.
  return {
    wash: 0,
    vignette: 0.35,
    cool: 0.32 * prog(t, 20.6, 21.0) * (1 - prog(t, 24.0, 24.4)),
    warm: 0.7 * prog(t, HOST_T - 0.6, HOST_T) * (1 - prog(t, END_T - 0.53, END_T - 0.13)),
  };
}

const KIND = ['tee', 'pants', 'shirt', 'skirt', 'tee', 'sock', 'shirt', 'pants', 'tee', 'skirt', 'sock', 'shirt', 'tee', 'pants', 'sock', 'tee', 'skirt', 'shirt'];
// Per-kind scale so a sock and a coat read at similar visual weight inside the same card or pile.
const FIT = { tee: 1, shirt: 0.95, pants: 0.92, skirt: 1.3, sock: 1.45 };
const JEANS = { color: BRAND.denim, w: 26 };
const DM = '"DM Sans"';

function boilR(key, t) {
  return rng(hash(key, boilIndex(t)));
}

function wob(t, t0, amp = 0.2, freq = 14, decay = 5) {
  if (t < t0) return 0;
  const k = stepped(t) - t0;
  return amp * Math.sin(k * freq) * Math.exp(-k * decay);
}

function overlay(ctx, color, alpha) {
  if (alpha <= 0) return;
  ctx.save();
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.globalAlpha = alpha;
  ctx.fillStyle = color;
  ctx.fillRect(0, 0, W, H);
  ctx.restore();
}

function textAt(ctx, str, x, y, size, color, o = {}) {
  ctx.save();
  ctx.globalAlpha *= o.alpha ?? 1;
  ctx.font = `${o.weight ?? 600} ${size}px ${o.font ?? DM}`;
  ctx.fillStyle = color;
  ctx.textAlign = o.align ?? 'left';
  ctx.fillText(str, x, y);
  ctx.restore();
}

function cuteFace(ctx, x, y, s, mood, t, key) {
  const r = boilR(key, t);
  ctx.save();
  ctx.translate(x, y);
  ctx.scale(s, s);
  if (mood === 'joy') {
    ink(ctx, arcPts(-22, 6, 9, 8, Math.PI + 0.2, TAU - 0.2, 8), r, { w: 4.2 });
    ink(ctx, arcPts(22, 6, 9, 8, Math.PI + 0.2, TAU - 0.2, 8), r, { w: 4.2 });
  } else {
    inkDot(ctx, -22, 0, 5.5, r);
    inkDot(ctx, 22, 0, 5.5, r);
  }
  if (mood === 'sad') ink(ctx, arcPts(0, 30, 12, 8, Math.PI + 0.35, TAU - 0.35, 8), r, { w: 3.8 });
  else ink(ctx, arcPts(0, 12, 13, 10, 0.3, Math.PI - 0.3, 8), r, { w: 3.8 });
  blush(ctx, -38, 16, 9, r);
  blush(ctx, 38, 16, 9, r);
  ctx.restore();
}

function outfitCard(ctx, card, items, caption, x, y, t, o = {}) {
  const s = o.scale ?? 1;
  ctx.save();
  ctx.translate(x, y);
  ctx.rotate(o.rot ?? 0);
  ctx.scale(s, s);
  card.draw(ctx, 0, 0, { lift: o.lift ?? 0 });
  for (const [g, gx, gy, gs] of items) g.draw(ctx, gx, gy, { scale: gs, shadowAlpha: 0.25 });
  handText(ctx, caption, 0, 218, boilR(caption, t), { size: 50, font: FONTS.hand, align: 'center' });
  if (o.after) o.after(ctx);
  ctx.restore();
}

function partialRing(pts, p) {
  const n = Math.max(2, Math.ceil(pts.length * p));
  return pts.slice(0, n);
}

function bedroom() {
  const crisisT = wd('crisis', 'crisis');
  const doorT = wd('nothing', 'closet');
  const nothingT = wd('nothing', 'nothing');
  const wearT = wd('nothing', 'wear');
  const CX = 1320;
  const FY = 900;
  const stuffed = [[A.clothes[2], -120, -520, 0.2], [A.clothes[7], 60, -470, -0.3], [A.clothes[11], 150, -560, 0.5], [A.clothes[13], -60, -360, 0.1], [A.clothes[16], 120, -300, -0.4]];
  const ava = A.clothes.slice(0, 16).map((g, i) => {
    const r = rng(700 + i);
    const t0 = doorT + 0.06 + i * 0.09;
    return { g, t0, t1: t0 + 0.5, from: [CX + rr(r, -160, 160), FY - rr(r, 300, 560)], to: [rr(r, 450, 830), FY - 30 - (i / 15) * 255 + rr(r, -20, 20)], spin: rr(r, -7, 7), rot: rr(r, -0.9, 0.9), s: 0.62 * FIT[KIND[i]] };
  });
  const sock = { t0: nothingT - 0.42, t1: nothingT, from: [CX, FY - 600], to: [655, FY - 1.8 * 262 - 84] };

  sfx(0.45, 'rustle', 0.4, -0.3);
  [3.3, 3.55, 3.8, 4.05, 4.28].forEach((x, i) => sfx(x, 'thump', 0.22 + i * 0.05, 0.4));
  sfx(doorT, 'thump', 0.5, 0.35);
  sfx(doorT + 0.02, 'whoosh', 0.45, 0.2);
  ava.forEach((a, i) => {
    if (i % 3 === 0) sfx(a.t0, 'rustle', 0.45, 0.3);
    if (i % 2 === 0) sfx(a.t1, 'tap', 0.3, -0.3);
  });
  sfx(sock.t1, 'pop', 0.7, -0.3);
  sfx(wearT, 'crayon', 0.9, -0.1);

  scene(0, 7.95, (ctx, t) => {
    const r = boilR('bed', t);
    A.frame.draw(ctx, 300, 330, { rot: -0.04 });
    A.clock.draw(ctx, 170, 560, { rot: 0.05 });
    A.floor.draw(ctx, 960, FY - 10);

    const rattle = t > crisisT && t < doorT ? Math.sin(stepped(t, 24) * 50) : 0;
    const bang = wob(t, doorT, 1, 30, 6);
    ctx.save();
    ctx.translate(CX + rattle * 4, FY);
    ctx.rotate(rattle * 0.012 + bang * 0.01);
    A.cabinet.draw(ctx, 0, 0);
    if (t >= doorT) for (const [g, x, y, rot] of stuffed) g.draw(ctx, x, y, { rot, scale: 0.6 });
    const open = t < doorT ? 0 : ease.outBack(prog(stepped(t, 24), doorT, doorT + 0.16), 2.6);
    const sx = lerp(1, -0.42, open) + bang * 0.08;
    A.doorL.draw(ctx, -262, 0, { sx });
    A.doorR.draw(ctx, 262, 0, { sx: -sx });
    if (t > crisisT + 0.3 && t < doorT) A.clothes[10].draw(ctx, 6, -420, { rot: 1.3 + Math.sin(stepped(t) * 9) * 0.15, scale: 0.42 });
    ctx.restore();

    const stretch = Math.sin(Math.PI * prog(t, 0.3, 1.6));
    const shock = t >= doorT;
    const buried = t >= nothingT;
    const hop = shock && !buried ? -Math.abs(Math.sin((stepped(t) - doorT) * 9)) * 28 : 0;
    const arm = shock && !buried ? [2.4 + wob(t, doorT, 0.3), 0.5] : [lerp(0.18, 2.8, stretch), lerp(0.1, 0.2, stretch)];
    drawPerson(ctx, A.hero, {
      x: 640,
      y: FY + hop,
      scale: 1.8,
      armL: arm,
      armR: arm,
      eyes: t < 1.7 ? 'closed' : shock ? 'wide' : 'dot',
      mouth: t < 1.7 ? (stretch > 0.3 ? 'o' : 'flat') : shock ? (buried ? 'sad' : 'o') : 'flat',
      look: buried ? [0.2, -1] : t > 2.4 ? [1, 0] : [0, 0],
      blink: t > 1.7 && !shock && blinkAt(t, 3),
      head: { rot: t < 1.7 ? -stretch * 0.12 : buried ? wob(t, nothingT, 0.12, 18, 4) : 0 },
    }, t);

    for (const a of ava) {
      if (t < a.t0) continue;
      const f = fly(t, a.t0, a.t1, a.from, a.to, 220, a.spin);
      a.g.draw(ctx, f.x, f.y, { rot: f.rot + a.rot, scale: a.s, lift: f.lift });
    }
    if (t >= sock.t0) {
      const f = fly(t, sock.t0, sock.t1, sock.from, sock.to, 160, 6);
      A.clothes[5].draw(ctx, f.x, f.y, { rot: f.rot + 1.35 + wob(t, sock.t1, 0.25), scale: 0.72, lift: f.lift });
    }
    if (t >= wearT) {
      const L = landing(t, wearT, 0.2, 1.6);
      A.nothing.draw(ctx, 640, 150, { v: boilIndex(t), rot: -0.05, scale: 1.35 * L.s });
      sparkle(ctx, 1110, 90, 26, r, PAL.red);
    }
  }, { cam: [[0, [880, 540, 1.12]], [doorT - 0.1, [920, 530, 1.04]], [doorT + 0.15, [960, 540, 1.0]], [7.95, [800, 520, 1.12]]], table: '#f1eef6' });
}

function brandRows() {
  const meetT = wd('meet', 'meet');
  const brandT = wd('meet', 'wardrobe');
  const rowT = wd('meet', 'row');
  const putsT = wd('rows', 'puts');
  const gridT = wd('rows', 'clothes');
  const headT = putsT - 0.26;
  const wW = A.wordmarkW;
  const wardW = measure('ward', DM, 150, 700);
  const rowW = measure('row', DM, 150, 700);
  const ringPts = ellipsePts(-wW / 2 + 4 + wardW + rowW / 2, -4, rowW / 2 + 28, 100, 56, -0.08);
  const ring = [...ringPts, ...ringPts.slice(0, 6)];
  const cells = [];
  for (let row = 0; row < 3; row++) {
    for (let c = 0; c < 6; c++) {
      const i = row * 6 + c;
      const r = rng(900 + i);
      cells.push({ i, row, c, tc: gridT + row * 0.36 + c * 0.05, x: 960 + (c - 2.5) * 190, y: 375 + row * 195, heap: [960 + rr(r, -520, 520), 985 + rr(r, -30, 40)], hrot: rr(r, -1, 1), rot: rr(r, -0.04, 0.04) });
    }
  }

  sfx(meetT, 'thump', 0.4, 0);
  LOGO_DOTS.forEach((d, k) => sfx(meetT + 0.22 + k * 0.07, 'pop', 0.45, d[0] / 60));
  sfx(brandT, 'slide', 0.7, 0);
  sfx(rowT, 'crayon', 0.9, 0.1);
  sfx(headT, 'whoosh', 0.55, 0);
  sfx(putsT, 'rustle', 0.7, 0);
  for (let row = 0; row < 3; row++) sfx(gridT + row * 0.36 + 0.12, 'pop', 0.55, 0);
  cells.forEach((cl) => sfx(cl.tc, 'tap', 0.22, (cl.c - 2.5) / 3));

  scene(7.95, 12.9, (ctx, t) => {
    const r = boilR('brand', t);
    A.panel.draw(ctx, 960, 540);
    const hp = ease.inOut(prog(stepped(t), headT, headT + 0.4));
    const [tx, ty, ts] = [lerp(960, 780, hp), lerp(330, 175, hp), lerp(1, 0.42, hp)];
    if (t >= meetT - 0.05) {
      const L = landing(t, meetT - 0.05, 0.24, 1.5);
      A.tileBig.draw(ctx, tx, ty, { scale: ts * L.s, lift: L.lift, rot: -0.02 });
      LOGO_DOTS.forEach(([dx, dy], k) => {
        const dt = meetT + 0.22 + k * 0.07;
        if (t < dt) return;
        const D = landing(t, dt, 0.16, 1.8);
        A.dot.draw(ctx, tx + dx * 3 * ts, ty + dy * 3 * ts, { scale: ts * D.s, lift: D.lift * 0.5 });
      });
    }
    if (t >= brandT) {
      const L = landing(t, brandT, 0.22, 1.3);
      const ws = lerp(1, 0.5, hp) * L.s;
      ctx.save();
      ctx.translate(lerp(960, 1060, hp), lerp(640, 185, hp));
      ctx.scale(ws, ws);
      A.wordmark.draw(ctx, 0, 0, { lift: L.lift });
      if (t >= rowT) crayon(ctx, partialRing(ring, ease.out(prog(t, rowT, rowT + 0.4))), r, { w: 11, color: BRAND.rain, passes: 3 });
      ctx.restore();
    }
    const heapY = lerp(320, 0, ease.outBack(prog(stepped(t), putsT - 0.1, putsT + 0.2)));
    for (const cl of cells) {
      if (t >= cl.tc - 0.06) {
        const L = landing(t, cl.tc - 0.06, 0.18, 1.4);
        A.rowCard.draw(ctx, cl.x, cl.y, { scale: 0.7 * L.s, rot: cl.rot, lift: L.lift });
      }
    }
    for (const cl of cells) {
      if (t < putsT - 0.1) break;
      const g = A.clothes[cl.i];
      const fs = FIT[KIND[cl.i]];
      if (t < cl.tc - 0.3) {
        g.draw(ctx, cl.heap[0], cl.heap[1] + heapY, { rot: cl.hrot, scale: 0.5 * fs });
        continue;
      }
      const f = fly(t, cl.tc - 0.3, cl.tc, [cl.heap[0], cl.heap[1] + heapY], [cl.x, cl.y], 140, cl.hrot * 2);
      g.draw(ctx, f.x, f.y, { rot: f.rot + cl.rot, scale: lerp(0.5, 0.42, f.p) * fs, lift: f.lift });
    }
  }, { cam: [[7.55, [960, 540, 1.04]], [12.9, [960, 540, 1.0]]], table: BRAND.table });
}

function snapTags() {
  const snapT = wd('snap', 'snap');
  const swaps = [wd('snap', 'photo'), wd('snap', 'each'), wd('snap', 'piece')];
  const tagsT = wd('tags', 'tags');
  const everyT = wd('tags', 'everything');
  const tagTimes = [everyT, wd('tags', 'colour'), wd('tags', 'pattern'), wd('tags', 'fabric'), wd('tags', 'lot')];
  const texts = ['shirt', 'light blue', 'striped', 'cotton', 'casual'];
  const SX = 700;
  const SY = 560;
  const SS = 1.5;
  const onHanger = [A.stripedShirt, A.clothes[6], A.clothes[11], A.stripedShirt];
  const garmentAt = (t) => onHanger[swaps.filter((x) => t >= x).length];

  sfx(12.62, 'slide', 0.6, 0.6);
  sfx(snapT, 'snip', 0.55, 0.4);
  sfx(snapT + 0.02, 'pop', 0.35, 0.4);
  swaps.forEach((x) => {
    sfx(x, 'snip', 0.35, 0.4);
    sfx(x - 0.05, 'whoosh', 0.3, -0.2);
  });
  sfx(tagsT - 0.3, 'whoosh', 0.6, 0.7);
  tagTimes.forEach((x, i) => {
    sfx(x, 'pop', 0.35, 0.4);
    sfx(x + 0.04, 'tap', 0.25, 0.4);
  });
  sfx(tagTimes[4] + 0.1, 'bell', 0.4, 0.3);

  scene(12.9, 18.85, (ctx, t) => {
    const r = boilR('snap', t);
    const g = garmentAt(t);
    const lastSwap = Math.max(snapT, ...swaps.filter((x) => t >= x));
    const sway = Math.sin(stepped(t) * 2.2) * 0.03 + wob(t, lastSwap, 0.12, 16, 6);
    ink(ctx, [[SX, -40], [SX + 2, SY - 132 * SS - 60]], r, { w: 3, color: '#6b5a48', taper: 0 });
    ctx.save();
    ctx.translate(SX, SY - 132 * SS - 60);
    ctx.rotate(sway);
    A.hanger.draw(ctx, 0, 60 + 4 * SS, { v: boilIndex(t), scale: SS * 1.45 });
    const pop = landing(t, lastSwap, 0.16, 1.15);
    g.draw(ctx, 0, 132 * SS + 60, { scale: SS * (t >= swaps[0] ? pop.s : 1), lift: 0.1 });
    ctx.restore();

    tagTimes.forEach((tt, i) => {
      if (t < tt) return;
      const L = landing(t, tt, 0.2, 1.6);
      const w = measure(texts[i], DM, 46, 600) + 70;
      const tx = 1230 + (i % 2) * 70;
      const ty = 250 + i * 140;
      const rot = -0.06 + wob(t, tt, 0.25, 12, 3);
      const hx = tx + Math.cos(rot) * (-w / 2 + 24) * L.s;
      const hy = ty + Math.sin(rot) * (-w / 2 + 24) * L.s;
      const a = [SX + 70, SY - 130 + i * 42];
      ink(ctx, spline([a, [(a[0] + hx) / 2, Math.max(a[1], hy) + 40], [hx, hy]], false, 8), r, { w: 2.4, color: '#6b5a48', taper: 0 });
      A.tags[i].draw(ctx, tx, ty, { rot, scale: L.s, lift: L.lift });
    });
    if (t >= everyT && t < everyT + 0.9) {
      const k = prog(t, everyT, everyT + 0.9);
      sparkle(ctx, SX - 150, SY - 170, 26 * Math.sin(k * Math.PI), r, PAL.mustard);
      sparkle(ctx, SX + 160, SY + 60, 20 * Math.sin(k * Math.PI), r, PAL.mustard);
    }

    const pIn = ease.outBack(prog(stepped(t), 12.6, 12.95), 1.4);
    const pOut = ease.in(prog(stepped(t), tagsT - 0.3, tagsT));
    if (pOut < 1) {
      const px = lerp(2300, 1340, pIn) + pOut * 1100;
      const py = 580 - pOut * 80;
      ctx.save();
      ctx.translate(px, py);
      ctx.rotate(-0.08 + pOut * 0.4);
      ctx.scale(1.6, 1.6);
      A.phone.draw(ctx, 0, 0, { lift: 0.3 });
      if (t >= snapT) {
        ctx.save();
        tracePath(ctx, roundRectPts(-58, -118, 116, 236, 12, 5));
        ctx.clip();
        ctx.fillStyle = '#e9eef2';
        ctx.fillRect(-60, -120, 120, 240);
        g.draw(ctx, 0, -10, { scale: 0.34, shadow: false });
        ctx.restore();
      }
      inkDot(ctx, 0, 100, 9, r, '#c9c4bb');
      A.hero.hand.draw(ctx, -72, 40, { scale: 1.6 });
      A.hero.hand.draw(ctx, 72, 60, { scale: 1.6 });
      ctx.restore();
      burst(ctx, px, py - 250, prog(t, snapT, snapT + 0.3), r, 10, 50, 120);
    }
    overlay(ctx, '#fffdf5', 0.85 * (1 - ease.out(prog(t, snapT, snapT + 0.3))) * (t >= snapT ? 1 : 0));
    for (const x of swaps) if (t >= x) overlay(ctx, '#fffdf5', 0.4 * (1 - ease.out(prog(t, x, x + 0.18))));
  }, { cam: [[12.5, [1000, 540, 1.22]], [14.5, [1020, 540, 1.26]], [15.0, [990, 530, 1.22]], [18.85, [990, 530, 1.26]]], table: '#f6f4ef' });
}

function weatherOutfit() {
  const morningT = wd('weather', 'morning');
  const checksT = wd('weather', 'checks');
  const rainT = wd('weather', 'weather');
  const sendsT = wd('outfit', 'sends');
  const topT = wd('outfit', 'top');
  const toT = wd('outfit', 'to');
  const toeT = wd('outfit', 'toe');
  const WX = 470;
  const WY = 400;
  const WS = 1.1;
  const HX = 1250;
  const HY = 930;
  const HS = 1.75;
  const NX = 1140;
  const NY = 230;
  const drops = Array.from({ length: 34 }, (_, i) => {
    const r = rng(300 + i);
    return [rr(r, -220, 220), rr(r, 0, 420), rr(r, 0.8, 1.2)];
  });

  sfx(morningT, 'slide', 0.4, -0.5);
  sfx(checksT, 'whoosh', 0.5, -0.5);
  [0, 0.35, 0.7, 1.05, 1.4, 1.75, 2.1].forEach((d) => sfx(rainT + d, 'rustle', 0.28, -0.5));
  sfx(sendsT, 'bell', 0.9, 0.2);
  sfx(sendsT + 0.03, 'slide', 0.5, 0.2);
  for (const x of [topT, toT, toeT]) {
    sfx(x - 0.2, 'whoosh', 0.35, 0.2);
    sfx(x, 'pop', 0.4, 0.2);
  }
  sfx(toeT + 0.3, 'tap', 0.5, 0.2);

  scene(18.85, 24.4, (ctx, t) => {
    const r = boilR('rain', t);
    A.floor.draw(ctx, 960, HY - 10);
    ctx.save();
    ctx.translate(WX, WY);
    ctx.scale(WS, WS);
    ctx.save();
    ctx.beginPath();
    ctx.rect(-230, -190, 460, 380);
    ctx.clip();
    const grey = prog(t, checksT, rainT + 0.2);
    ctx.fillStyle = grey > 0.5 ? '#8d9aa6' : '#9fd0e3';
    ctx.fillRect(-240, -200, 480, 400);
    if (t >= morningT - 0.4) A.sun.draw(ctx, 90, lerp(160, -60, ease.out(prog(stepped(t), morningT - 0.4, morningT + 0.2))), { v: 0 });
    if (t >= checksT) {
      A.cloud.draw(ctx, lerp(-420, 70, ease.outBack(prog(stepped(t), checksT, rainT), 1.3)), -70, { scale: 1.25 });
      A.cloud.draw(ctx, lerp(460, -80, ease.out(prog(stepped(t), checksT + 0.15, rainT + 0.1))), 40, { scale: 0.9, sx: -1 });
    }
    if (t >= rainT) {
      for (const [x, y0, sp] of drops) {
        const y = ((stepped(t) - rainT) * 700 * sp + y0) % 420 - 210;
        A.drop.draw(ctx, x, y, { scale: 0.9, shadow: false });
      }
    }
    ctx.restore();
    A.window.draw(ctx, 0, 0);
    ctx.restore();

    const notif = t >= sendsT ? landing(t, sendsT, 0.24, 1.4) : null;
    const done = t >= toeT + 0.15;
    const hop = done ? -Math.abs(Math.sin((stepped(t) - toeT) * 8)) * 26 * (1 - prog(t, toeT + 0.15, toeT + 1.0)) : 0;
    drawPerson(ctx, A.hero, {
      x: HX,
      y: HY + hop,
      scale: HS,
      body: t >= topT ? A.raincoatTop : undefined,
      pants: t >= toT ? JEANS : undefined,
      shoe: t >= toeT ? A.rigBoot : undefined,
      look: notif ? [0, -1] : [-1, -0.3],
      expr: done ? 'joy' : notif ? 'wow' : 'flat',
      mouth: !notif && t >= rainT ? 'sad' : undefined,
      armR: done ? [2.6, 0.3] : [0.2, 0.1],
      armL: done ? [0.5, 0.3] : [0.2, 0.1],
      blink: !notif && blinkAt(t, 5),
    }, t);

    if (t >= topT - 0.25 && t < topT) {
      const f = fly(t, topT - 0.25, topT, [NX, NY + 120], [HX, HY], 60, 1.2);
      A.raincoatTop.draw(ctx, f.x, f.y, { scale: lerp(0.5, HS, f.p), rot: f.rot, lift: f.lift });
    }
    if (t >= toT - 0.22 && t < toT) {
      const f = fly(t, toT - 0.22, toT, [NX, NY + 120], [HX, HY - 60 * HS], 60, -1);
      A.clothes[1].draw(ctx, f.x, f.y, { scale: lerp(0.25, 0.5, f.p), rot: f.rot, lift: f.lift });
    }
    if (t >= toeT - 0.2 && t < toeT) {
      for (const side of [-1, 1]) {
        const f = fly(t, toeT - 0.2, toeT, [NX + side * 40, NY + 120], [HX + side * 36 * HS, HY - 4], 80, side);
        A.rigBoot.draw(ctx, f.x, f.y, { scale: HS, sx: side, rot: f.rot, lift: f.lift });
      }
    }
    for (const [x, y] of [[topT, HY - 160 * HS], [toT, HY - 60 * HS], [toeT, HY]]) burst(ctx, HX, y, prog(t, x, x + 0.25), r, 8, 70, 130, PAL.mustard);

    if (notif) {
      ctx.save();
      ctx.translate(NX, NY - notif.lift * 40);
      ctx.scale(1.22 * notif.s, 1.22 * notif.s);
      A.notif.draw(ctx, 0, 0, { lift: notif.lift + 0.2 });
      A.notifIcon.draw(ctx, -250, 0, { shadow: false });
      LOGO_DOTS.forEach(([dx, dy]) => A.dot.draw(ctx, -250 + dx * 0.92, dy * 0.92, { scale: 0.3, shadow: false }));
      textAt(ctx, 'wardrowbe', -180, -14, 34, '#2a2a2a', { weight: 700 });
      textAt(ctx, 'now', 300, -14, 24, '#8a857c', { align: 'right' });
      textAt(ctx, 'Rainy day: raincoat, jeans, boots', -180, 34, 27, '#55514b', { weight: 500 });
      ctx.restore();
    }
  }, { cam: [[18.45, [760, 480, 1.1]], [20.2, [820, 500, 1.05]], [21.3, [1000, 520, 1.0]], [22.6, [1000, 545, 1.02]], [24.4, [1020, 550, 1.05]]], table: '#eef2f5' });
}

function wearSkip() {
  const loveT = wd('skip', 'love');
  const wearT = wd('skip', 'wear');
  const notT = wd('skip', 'not');
  const skipT = wd('skip', 'skip');
  const learnsT = wd('skip', 'learns');
  const tasteT = wd('skip', 'taste');
  const HX = 420;
  const HY = 950;
  const HS = 1.8;
  const CX = 1200;
  const CY = 520;
  const outfitA = [[A.blouse, 0, -118, 0.55], [A.clothes[1], 0, 52, 0.42]];
  const outfitB = [[A.clothes[6], 0, -110, 0.52], [A.clothes[9], 0, 60, 0.62], [A.clothes[10], -110, 110, 0.42], [A.clothes[10], 110, 110, 0.42]];
  const intoHero = [wearT + 0.2, wearT + 0.42];

  sfx(loveT - 0.1, 'slide', 0.6, 0.4);
  sfx(wearT, 'thump', 0.45, 0.4);
  sfx(intoHero[0], 'whoosh', 0.5, -0.2);
  sfx(intoHero[1], 'pop', 0.7, -0.4);
  sfx(notT + 0.04, 'slide', 0.6, 0.4);
  sfx(skipT, 'thump', 0.4, 0.4);
  sfx(skipT + 0.14, 'whoosh', 0.5, 0.6);
  sfx(learnsT, 'pop', 0.8, 0.3);
  sfx(learnsT + 0.12, 'crayon', 0.8, 0.3);
  sfx(tasteT, 'bell', 0.35, 0);

  scene(24.4, 28.6, (ctx, t) => {
    const r = boilR('wear', t);
    A.floor.draw(ctx, 960, HY - 10);
    const worn = t >= intoHero[1];
    const meh = t >= notT && t < learnsT;
    drawPerson(ctx, A.hero, {
      x: HX,
      y: HY - (worn && t < intoHero[1] + 0.5 ? Math.abs(Math.sin((stepped(t) - intoHero[1]) * 7)) * 22 : 0),
      scale: HS,
      body: worn ? A.tealTop : undefined,
      pants: worn ? JEANS : undefined,
      look: [1, -0.2],
      expr: t >= learnsT ? 'joy' : meh ? 'flat' : t >= wearT ? 'joy' : 'smile',
      eyes: t >= tasteT ? 'heart' : undefined,
      head: { rot: meh ? Math.sin(stepped(t) * 14) * 0.08 * (1 - prog(t, skipT, skipT + 0.4)) : t >= tasteT ? 0.1 : 0 },
      armR: t >= wearT && t < notT ? [2.5, 0.4] : t >= learnsT ? [2.2, 0.5] : [0.25, 0.1],
      armL: meh ? [0.6, 1.6] : [0.2, 0.1],
      blink: blinkAt(t, 9),
    }, t);

    if (t >= loveT - 0.15 && t < intoHero[1]) {
      let x = CX;
      let y = CY;
      let s = 1.05;
      let rot = 0.03;
      let lift = 0;
      if (t < loveT + 0.1) {
        const f = fly(t, loveT - 0.15, loveT + 0.1, [2300, 600], [CX, CY], 80, 0.5);
        [x, y, rot, lift] = [f.x, f.y, f.rot + 0.03, f.lift];
      } else if (t >= intoHero[0]) {
        const f = fly(t, intoHero[0], intoHero[1], [CX, CY], [HX, HY - 150 * HS], 120, -2);
        [x, y, rot, lift] = [f.x, f.y, f.rot, f.lift];
        s = lerp(1.05, 0.15, f.p);
      }
      outfitCard(ctx, A.cardA, outfitA, 'tuesday', x, y, t, { scale: s, rot, lift, after: (g) => {
        if (t < wearT) return;
        const L = landing(t, wearT, 0.18, 2.2);
        A.check.draw(g, 140, -210, { scale: L.s, lift: L.lift, rot: -0.15 });
      } });
    }
    burst(ctx, HX, HY - 150 * HS, prog(t, intoHero[1], intoHero[1] + 0.25), r, 9, 80, 150, PAL.teal);

    if (t >= notT && t < skipT + 0.5) {
      let x = CX;
      let y = CY;
      let rot = -0.04;
      let lift = 0;
      if (t < notT + 0.24) {
        const f = fly(t, notT, notT + 0.24, [2300, 560], [CX, CY], 80, 0.4);
        [x, y, rot, lift] = [f.x, f.y, f.rot - 0.04, f.lift];
      } else if (t >= skipT + 0.14) {
        const p = ease.in(prog(stepped(t), skipT + 0.14, skipT + 0.44));
        [x, y, rot, lift] = [lerp(CX, 2500, p), lerp(CY, 260, p), -0.04 + p * 1.4, p];
      }
      outfitCard(ctx, A.cardB, outfitB, 'bold choice', x, y, t, { scale: 1.05, rot, lift, after: (g) => {
        if (t < skipT) return;
        const L = landing(t, skipT, 0.16, 2.2);
        A.cross.draw(g, 140, -210, { scale: L.s, lift: L.lift, rot: 0.12 });
      } });
    }

    if (t >= learnsT) {
      const L = landing(t, learnsT, 0.22, 0.2);
      A.heart.draw(ctx, CX, CY - 60 + Math.sin(stepped(t) * 3) * 6, { scale: 4 * L.s, lift: L.lift + 0.2, rot: -0.06 });
      if (t >= learnsT + 0.12) {
        const N = landing(t, learnsT + 0.12, 0.2, 1.5);
        A.noted.draw(ctx, CX + 20, CY + 230, { v: boilIndex(t), rot: -0.06, scale: 1.7 * N.s });
      }
      for (let i = 0; i < 3; i++) {
        const k = prog(t, learnsT + i * 0.2, learnsT + i * 0.2 + 1.1);
        if (k <= 0 || k >= 1) continue;
        A.heart.draw(ctx, HX + 60 + i * 40 + Math.sin(k * 8 + i) * 14, HY - 560 - k * 220, { scale: 0.5 + k * 0.3, alpha: 1 - k * k, shadow: false });
      }
    }
  }, { cam: [[24.0, [900, 540, 1.04]], [28.6, [880, 540, 1.0]]], table: '#f7f3ec' });
}

function washForgot() {
  const hoodieT = wd('wash', 'hoodie');
  const washT = wd('wash', 'wash');
  const digsT = wd('forgot', 'digs');
  const sweaterT = wd('forgot', 'sweater');
  const forgotT = wd('forgot', 'forgot');
  const hadT = wd('forgot', 'had');
  const WX = 600;
  const FY = 940;
  const WS = 1.25;
  const CX = 1530;
  const CS = 0.85;
  const HX = 1180;
  const HS = 1.4;
  const pullT = [sweaterT - 0.1, sweaterT + 0.3];
  const bubbles = Array.from({ length: 12 }, (_, i) => {
    const r = rng(400 + i);
    return [rr(r, -90, 90), rr(r, 0, 1), rr(r, 0.5, 1.1)];
  });
  const puffs = Array.from({ length: 8 }, (_, i) => [(i / 8) * TAU + 0.2, 0.8 + (i % 3) * 0.2]);

  sfx(28.7, 'thump', 0.3, -0.4);
  sfx(hoodieT, 'pop', 0.6, -0.4);
  [0.1, 0.35, 0.6, 0.85].forEach((d) => sfx(hoodieT + d, 'rustle', 0.35, -0.4));
  [0.3, 0.6, 0.9].forEach((d) => sfx(hoodieT + d, 'thump', 0.22, -0.4));
  sfx(washT, 'crayon', 0.8, -0.4);
  sfx(30.62, 'whoosh', 0.5, 0.3);
  sfx(digsT, 'flip', 0.7, 0.5);
  sfx(digsT + 0.2, 'rustle', 0.6, 0.5);
  sfx(pullT[0], 'whoosh', 0.5, 0.3);
  sfx(forgotT, 'pop', 0.45, 0.3);
  sfx(forgotT + 0.02, 'rustle', 0.45, 0.3);
  sfx(hadT, 'bell', 0.4, 0.2);

  scene(28.6, 33.65, (ctx, t) => {
    const r = boilR('wash', t);
    A.floor.draw(ctx, 960, FY - 10);
    A.floor.draw(ctx, 2200, FY - 10);

    const spin = t >= hoodieT;
    const jig = spin ? Math.sin(stepped(t, 24) * 30) : 0;
    ctx.save();
    ctx.translate(WX + jig * 3, FY);
    ctx.rotate(jig * 0.01);
    ctx.scale(WS, WS);
    A.washer.draw(ctx, 0, 0);
    ctx.save();
    ctx.beginPath();
    ctx.arc(0, -210, 110, 0, TAU);
    ctx.clip();
    if (spin) {
      const L = landing(t, hoodieT, 0.2, 1.6);
      A.hoodie.draw(ctx, 0, -190, { scale: 0.48 * L.s, rot: (stepped(t) - hoodieT) * 7, shadow: false, v: boilIndex(t) });
      for (const [bx, ph, sp] of bubbles) {
        const k = ((stepped(t) - hoodieT) * sp + ph) % 1;
        A.bubble.draw(ctx, bx, -100 - k * 220, { scale: 0.7 + k * 0.6, v: boilIndex(t) });
      }
    }
    ctx.fillStyle = 'rgba(255,255,255,0.18)';
    ctx.beginPath();
    ctx.ellipse(-40, -260, 50, 26, -0.6, 0, TAU);
    ctx.fill();
    ctx.restore();
    ink(ctx, ellipsePts(0, -210, 112, 112, 40), r, { w: 4, closed: true, taper: 0, alpha: 0.7 });
    ctx.restore();
    if (t >= washT) {
      const L = landing(t, washT, 0.2, 1.6);
      A.inWash.draw(ctx, WX + 20, FY - 700, { v: boilIndex(t), rot: -0.06 + Math.sin(stepped(t) * 4) * 0.02, scale: 1.5 * L.s });
    }

    const open = ease.outBack(prog(stepped(t), digsT - 0.15, digsT + 0.1), 1.6);
    ctx.save();
    ctx.translate(CX, FY);
    ctx.scale(CS, CS);
    A.cabinet.draw(ctx, 0, 0);
    A.cobweb.draw(ctx, -200, -660, { v: boilIndex(t), scale: 0.9 });
    if (t < pullT[0]) A.sweater.draw(ctx, 0, -360, { scale: 0.85, alpha: 0.75 });
    A.doorL.draw(ctx, -262, 0, { sx: lerp(1, -0.4, open) });
    A.doorR.draw(ctx, 262, 0, { sx: -lerp(1, -0.4, open) });
    ctx.restore();

    const reach = t >= digsT - 0.1 && t < pullT[1];
    const got = t >= pullT[1];
    const dusty = t < forgotT;
    drawPerson(ctx, A.hero, {
      x: HX,
      y: FY,
      scale: HS,
      look: t >= forgotT ? [0, -0.6] : [1, -0.2],
      expr: t >= hadT ? 'joy' : t >= forgotT ? 'wow' : 'smile',
      armR: reach ? [2.0, 0.2] : got ? [2.4, 0.6] : [0.2, 0.1],
      armL: got ? [2.4, 0.6] : [0.2, 0.1],
      blink: blinkAt(t, 13),
    }, t);

    if (t >= pullT[0]) {
      const f = fly(t, pullT[0], pullT[1], [CX, FY - 360 * CS], [HX + 20, FY - 1.4 * 400], 120, 1);
      const sx = f.x + (got ? Math.sin(stepped(t) * 18) * 4 * (1 - prog(t, pullT[1], forgotT)) : 0);
      A.sweater.draw(ctx, sx, f.y, { scale: lerp(0.85 * CS, 0.95, f.p), rot: f.rot + wob(t, forgotT, 0.15), alpha: dusty ? 0.8 : 1 });
      if (dusty) {
        ctx.save();
        ctx.globalAlpha = 0.55;
        A.cobweb.draw(ctx, sx + 70, f.y - 90, { v: boilIndex(t), scale: 0.6 });
        ctx.restore();
        for (let i = 0; i < 14; i++) inkDot(ctx, sx + Math.sin(i * 7.1) * 95, f.y + Math.cos(i * 3.3) * 105, 3, r, '#9a958c');
      }
    }
    if (t >= forgotT) {
      const k = prog(t, forgotT, forgotT + 0.8);
      const cx = HX + 20;
      const cy = FY - 1.4 * 400;
      if (k < 1) {
        for (const [a, sp] of puffs) A.puff.draw(ctx, cx + Math.cos(a) * 240 * ease.out(k) * sp, cy + Math.sin(a) * 200 * ease.out(k) * sp, { scale: 1 + k * 1.4, alpha: 1 - k, rot: a, shadow: false });
      }
      burst(ctx, cx, cy, prog(t, forgotT, forgotT + 0.3), r, 10, 150, 230);
      if (t >= hadT) {
        const s = Math.sin(Math.PI * prog(t, hadT, hadT + 0.9));
        sparkle(ctx, cx - 160, cy - 120, 30 * s, r, PAL.mustard);
        sparkle(ctx, cx + 170, cy + 40, 24 * s, r, PAL.mustard);
      }
    }
  }, { cam: [[28.2, [640, 580, 1.12]], [30.6, [680, 580, 1.1]], [31.05, [1220, 560, 1.08]], [33.65, [1240, 560, 1.12]]], table: '#e9f2f4' });
}

function perfectMatch() {
  const oneT = wd('pair', 'one');
  const findsT = wd('pair', 'finds');
  const matchT = wd('pair', 'match');
  const SY = 610;
  const slot = [1150, 470];
  const tries = A.candidates.map((g, i) => ({ g, t0: findsT - 0.05 + i * 0.22 }));

  sfx(oneT, 'crayon', 0.7, 0);
  sfx(findsT - 0.15, 'slide', 0.5, -0.2);
  tries.forEach((c) => {
    sfx(c.t0, 'pop', 0.4, 0.4);
    sfx(c.t0 + 0.14, 'whoosh', 0.35, 0.5);
  });
  sfx(matchT, 'thump', 0.4, 0.3);
  sfx(matchT + 0.02, 'bell', 0.8, 0);
  A.match.forEach((c, i) => c && sfx(matchT + 0.1 + i * 0.06, 'tap', 0.35, -0.5 + i * 0.2));

  scene(33.65, 36.95, (ctx, t) => {
    const r = boilR('match', t);
    const happy = t >= matchT + 0.1;
    const sx = lerp(960, 800, ease.inOut(prog(stepped(t), findsT - 0.2, findsT + 0.05)));
    const droop = happy ? 0 : Math.sin(stepped(t) * 1.6) * 0.03;
    const sy = SY - (happy ? Math.abs(Math.sin((stepped(t) - matchT) * 6)) * 18 : 0);
    if (happy) {
      const hp = ease.out(prog(stepped(t), matchT + 0.1, matchT + 0.3));
      const a = [sx + 118, sy + 10];
      const b = [slot[0] - 108, slot[1] - 10];
      const m = [lerp(a[0], b[0], 0.5), lerp(Math.max(a[1], b[1]) + 30, (a[1] + b[1]) / 2 + 60, hp)];
      ink(ctx, spline([a, [lerp(a[0], m[0], hp), lerp(a[1], m[1], hp)]], false, 6), r, { w: 6 });
      ink(ctx, spline([b, [lerp(b[0], m[0], hp), lerp(b[1], m[1], hp)]], false, 6), r, { w: 6 });
      if (hp >= 1) inkDot(ctx, m[0], m[1], 12, r, PAL.skin2 ?? PAL.skin);
    }
    A.matchSkirt.draw(ctx, sx, sy, { scale: 1.6, rot: droop + (happy ? -0.06 : 0) });
    cuteFace(ctx, sx, sy + 10, 1.15, happy ? 'joy' : 'sad', t, 'skirt');
    if (!happy && t < findsT) {
      ink(ctx, [[sx + 140, sy - 120], [sx + 150, sy - 100]], r, { w: 4, color: '#6fa8dc' });
      A.drop.draw(ctx, sx - 100, sy - 30 + ((stepped(t) * 60) % 60), { scale: 0.8, shadow: false });
    }
    if (t >= oneT) {
      const ring = ellipsePts(sx, sy, 230, 185, 48, -0.4);
      crayon(ctx, partialRing([...ring, ...ring.slice(0, 5)], ease.out(prog(t, oneT, oneT + 0.35))), r, { w: 9, color: PAL.red, alpha: 1 - prog(t, findsT - 0.3, findsT) });
    }
    for (const c of tries) {
      if (t < c.t0 || t > c.t0 + 0.3) continue;
      const L = landing(t, c.t0, 0.1, 1.5);
      const out = ease.in(prog(stepped(t), c.t0 + 0.14, c.t0 + 0.3));
      c.g.draw(ctx, slot[0] + out * 300, slot[1] - out * 500, { scale: 1.2 * L.s, rot: out * 1.2, lift: L.lift + out });
    }
    if (t >= matchT) {
      const L = landing(t, matchT, 0.22, 1.7);
      const by = slot[1] - (happy ? Math.abs(Math.sin((stepped(t) - matchT) * 6 + 1)) * 18 : 0);
      A.blouse.draw(ctx, slot[0], by, { scale: 1.25 * L.s, lift: L.lift, rot: 0.05 });
      if (happy) cuteFace(ctx, slot[0], by - 38, 1.1, 'joy', t, 'blouse');
      let x = 960 - A.match.reduce((a, c) => a + (c ? c.cw + 8 : 40), 0) / 2;
      A.match.forEach((c, i) => {
        if (!c) {
          x += 40;
          return;
        }
        const ct = matchT + 0.1 + i * 0.06;
        if (t >= ct) {
          const C = landing(t, ct, 0.16, 1.5);
          c.draw(ctx, x + c.cw / 2, 205 + c.dy, { rot: c.tilt, scale: C.s, lift: C.lift });
        }
        x += c.cw + 8;
      });
      for (let i = 0; i < 4; i++) {
        const k = prog(t, matchT + 0.2 + i * 0.18, matchT + 1.3 + i * 0.18);
        if (k <= 0 || k >= 1) continue;
        A.heart.draw(ctx, 990 + Math.sin(k * 7 + i * 2) * 60 + (i - 1.5) * 50, 560 - k * 300, { scale: 0.6 + k * 0.5, alpha: 1 - k * k, shadow: false });
      }
    }
  }, { cam: [[33.25, [975, 480, 1.3]], [36.95, [975, 470, 1.38]]], table: '#fbeeee' });
}

function drawLaptop(ctx, x, y, s, t) {
  ctx.save();
  ctx.translate(x, y);
  ctx.scale(s, s);
  ctx.fillStyle = '#2a2a2a';
  tracePath(ctx, roundRectPts(-80, -110, 160, 104, 10, 4));
  ctx.fill();
  ctx.fillStyle = '#f5f2ec';
  ctx.fillRect(-70, -100, 140, 84);
  ctx.fillStyle = '#4a4a4a';
  tracePath(ctx, [[-96, -6], [96, -6], [108, 10], [-108, 10]]);
  ctx.fill();
  A.miniTile.draw(ctx, 0, -58, { scale: 0.62, shadow: false });
  ctx.restore();
}

function household() {
  const householdT = wd('home', 'household');
  const homeEnd = VO.home.e;
  const cloudT = wd('cloud', 'cloud');
  const webT = wd('cloud', 'web');
  const phoneT = wd('cloud', 'iphone');
  const hostT = wd('self', 'host');
  const yourselfT = wd('self', 'yourself');
  const openT = wd('self', 'open');
  const shutT = yourselfT + 0.7;
  const FY = 930;
  const HX = 3000;
  const HS = 1.3;
  const CX = 2140;
  const CY = 470;
  const fam = [
    { P: A.hero, x: 250, stars: 5, pose: { body: A.tealTop, pants: JEANS } },
    { P: A.friend, x: 560, stars: 4, pose: {} },
    { P: A.kid, x: 870, stars: 5, pose: {} },
  ];
  const ducks = [0, 3, 5, 8, 14].map((k, i) => ({ g: A.clothes[k], k: KIND[k], t0: hostT + i * 0.1 }));
  const floaters = [6, 11, 17].map((k, i) => ({ g: A.clothes[k], k: KIND[k], t0: cloudT + 0.1 + i * 0.15, from: [1950 + i * 180, FY - 40] }));
  const doorX = HX + 70 * HS;
  const goal = HX + 135 * HS;
  const banner = makeLabel('open source', { font: DM, size: 64, color: '#fbf8f0', padX: 70 });

  fam.forEach((f, i) => {
    sfx(householdT - 0.1 + i * 0.15, 'slide', 0.4, -0.6 + i * 0.2);
    for (let k = 0; k < f.stars; k++) sfx(householdT + i * 0.18 + k * 0.07, 'pop', 0.28, -0.6 + i * 0.2);
  });
  sfx(householdT + 0.55, 'laugh', 0.9, -0.3);
  sfx(homeEnd, 'whoosh', 0.6, 0.4);
  sfx(cloudT, 'pop', 0.4, -0.3);
  floaters.forEach((f) => sfx(f.t0, 'rustle', 0.3, -0.3));
  sfx(webT, 'pop', 0.4, -0.4);
  sfx(phoneT, 'pop', 0.4, -0.2);
  sfx(hostT, 'tap', 0.5, 0.4);
  ducks.forEach((d) => sfx(d.t0 + 0.2, 'tap', 0.3, 0.4));
  sfx(shutT, 'thump', 0.5, 0.4);
  sfx(openT, 'tape', 0.6, 0);
  sfx(openT + 0.05, 'pop', 0.35, 0);
  sfx(openT + 0.5, 'bell', 0.4, 0);

  scene(36.95, END_T - 0.13, (ctx, t) => {
    const r = boilR('home', t);
    A.floor.draw(ctx, 960, FY - 10);
    A.floor.draw(ctx, 3400, FY - 10);
    outfitCard(ctx, A.cardA, [[A.blouse, 0, -118, 0.55], [A.clothes[1], 0, 52, 0.42]], 'friday', 1250, 500, t, { scale: 1.05, rot: 0.04 });
    fam.forEach((f, i) => {
      const up = t >= householdT - 0.1 + i * 0.15;
      const kidHop = f.P === A.kid && t > householdT + 0.4 ? Math.abs(Math.sin(stepped(t) * 7)) * 20 : 0;
      const out = drawPerson(ctx, f.P, {
        x: f.x,
        y: FY - kidHop,
        scale: 1.5,
        look: [1, -0.3],
        expr: up ? 'joy' : 'smile',
        armR: up ? [2.9, 0.1] : [0.2, 0.1],
        blink: blinkAt(t, i * 4 + 1),
        ...f.pose,
      }, t);
      if (!up) return;
      const L = landing(t, householdT - 0.1 + i * 0.15, 0.18, 1.4);
      ctx.save();
      ctx.translate(out.handR[0], out.handR[1] - 56);
      ctx.rotate(-0.05 + i * 0.05);
      ctx.scale(0.88 * L.s, 0.88 * L.s);
      A.ratingCard.draw(ctx, 0, 0, { lift: L.lift });
      for (let k = 0; k < 5; k++) {
        const st = householdT + i * 0.18 + k * 0.07;
        const on = k < f.stars && t >= st;
        const S = on ? landing(t, st, 0.14, 1.8) : { s: 1 };
        (on ? A.star : A.starOff).draw(ctx, -88 + k * 44, 0, { scale: 0.5 * S.s, shadowAlpha: 0.2 });
      }
      ctx.restore();
    });

    if (t >= homeEnd - 0.2) {
      const bob = Math.sin(stepped(t) * 1.8) * 8;
      const pulse = 1 + wob(t, cloudT, 0.12, 16, 5);
      A.skyCloud.draw(ctx, CX, CY + bob, { scale: 3.4 * pulse, lift: 0.6, v: boilIndex(t) });
      sparkle(ctx, CX + 330, CY - 170, 28 * Math.sin(Math.PI * prog(t, cloudT, cloudT + 0.8)), r, PAL.mustard);
      if (t >= webT) {
        const W2 = landing(t, webT, 0.18, 1.6);
        drawLaptop(ctx, CX - 150, CY - 10 + bob, 1.35 * W2.s, t);
      }
      if (t >= phoneT) {
        const P2 = landing(t, phoneT, 0.18, 1.6);
        ctx.save();
        ctx.translate(CX + 200, CY - 60 + bob);
        ctx.rotate(0.08);
        ctx.scale(0.85 * P2.s, 0.85 * P2.s);
        A.phone.draw(ctx, 0, 0, { lift: P2.lift });
        A.miniTile.draw(ctx, 0, -10, { scale: 0.9, shadow: false });
        ctx.restore();
      }
    }
    for (const f of floaters) {
      if (t < f.t0) continue;
      const p = prog(stepped(t), f.t0, f.t0 + 0.8);
      if (p >= 1) continue;
      const fl = fly(t, f.t0, f.t0 + 0.8, f.from, [CX + (f.from[0] - 2130) * 0.3, CY + 40], 60, 1.5);
      f.g.draw(ctx, fl.x, fl.y, { scale: 0.34 * FIT[f.k] * (1 - p * 0.5), rot: fl.rot, alpha: 1 - ease.in(p), lift: 0.5 });
    }

    ctx.save();
    ctx.translate(HX, FY);
    ctx.scale(HS, HS);
    A.house.draw(ctx, 0, 0);
    if (t >= hostT) {
      const L = landing(t, hostT, 0.2, 1.5);
      ctx.save();
      ctx.translate(-110, -150);
      ctx.scale(L.s, L.s);
      drawLaptop(ctx, -32, -12, 0.42, t);
      A.cabinet.draw(ctx, 55, 48, { scale: 0.16 });
      ctx.restore();
    }
    ctx.restore();
    for (const d of ducks) {
      if (t < d.t0) continue;
      const p = prog(stepped(t), d.t0, d.t0 + 0.55);
      if (p >= 1) continue;
      const x = lerp(HX - 720, goal, p);
      const y = FY - 40 - Math.abs(Math.sin(p * Math.PI * 3)) * 50;
      d.g.draw(ctx, x, y, { scale: 0.38 * FIT[d.k], rot: Math.sin(p * 20) * 0.2 });
    }
    const close = ease.outBack(prog(stepped(t), shutT - 0.3, shutT), 2.2);
    A.houseDoor.draw(ctx, doorX, FY + 10 * HS, { scale: HS, sx: HS * lerp(-0.25, 1, close) });
    burst(ctx, doorX + 70, FY - 110, prog(t, shutT, shutT + 0.25), r, 8, 120, 180);
    if (t >= shutT + 0.1) {
      for (let i = 0; i < 4; i++) {
        const k = prog(t, shutT + 0.1 + i * 0.3, shutT + 1.4 + i * 0.3);
        if (k <= 0 || k >= 1) continue;
        A.heart.draw(ctx, HX + 189 * HS + Math.sin(k * 6 + i) * 30, FY - 580 * HS - k * 260, { scale: 0.5 + k * 0.6, alpha: 1 - k * k, shadow: false });
      }
    }
    if (t >= openT) {
      const L = landing(t, openT, 0.2, 1.7);
      const bx = 2250;
      const by = 800;
      banner.draw(ctx, bx, by, { scale: 1.1 * L.s, lift: L.lift, rot: -0.04 });
      A.tapes[0].draw(ctx, bx - 220, by - 34, { rot: -0.6, alpha: L.s > 1.05 ? 0 : 1 });
      A.tapes[1].draw(ctx, bx + 220, by - 40, { rot: 0.5, alpha: L.s > 1.05 ? 0 : 1 });
      const sp = Math.sin(Math.PI * prog(t, openT + 0.1, openT + 1.0));
      sparkle(ctx, bx - 260, by - 90, 26 * sp, r, PAL.mustard);
      sparkle(ctx, bx + 270, by + 60, 22 * sp, r, PAL.mustard);
    }
  }, { cam: [[36.55, [790, 560, 1.18]], [homeEnd - 0.1, [820, 560, 1.2]], [cloudT - 0.15, [2580, 560, 1.0]], [openT, [2600, 560, 1.03]], [END_T - 0.13, [2600, 560, 1.06]]], table: '#f7f1e6' });
}

function endCard() {
  const endT = wd('end', 'wardrobe');
  const lines = [wd('end', 'snap'), wd('end', 'organize'), wd('end', 'wear')];
  const urlT = lines[2] + 0.7;

  sfx(endT, 'thump', 0.45, 0);
  LOGO_DOTS.forEach((d, k) => sfx(endT + 0.14 + k * 0.07, 'pop', 0.5, d[0] / 60));
  sfx(endT + 0.3, 'slide', 0.6, 0);
  lines.forEach((x, i) => sfx(x, 'tap', 0.8, -0.4 + i * 0.4));
  sfx(urlT, 'flip', 0.4, 0);

  scene(END_T - 0.13, DURATION, (ctx, t) => {
    A.panel.draw(ctx, 960, 540);
    if (t >= endT - 0.06) {
      const L = landing(t, endT - 0.06, 0.24, 1.6);
      A.tileBig.draw(ctx, 960, 320, { scale: 0.92 * L.s, lift: L.lift, rot: -0.02 });
      LOGO_DOTS.forEach(([dx, dy], k) => {
        const dt = endT + 0.14 + k * 0.07;
        if (t < dt) return;
        const D = landing(t, dt, 0.16, 1.8);
        A.dot.draw(ctx, 960 + dx * 2.76, 320 + dy * 2.76, { scale: 0.92 * D.s, lift: D.lift * 0.5 });
      });
    }
    if (t >= endT + 0.3) {
      const L = landing(t, endT + 0.3, 0.2, 1.3);
      A.wordmark.draw(ctx, 960, 585, { scale: 0.86 * L.s, lift: L.lift });
    }
    lines.forEach((x, i) => {
      if (t < x) return;
      const L = landing(t, x, 0.18, 1.6);
      A.tagline[i].draw(ctx, 960 + (i - 1) * 380, 745, { scale: L.s, lift: L.lift, rot: [-0.05, 0.02, 0.05][i] });
    });
    const ua = ease.out(prog(t, urlT, urlT + 0.6));
    if (ua > 0) textAt(ctx, 'github.com/Anyesh/wardrowbe  ·  app.wardrowbe.com', 960, 890, 38, '#cfc8bb', { align: 'center', weight: 500, alpha: ua });
  }, { cam: [[END_T - 0.53, [960, 540, 1.03]], [DURATION, [960, 540, 1.0]]], table: BRAND.table });
}

function buildScenes() {
  buildStage();
  bedroom();
  brandRows();
  snapTags();
  weatherOutfit();
  wearSkip();
  washForgot();
  perfectMatch();
  household();
  endCard();
}
