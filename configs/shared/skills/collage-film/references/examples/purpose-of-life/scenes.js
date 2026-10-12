'use strict';

const DURATION = 57;
const SFX_CUES = [];
const S = {};

function wd(id, k, nth = 0) {
  const words = VO[id].words.filter((w) => /[a-z]/i.test(w[0]));
  if (typeof k === 'number') return words[k][1];
  const hits = words.filter((w) => w[0].toLowerCase() === k);
  if (!hits.length) throw new Error(`word ${k} not in ${id}`);
  return hits[nth][1];
}

function sfx(t, name, gain = 1, pan = 0) {
  SFX_CUES.push({ t: Math.round(t * 1000) / 1000, name, gain, pan });
}

function kf(t, keys, fn = ease.inOut) {
  if (t <= keys[0][0]) return keys[0][1];
  for (let i = 0; i < keys.length - 1; i++) {
    const [t0, v0, e] = keys[i];
    const [t1, v1] = keys[i + 1];
    if (t <= t1) {
      const p = (e || fn)(prog(t, t0, t1));
      if (Array.isArray(v0)) return v0.map((x, j) => lerp(x, v1[j], p));
      return lerp(v0, v1, p);
    }
  }
  return keys[keys.length - 1][1];
}

function setCam(ctx, cx, cy, z, rot = 0) {
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.translate(W / 2, H / 2);
  ctx.rotate(rot);
  ctx.scale(z, z);
  ctx.translate(-cx, -cy);
}

// Built from tileable patterns anchored in world space so that camera moves never reveal a seam.
function paperBG(ctx, color, view) {
  const { x, y, w, h } = view;
  ctx.save();
  ctx.fillStyle = color;
  ctx.fillRect(x, y, w, h);
  for (const [tex, scale, mode, alpha, ox] of [
    [TEX.mottle, 3.2, 'soft-light', 0.38, 0],
    [TEX.mottle, 1.1, 'multiply', 0.1, 170],
    [TEX.grain, 1.4, 'multiply', 0.9, 0],
    [TEX.fibers, 1, 'source-over', 1, 0],
  ]) {
    const pat = ctx.createPattern(tex, 'repeat');
    pat.setTransform(new DOMMatrix().translate(ox, ox * 0.6).scale(scale));
    ctx.globalCompositeOperation = mode;
    ctx.globalAlpha = alpha;
    ctx.fillStyle = pat;
    ctx.fillRect(x, y, w, h);
  }
  ctx.restore();
}

function viewRect(cx, cy, z) {
  const w = W / z + 80;
  const h = H / z + 80;
  return { x: cx - w / 2, y: cy - h / 2, w, h };
}

function buildFiberTile() {
  const S2 = 1024;
  const c = canvas(S2, S2);
  const g = c.getContext('2d');
  const r = rng(808);
  g.lineCap = 'round';
  for (let i = 0; i < 520; i++) {
    const x = r() * S2;
    const y = r() * S2;
    const a = r() * TAU;
    const l = 6 + r() * 30;
    const light = r() < 0.5;
    g.strokeStyle = light ? `rgba(255,252,240,${0.06 + r() * 0.14})` : `rgba(60,40,20,${0.03 + r() * 0.07})`;
    g.lineWidth = 0.5 + r() * 0.9;
    for (const dx of [-S2, 0, S2]) for (const dy of [-S2, 0, S2]) {
      g.beginPath();
      g.moveTo(x + dx, y + dy);
      g.quadraticCurveTo(x + dx + Math.cos(a + 0.8) * l * 0.5, y + dy + Math.sin(a + 0.8) * l * 0.5, x + dx + Math.cos(a) * l, y + dy + Math.sin(a) * l);
      g.stroke();
    }
  }
  for (let i = 0; i < 160; i++) {
    g.fillStyle = `rgba(50,35,20,${0.08 + r() * 0.25})`;
    g.beginPath();
    g.arc(r() * S2, r() * S2, 0.4 + r() * 1.2, 0, TAU);
    g.fill();
  }
  TEX.fibers = c;
}

function landing(t, t0, d = 0.22, from = 1.25) {
  const p = prog(stepped(t), t0, t0 + d);
  return { on: t >= t0, p, s: lerp(from, 1, ease.outBack(p, 2.2)), lift: 1 - ease.out(p) };
}

function fly(t, t0, t1, from, to, arc = 200, spin = 0) {
  const p = ease.inOutSine(prog(stepped(t), t0, t1));
  const x = lerp(from[0], to[0], p);
  const y = lerp(from[1], to[1], p) - Math.sin(p * Math.PI) * arc;
  return { x, y, p, rot: spin * (1 - p), lift: Math.sin(p * Math.PI) * 0.9 + (1 - p) * 0.2 };
}

function idleBob(t, seed = 0) {
  return Math.sin(stepped(t) * 2.4 + seed) * 2.5;
}

function sparkle(ctx, x, y, s, r, color = INK) {
  ink(ctx, [
    [x, y - s],
    [x, y + s],
  ], r, { w: s * 0.22, color, jit: 0.4 });
  ink(ctx, [
    [x - s, y],
    [x + s, y],
  ], r, { w: s * 0.22, color, jit: 0.4 });
}

function burst(ctx, x, y, p, r, n = 8, r0 = 40, r1 = 90, color = INK) {
  if (p <= 0 || p >= 1) return;
  const a = lerp(r0, r1, ease.out(p));
  const b = lerp(r0, r1, ease.out(clamp(p * 1.6)));
  for (let i = 0; i < n; i++) {
    const ang = (i / n) * TAU + 0.3;
    const c = Math.cos(ang);
    const s = Math.sin(ang);
    ink(ctx, [
      [x + c * a, y + s * a],
      [x + c * b * 1.25, y + s * b * 1.25],
    ], r, { w: 4.5, color, jit: 0.5 });
  }
}

function drawScissors(ctx, x, y, rot, scale, open, o = {}) {
  ctx.save();
  ctx.translate(x, y);
  ctx.rotate(rot);
  ctx.scale(scale, scale);
  for (const [i, side] of [
    [0, -1],
    [1, 1],
  ]) {
    ctx.save();
    ctx.rotate((side * open) / 2);
    A.scissorLoop[i].draw(ctx, 0, 0, { lift: o.lift ?? 0, shadowAlpha: 0.35 });
    A.scissorBlade[i].draw(ctx, 0, 0, { lift: o.lift ?? 0, shadowAlpha: 0.35, v: o.v ?? 0 });
    ctx.restore();
  }
  ctx.fillStyle = '#4a4248';
  ctx.beginPath();
  ctx.arc(0, 0, 7, 0, TAU);
  ctx.fill();
  ctx.fillStyle = 'rgba(255,255,255,0.7)';
  ctx.beginPath();
  ctx.arc(-2, -2, 2.2, 0, TAU);
  ctx.fill();
  ctx.restore();
}

function snipOpen(t, times, base = 0.42) {
  let o = base;
  for (const s of times) {
    const d = stepped(t) - s;
    if (d >= -0.12 && d < 0) o = lerp(base, 0.75, prog(d, -0.12, -0.04));
    if (d >= 0 && d < 0.1) o = lerp(0.04, base, prog(d, 0.02, 0.1));
  }
  return o;
}

function pip(ctx, pose, t) {
  return drawPerson(ctx, A.pip, pose, t);
}

const HATS = {
  laurel: (ctx) => A.laurel.draw(ctx, 0, -6, { scale: 1.05 }),
  beret: (ctx) => {
    A.feather.draw(ctx, 46, -64, { rot: 0.5, scale: 0.75 });
    A.beret.draw(ctx, 0, 6, { rot: -0.08 });
  },
  topHat: (ctx) => A.topHat.draw(ctx, 0, -26, { rot: 0.06, scale: 0.92 }),
  helmet: (ctx, t) => {
    A.helmetRing.draw(ctx, 0, 2, {});
    A.helmet.draw(ctx, 0, 0, { v: boilIndex(t), shadow: false });
  },
  beanie: (ctx) => {
    A.beanie.draw(ctx, 0, -4, { rot: -0.05 });
    A.pompom.draw(ctx, -6, -110, {});
  },
};

const SCENES = [];

function scene(t0, t1, draw) {
  const s = { t0, t1, draw };
  SCENES.push(s);
  return s;
}

function buildTitleScene() {
  const rowsWords = [
    [
      ['WHAT', wd('q', 'what')],
      ['IS', wd('q', 'is')],
      ['THE', wd('q', 'the')],
    ],
    [['PURPOSE', wd('q', 'purpose')]],
    [
      ['OF', wd('q', 'of')],
      ['LIFE', wd('q', 'life')],
    ],
  ];
  const chips = [];
  A.titleRows.forEach((row, k) => {
    const gap = 6;
    const space = row.size * 0.36;
    let total = 0;
    row.chips.forEach((c) => (total += c ? c.cw + gap : space));
    let x = 880 - total / 2;
    let letter = 0;
    let wordIdx = 0;
    row.chips.forEach((c) => {
      if (!c) {
        x += space;
        wordIdx++;
        letter = 0;
        return;
      }
      const [word, tw] = rowsWords[k][wordIdx];
      const tt = tw - 0.05 + letter * Math.min(0.055, 0.32 / word.length);
      chips.push({ c, x: x + c.cw / 2, y: row.y + c.dy, rot: c.tilt, t: tt });
      x += c.cw + gap;
      letter++;
    });
  });
  chips.forEach((ch, i) => sfx(ch.t, 'tap', 0.22 + (i % 3) * 0.06, (ch.x - 960) / 1400));
  const qT = VO.q.e - 0.05;
  sfx(qT + 0.18, 'thump', 0.7, 0.5);
  sfx(0.25, 'slide', 0.35, 0);

  const hatT = [wd('long', 'people') + 0.02, wd('long', 'asking') + 0.1, wd('long', 'very', 0) - 0.05, wd('long', 'very', 1) - 0.02, wd('long', 'long') + 0.1];
  const hats = ['laurel', 'beret', 'topHat', 'helmet', 'beanie'];
  hatT.forEach((tt) => {
    sfx(tt, 'pop', 0.45, 0);
    sfx(tt + 0.04, 'tap', 0.3, 0.2);
  });
  S.title = { chips, qT, hatT, hats };

  scene(0, 7.9, (ctx, t) => {
    const z = 1 + 0.035 * ease.inOutSine(prog(t, 0, 7.9));
    setCam(ctx, 960, 560, z);
    paperBG(ctx, PAL.paper, viewRect(960, 560, z));
    const st = stepped(t);
    for (const ch of chips) {
      if (t < ch.t) continue;
      const L = landing(t, ch.t, 0.17, 1.35);
      ch.c.draw(ctx, ch.x, ch.y, { rot: ch.rot + (1 - L.p) * 0.12, scale: L.s, lift: L.lift });
    }
    if (t >= qT) {
      const p = prog(st, qT, qT + 0.2);
      const y = lerp(-380, 330, ease.in(p));
      const sq = st > qT + 0.2 && st < qT + 0.36 ? 0.88 : 1;
      A.bigQ.draw(ctx, 1555, y, { rot: 0.14 + Math.sin(st * 1.7) * 0.015, sy: sq, sx: 2 - sq, lift: 1 - p * 0.9 });
      if (p >= 1) burst(ctx, 1555, 560, prog(t, qT + 0.2, qT + 0.5), rng(hash('qb', boilIndex(t))), 9, 150, 220);
    }

    const hi = hatT.findIndex((h, i) => t >= h && (i === hatT.length - 1 || t < hatT[i + 1]));
    const enter = ease.outBack(prog(st, 0.25, 0.7));
    const pose = { x: 960, y: lerp(1560, 1065, enter), scale: 1.32, look: [0, -1], expr: 'smile', blink: blinkAt(t, 3) };
    if (t > 1.0 && t < qT + 0.2) pose.look = [-0.4 + 0.8 * prog(t, 1.4, 3.2), -1];
    if (t >= qT + 0.2) {
      pose.look = [1, -0.9];
      pose.expr = 'wow';
      pose.eyes = 'wide';
      pose.brows = [6, 8];
    }
    if (t >= qT + 0.55 && t < hatT[0]) {
      pose.armR = [2.75 + Math.sin(st * 30) * 0.12, 1.75];
      pose.expr = 'flat';
      pose.eyes = 'dot';
      pose.look = [0.7, -0.6];
      pose.head = { rot: 0.12 };
      pose.brows = [2, 7];
    }
    if (hi >= 0) {
      const h = hats[hi];
      const pop = landing(t, hatT[hi], 0.17, 1.5);
      pose.hat = (c, tt) => {
        c.save();
        c.scale(pop.s, pop.s);
        HATS[h](c, tt);
        c.restore();
      };
      Object.assign(pose, [
        { armR: [0.15, -2.72], look: [0.6, -1], expr: 'smile', head: { rot: -0.1 }, brows: [2, 5] },
        { armR: [2.95, 0.05], armL: [0.3, 0.2], expr: 'wow', eyes: 'dot', look: [0.3, -1], brows: [6, 6] },
        { armL: [0.06, 0], armR: [0.06, 0], expr: 'flat', look: [0, 0], brows: [5, 1], head: { rot: 0.05 } },
        { armL: [1.45, 0.25], armR: [1.45, 0.25], expr: 'joy', rot: 0.08, look: [0, 0] },
        { armL: [0.75, 1.7], armR: [0.75, 1.7], expr: 'smile', look: [0, 0.1], brows: [6, 6], head: { rot: -0.06 } },
      ][hi]);
      if (hi === 3) pose.y = 1030 + Math.sin(st * 3) * 8;
      const yc = A.years[hi];
      const L = landing(t, hatT[hi], 0.17, 1.4);
      yc.draw(ctx, 1300, 850 + (hi % 2) * 14, { rot: [-0.06, 0.05, -0.03, 0.07, -0.05][hi], scale: 1.35 * L.s, lift: L.lift });
      A.tape.draw(ctx, 1300, 805 + (hi % 2) * 14, { rot: 0.1 + hi * 0.05, scale: 0.8 * L.s });
    }
    if (t >= 0.25) pip(ctx, pose, t);
    if (hi >= 0) burst(ctx, 960, 690, prog(t, hatT[hi], hatT[hi] + 0.25), rng(hash('hb', hi, boilIndex(t))), 7, 120, 180);
  });
}

function buildAnswersScene() {
  const t0 = 7.4;
  const panelX = (i) => i * 2050;
  const panelY = [540, 556, 528, 548];
  const panelR = [-0.012, 0.01, -0.008, 0.012];
  const tHappy = wd('happy', 'happy');
  const tGood = wd('good', 'good');
  const tMark = wd('mark', 'mark');
  const tSnack = wd('snacks', 'snacks');
  const camKeys = [
    [t0, [0, 540, 1.0]],
    [9.45, [0, 540, 1.025]],
    [9.8, [2050, 556, 1.0]],
    [11.22, [2050, 556, 1.025]],
    [11.57, [4100, 528, 1.0]],
    [13.2, [4100, 528, 1.025]],
    [13.55, [6150, 548, 1.0]],
    [15.0, [6150, 548, 1.04]],
    [15.55, [3075, 560, 0.232]],
    [16.4, [3075, 560, 0.226]],
  ];
  const sandwich = [
    ['breadBot', 13.95, 300],
    ['lettuce', 14.12, 276],
    ['tomato', 14.27, 258],
    ['cheese', 14.43, 240],
    ['breadTop', tSnack - 0.02, 230],
  ];
  sandwich.forEach(([, tt], i) => sfx(tt + 0.1, i === 4 ? 'thump' : 'tap', i === 4 ? 0.55 : 0.4, 0));
  sfx(tHappy, 'tap', 0.5, -0.4);
  sfx(tGood, 'bell', 0.32, 0);
  sfx(tGood + 0.02, 'tap', 0.4, 0.4);
  sfx(tMark - 0.04, 'thump', 0.75, 0.2);
  sfx(tMark + 0.12, 'tap', 0.4, -0.5);
  sfx(tMark + 0.26, 'crayon', 0.45, 0.2);
  sfx(9.42, 'whoosh', 0.35, 0.3);
  sfx(11.18, 'whoosh', 0.35, 0.3);
  sfx(13.17, 'whoosh', 0.35, 0.3);
  sfx(15.02, 'whoosh', 0.4, 0);
  A.snacks.forEach((c, i) => sfx(tSnack + 0.08 + i * 0.05, 'tap', 0.25, -0.3 + i * 0.1));
  sfx(7.75, 'slide', 0.3, 0.3);
  S.answers = { camKeys };

  scene(t0, 16.4, (ctx, t) => {
    const [cx, cy, z] = kf(t, camKeys);
    setCam(ctx, cx, cy, z);
    paperBG(ctx, PAL.paper, viewRect(cx, cy, z));
    const st = stepped(t);
    const view = viewRect(cx, cy, z);
    for (let i = 0; i < 4; i++) {
      const px = panelX(i);
      if (px + 1100 < view.x || px - 1100 > view.x + view.w) continue;
      ctx.save();
      ctx.translate(px, panelY[i]);
      ctx.rotate(panelR[i]);
      A.panels[i].draw(ctx, 0, 0, { shadowAlpha: 0.5 });
      [answerHappy, answerGood, answerMark, answerSnacks][i](ctx, t, st);
      A.tapes[i].draw(ctx, -930, -520, { rot: -0.7, scale: 1.3 });
      A.tapes[i + 1].draw(ctx, 930, 520, { rot: -0.7, scale: 1.3 });
      ctx.restore();
    }
  });

  function answerHappy(ctx, t, st) {
    A.cloud.draw(ctx, -560 + st * 9, -330, { scale: 1.1 });
    A.cloud.draw(ctx, 600 - st * 6, -400, { scale: 0.7, sx: -1 });
    const rise = ease.outBack(prog(st, 7.7, 8.4), 1.2);
    const sy = lerp(700, -130, rise);
    A.rays.draw(ctx, 380, sy, { rot: st * 0.35, scale: 1.4 });
    A.sun.draw(ctx, 380, sy, { v: boilIndex(t), rot: Math.sin(st * 1.3) * 0.04, scale: 1.35 });
    A.grass.draw(ctx, -520, 520, { sx: 1.3, sy: 1.5 });
    A.grass.draw(ctx, 520, 530, { sx: 1.3, sy: 1.3 });
    const joy = t >= tHappy;
    const hop = joy && st < tHappy + 0.5 ? -Math.abs(Math.sin((st - tHappy) * TAU)) * 40 : 0;
    pip(ctx, {
      x: -330,
      y: 525 + hop,
      scale: 1.6,
      expr: joy ? 'joy' : 'smile',
      look: joy ? [0.3, -0.3] : [1, -0.7],
      armL: joy ? [2.7, 0.2] : [0.2, 0.1],
      armR: joy ? [2.7, 0.2] : [0.2, 0.1],
      bob: idleBob(t),
      blink: blinkAt(t, 1),
    }, t);
    if (t >= tHappy) {
      const L = landing(t, tHappy, 0.2);
      A.lblHappy.draw(ctx, -560, -330, { rot: -0.08, scale: 1.5 * L.s, lift: L.lift, v: boilIndex(t) });
      A.tapes[2].draw(ctx, -560, -405, { rot: 0.05, scale: 1.1 * L.s });
    }
  }

  function answerGood(ctx, t, st) {
    const giving = t >= tGood - 0.6;
    A.grass.draw(ctx, 0, 530, { sx: 2.5, sy: 1.2 });
    A.worm.draw(ctx, 330, 530, { scale: 1.05, rot: Math.sin(st * 3) * 0.06, v: boilIndex(t, 3, 1) });
    const P = pip(ctx, {
      x: -200,
      y: 525,
      scale: 1.6,
      expr: 'smile',
      eyes: t >= tGood ? 'happy' : 'dot',
      look: [1, 0.3],
      armR: giving ? [1.25, -0.05] : [0.3, 0.1],
      armL: [0.2, 0.1],
      bob: idleBob(t, 1),
      head: { rot: 0.08 },
    }, t);
    ink(ctx, [
      [P.handR[0] + 4, P.handR[1]],
      [P.handR[0] + 24, P.handR[1] - 22],
    ], rng(hash('stem', boilIndex(t))), { w: 5, color: PAL.green });
    A.flower.draw(ctx, P.handR[0] + 28, P.handR[1] - 28, { rot: 0.4, scale: 1.9, v: boilIndex(t) });
    const hp = prog(st, tGood - 0.35, tGood + 0.02);
    if (hp > 0) {
      const hy = lerp(-760, P.head[1] - 132, ease.out(hp)) + (hp >= 1 ? Math.sin(st * 3) * 5 : 0);
      A.halo.draw(ctx, P.head[0], hy, { rot: 0.05, lift: 0.6, scale: 1.45 });
      if (hp >= 1) {
        const r = rng(hash('hs', boilIndex(t)));
        const k = prog(t, tGood, tGood + 0.6);
        if (k < 1) for (let i = 0; i < 4; i++) sparkle(ctx, P.head[0] + Math.cos(i * 1.7) * (70 + k * 40), hy + Math.sin(i * 1.7) * 30 - k * 20, 12 * (1 - k * 0.5), r, PAL.mustard);
      }
    }
    for (let i = 0; i < 3; i++) {
      const ht = tGood + 0.15 + i * 0.16;
      if (t < ht) continue;
      const k = prog(st, ht, ht + 1.4);
      A.heart.draw(ctx, 60 + i * 90 + Math.sin(st * 4 + i) * 16, 120 - k * 480, { scale: 1.1 + 0.3 * ease.outBack(prog(st, ht, ht + 0.2)), rot: Math.sin(st * 3 + i) * 0.2, alpha: 1 - prog(k, 0.75, 1), lift: 0.5 });
    }
    if (t >= tGood) {
      const L = landing(t, tGood, 0.2);
      A.lblGood.draw(ctx, 560, -330, { rot: 0.07, scale: 1.5 * L.s, lift: L.lift, v: boilIndex(t) });
      A.tapes[3].draw(ctx, 560, -405, { rot: -0.08, scale: 1.1 * L.s });
    }
  }

  function answerMark(ctx, t, st) {
    if (t >= tMark - 0.04) {
      const L = landing(t, tMark - 0.04, 0.12, 1.6);
      A.handprint.draw(ctx, 300, -100, { rot: 0.12, scale: 1.45 * L.s });
      if (t >= tMark + 0.26) {
        const p = prog(t, tMark + 0.26, tMark + 0.8);
        const s = A.iWasHere;
        ctx.save();
        ctx.beginPath();
        ctx.rect(330 - s.ox * 1.3 - 30, 290, s.w * 1.3 * p + 30, 200);
        ctx.clip();
        s.draw(ctx, 330, 390, { rot: -0.05, scale: 1.3, v: boilIndex(t) });
        ctx.restore();
      }
    }
    const proud = t >= tMark;
    pip(ctx, {
      x: -470,
      y: 525,
      scale: 1.6,
      expr: proud ? 'joy' : 'smile',
      look: [1, -0.4],
      armR: proud ? [2.55, 0.35] : [1.3, 0.5],
      armL: [0.2, 0.1],
      bob: idleBob(t, 2),
      blink: blinkAt(t, 5),
      front: (c, hands) => {
        c.save();
        c.fillStyle = PAL.red;
        c.globalAlpha = 0.9;
        c.beginPath();
        c.arc(hands[1][0], hands[1][1], 11, 0, TAU);
        c.fill();
        c.restore();
      },
    }, t);
    if (t >= tMark + 0.12) {
      const L = landing(t, tMark + 0.12, 0.2);
      A.lblMark.draw(ctx, -600, -360, { rot: -0.05, scale: 1.5 * L.s, lift: L.lift, v: boilIndex(t) });
      A.tapes[4].draw(ctx, -600, -435, { rot: 0.06, scale: 1.1 * L.s });
    }
  }

  function answerSnacks(ctx, t, st) {
    const got = t >= tSnack + 0.1;
    const hop = got && st < tSnack + 0.6 ? -Math.abs(Math.sin((st - tSnack) * TAU * 1.2)) * 30 : 0;
    const wob = got ? Math.sin(st * 5) * 0.03 : 0;
    const P = pip(ctx, {
      x: -60,
      y: 525 + hop,
      scale: 1.6,
      expr: got ? 'joy' : 'smile',
      eyes: got ? 'heart' : 'dot',
      look: got ? [0, -0.2] : [0, -1],
      brows: got ? null : [5, 5],
      armL: [2.5, 0.55],
      armR: [2.5, 0.55],
      head: { rot: wob },
      bob: idleBob(t, 3),
    }, t);
    const baseX = P.head[0];
    const baseY = P.head[1] - 64;
    for (const [k, tt, dy] of sandwich) {
      if (t < tt) continue;
      const p = prog(stepped(t), tt, tt + 0.11);
      const y = lerp(baseY - 900, baseY + (dy - 300) * 1.05, ease.in(p));
      const sq = p >= 1 && stepped(t) < tt + 0.2 ? 0.86 : 1;
      A[k].draw(ctx, baseX + (dy - 300) * wob * 4, y, { scale: 1.05, sy: sq, sx: 2 - sq, lift: (1 - p) * 0.8, rot: wob * 1.5 });
    }
    if (t >= tSnack + 0.08) {
      const cs = A.snacks;
      let x = -590;
      cs.forEach((c, i) => {
        const tt = tSnack + 0.08 + i * 0.05;
        if (t >= tt) {
          const L = landing(t, tt, 0.15, 1.5);
          c.draw(ctx, x + c.cw * 0.65, -400 + c.dy, { rot: c.tilt, scale: 1.3 * L.s, lift: L.lift });
        }
        x += c.cw * 1.3 + 10;
      });
      burst(ctx, baseX, baseY - 100, prog(t, tSnack + 0.1, tSnack + 0.4), rng(hash('sb', boilIndex(t))), 10, 230, 300);
    }
  }
}

function buildLookingScene() {
  const t0 = 15.95;
  const tStars = wd('stars', 'stars');
  const tRocks = wd('rocks', 'rocks');
  const tBooks = wd('books', 'books');
  const tLook = wd('look', 'go');
  const camKeys = [
    [t0, [560, 720, 1.32]],
    [17.45, [1160, 720, 1.32]],
    [17.78, [2400, 520, 1.15], ease.inOut],
    [19.0, [2420, 520, 1.19]],
    [19.3, [4330, 790, 1.45]],
    [20.15, [4330, 790, 1.5]],
    [20.45, [6250, 650, 1.15]],
    [22.8, [6250, 650, 1.2]],
  ];
  sfx(17.45, 'whoosh', 0.45, 0.4);
  sfx(19.0, 'whoosh', 0.45, 0.4);
  sfx(20.15, 'whoosh', 0.45, 0.4);
  sfx(tStars + 0.12, 'whoosh', 0.22, 0.3);
  sfx(tRocks - 0.02, 'thump', 0.4, 0.2);
  sfx(tRocks + 0.25, 'pop', 0.35, 0.1);
  sfx(20.55, 'flip', 0.5, 0.2);
  sfx(20.9, 'flip', 0.45, 0.3);
  sfx(tBooks, 'thump', 0.9, 0);
  sfx(tBooks + 0.2, 'pop', 0.3, 0);
  S.looking = { camKeys };

  scene(t0, 22.95, (ctx, t) => {
    const [cx, cy, z] = kf(t, camKeys);
    setCam(ctx, cx, cy, z);
    paperBG(ctx, PAL.paper, viewRect(cx, cy, z));
    const st = stepped(t);
    const view = viewRect(cx, cy, z);
    for (let i = -1; i < 5; i++) A.groundStrip.draw(ctx, i * 2100 + 300, 1010 + (i % 2) * 10, { rot: (i % 2 ? 1 : -1) * 0.004 });
    const vis = (x0, x1) => x1 > view.x && x0 < view.x + view.w;

    if (vis(-600, 1500)) {
      const px = lerp(330, 1060, prog(t, t0, 17.6));
      const ph = (px - 330) / 260;
      pip(ctx, {
        x: px,
        y: 1000,
        scale: 0.98,
        ...walkPose(stepped(ph * 0.5, 6), 0.9),
        armR: [1.2, -0.25],
        look: [1, 0.5],
        expr: 'smile',
        head: { rot: 0.06 },
        front: (c, hands) => A.magnifier.draw(c, hands[1][0] + 4, hands[1][1] + 6, { rot: 0.9, scale: 0.55, v: boilIndex(t) }),
      }, t);
      if (t >= tLook) {
        const s = prog(t, tLook, tLook + 0.15);
        sparkle(ctx, px + 150, 760, 10 + s * 8, rng(hash('lk', boilIndex(t))));
      }
    }

    if (vis(1150, 3350)) {
      A.nightSheet.draw(ctx, 2250, 470, { rot: 0.006, shadowAlpha: 0.5 });
      A.moon.draw(ctx, 1800, 230, { rot: -0.2 + Math.sin(st) * 0.03, v: boilIndex(t) });
      const starsAt = [
        [1950, 330, 0.6, 0],
        [2150, 170, 0.75, 1],
        [2880, 430, 0.55, 3],
        [3060, 210, 0.75, 1],
        [1700, 540, 0.45, 2],
        [3010, 650, 0.45, 0],
      ];
      starsAt.forEach(([x, y, s, k], i) => {
        const tw = 1 + Math.sin(st * 5 + i * 1.3) * 0.06;
        A.stars[k].draw(ctx, x, y, { scale: s * tw, rot: Math.sin(st + i) * 0.1 });
      });
      const dodge = ease.outBack(prog(st, tStars + 0.18, tStars + 0.4));
      A.stars[2].draw(ctx, lerp(2700, 2870, dodge), lerp(190, 120, dodge), { scale: 0.9, rot: dodge * 0.6, lift: 0.4 + dodge * 0.4 });
      A.ladder.draw(ctx, 2420, 1010, { scale: 0.8, rot: 0.02 });
      const swing = kf(t, [
        [tStars - 0.3, -0.5],
        [tStars + 0.05, -0.75],
        [tStars + 0.3, 0.75, ease.out],
        [tStars + 0.9, 0.5],
      ]);
      const missed = t > tStars + 0.45;
      pip(ctx, {
        x: 2420,
        y: 432,
        scale: 0.95,
        armR: [2.35 + swing * 0.25, 0.1],
        armL: [0.6, -0.9],
        legL: [0.1, 0],
        legR: [0.05, 0],
        look: missed ? [1, -0.5] : [0.8, -1],
        expr: missed ? 'flat' : 'smile',
        brows: missed ? [2, 6] : null,
        front: (c, hands) => A.net.draw(c, hands[1][0], hands[1][1] + 8, { rot: swing, scale: 1.0, v: boilIndex(t) }),
      }, t);
    }

    if (vis(3700, 4900)) {
      A.grass.draw(ctx, 4300, 1012, { sx: 1.6, sy: 1.3 });
      const lift = ease.outBack(prog(st, tRocks - 0.12, tRocks + 0.06), 1.4);
      const wormUp = ease.outBack(prog(st, tRocks + 0.15, tRocks + 0.45));
      if (wormUp > 0) A.worm.draw(ctx, 4420, 1012, { sy: wormUp, rot: Math.sin(st * 9) * 0.18 * wormUp, v: boilIndex(t), shadow: false });
      ctx.save();
      ctx.translate(4590, 1004);
      ctx.rotate(0.5 * lift);
      A.rock.draw(ctx, -168, 0, { v: boilIndex(t), lift: lift * 0.5 });
      ctx.restore();
      pip(ctx, {
        x: 4170,
        y: 1004,
        scale: 0.95,
        armR: [1.55 + lift * 0.6, -0.2 - lift * 0.3],
        armL: [1.2 + lift * 0.5, -0.5],
        legL: [0.25, 0.25],
        legR: [0.2, 0.2],
        look: [1, 0.4],
        expr: wormUp > 0.5 ? 'wow' : 'smile',
        eyes: wormUp > 0.5 ? 'wide' : 'dot',
        brows: wormUp > 0.5 ? [6, 8] : null,
        bob: 6,
      }, t);
    }

    if (vis(5700, 6800)) {
      const shut = t >= tBooks;
      const bx = 6250;
      if (!shut) {
        A.bookCover.draw(ctx, bx, 1000, { shadowAlpha: 0.5 });
        A.pageL.draw(ctx, bx, 990, {});
        A.pageR.draw(ctx, bx, 990, {});
        for (const [a, b] of [
          [20.55, 20.85],
          [20.9, 21.18],
        ]) {
          const p = prog(stepped(t), a, b);
          if (p > 0 && p < 1) A.flipPage.draw(ctx, bx + 6, 990, { sx: Math.cos(p * Math.PI), lift: Math.sin(p * Math.PI) * 0.6 });
        }
      }
      const jump = prog(st, tBooks - 0.25, tBooks - 0.05);
      const px = shut ? bx : lerp(6010, bx, ease.inOut(jump));
      const py = shut ? 1010 : 1004 - Math.sin(jump * Math.PI) * 120;
      const kick = shut ? Math.sin(st * 16) : 0;
      pip(ctx, {
        x: px,
        y: py,
        scale: 0.95,
        armR: shut ? [2.6, 0.3] : [1.95, -0.35],
        armL: [0.3, 0.1],
        legL: shut ? [0.35 + kick * 0.35, 0.3] : [0.05, 0],
        legR: shut ? [0.35 - kick * 0.35, 0.3] : [0.05, 0],
        look: [1, -0.6],
        expr: jump > 0 ? 'joy' : 'smile',
        front: shut ? null : (c, hands) => A.magnifier.draw(c, hands[1][0] + 6, hands[1][1] + 2, { rot: 0.5, scale: 0.55 }),
      }, t);
      if (shut) {
        const L = landing(t, tBooks, 0.15, 1.12);
        const wob = Math.sin(st * 11) * 0.05 * (1 - prog(t, tBooks + 0.4, tBooks + 1.4));
        A.bookClosed.draw(ctx, bx, 922 + (1 - L.p) * -30, { scale: L.s * 0.95, rot: wob, lift: 0.3, v: boilIndex(t) });
        if (t >= tBooks + 0.18) {
          const L2 = landing(t, tBooks + 0.18, 0.15, 1.6);
          A.bang.draw(ctx, bx + 250, 330, { scale: L2.s, rot: 0.2, v: boilIndex(t) });
        }
      }
    }
  });
}

function buildNotFoundScene() {
  const t0 = 22.4;
  const tMake = wd('make', 'make');
  const tMaybe = wd('make', 'maybe');
  const tSome = wd('find', 'somewhere');
  const scissorIn = [26.75, 27.3];
  const snips = [tMake + 0.42, tMake + 0.66];
  sfx(scissorIn[0], 'slide', 0.45, 0.6);
  sfx(scissorIn[1], 'tap', 0.35, 0.4);
  sfx(tMake, 'bell', 0.5, 0.2);
  snips.forEach((s) => sfx(s, 'snip', 0.65, 0.2));
  [22.9, 24.2, 25.5].forEach((s) => sfx(s + 0.5, 'rustle', 0.16, -0.4));
  S.notfound = { tMake, snips };
  S.drawNotFound = (ctx, t) => {
    const st = stepped(t);
    [
      [A.stars[0], 520, 930, 0.5, 0.5],
      [A.rock, 1650, 980, 0.42, 0.05],
      [A.stars[3], 1830, 880, 0.35, -0.3],
    ].forEach(([s, x, y, sc, r]) => s.draw(ctx, x, y, { scale: sc, rot: r }));
    A.magnifier.draw(ctx, 700, 1000, { rot: -1.3, scale: 0.6 });
    [
      [22.6, 760, 0],
      [23.9, 600, 8],
      [25.2, 900, 4],
    ].forEach(([s, y, k]) => {
      const p = (st - s) / 4.2;
      if (p < 0 || p > 1) return;
      A.scraps[k].draw(ctx, lerp(-200, 2200, p), y + Math.sin(p * 9) * 40, { rot: p * 5, scale: 0.6, lift: 0.8 });
    });
  };
  S.notfound.draw = (ctx, t) => {
    const st = stepped(t);
    const standing = t >= tMake;
    S.drawNotFound(ctx, t);
    const sp = ease.out(prog(st, scissorIn[0], scissorIn[1]));
    if (!standing) {
      drawScissors(ctx, lerp(2250, 1420, sp), 925, lerp(-1.2, -1.75, sp), 0.62, 0.32, { lift: 1 - sp });
      if (sp >= 1) {
        const k = prog(t, scissorIn[1] + 0.1, scissorIn[1] + 0.6);
        if (k > 0 && k < 1) sparkle(ctx, 1380, 880, 14 * Math.sin(k * Math.PI), rng(hash('gl', boilIndex(t))), PAL.mustard);
      }
      const sigh = st > tSome + 0.1 && st < tSome + 0.9;
      const noticed = t >= tMaybe + 0.05;
      pip(ctx, {
        x: 1110,
        y: 1000 + (sigh ? 8 : 0),
        scale: 1,
        legL: [2.2, -1.9],
        legR: [2.2, -1.9],
        armL: noticed ? [0.25, 0.1] : [0.1, -2.82],
        armR: noticed ? [0.4, 0.2] : [0.1, -2.82],
        head: noticed ? { rot: 0.1, dy: 0 } : { dy: 18, rot: Math.sin(st * 1.3) * 0.04 },
        expr: noticed ? 'wow' : sigh ? 'flat' : 'sad',
        eyes: noticed && t > tMaybe + 0.35 ? 'wide' : sigh ? 'closed' : 'dot',
        look: noticed ? [1, 0.5] : [0.2, 0.7],
        brows: noticed ? [5, 9] : [-2, -2],
        bob: 100,
        blink: !noticed && blinkAt(t, 2),
      }, t);
    } else {
      const open = snipOpen(t, snips, 0.4);
      const jumpP = prog(st, tMake, tMake + 0.25);
      pip(ctx, {
        x: 1110,
        y: 1060 - Math.sin(jumpP * Math.PI) * 60,
        scale: 1.3,
        armR: [2.55, 0.3],
        armL: [1.4, 0.4],
        expr: 'joy',
        look: [0.6, -0.6],
        front: (c, hands) => drawScissors(c, hands[1][0] + 10, hands[1][1] - 10, 0.35, 0.62, open, { v: boilIndex(t) }),
      }, t);
      const k = prog(t, tMake, tMake + 0.5);
      burst(ctx, 1235, 560, k, rng(hash('mk', boilIndex(t))), 10, 150, 260, PAL.orange);
    }
  };
  scene(t0, 29.05, (ctx, t) => {
    const z = kf(t, [
      [t0, 1.42],
      [27.1, 1.6, ease.inOutSine],
      [tMake, 1.6],
      [tMake + 0.5, 1.0],
    ]);
    const cx = kf(t, [
      [t0, 1110],
      [27.1, 1170],
      [tMake, 1170],
      [tMake + 0.5, 960],
    ]);
    const cy = kf(t, [
      [t0, 790],
      [27.1, 820],
      [tMake, 820],
      [tMake + 0.5, 540],
    ]);
    setCam(ctx, cx, cy, z);
    paperBG(ctx, PAL.paper, viewRect(cx, cy, z));
    S.notfound.draw(ctx, t);
  });
}

function buildMakingScene() {
  const t0 = 29.05;
  const tScraps = wd('scraps', 'out');
  const tCup = wd('cup', 'cup');
  const tLaugh = wd('laugh', 'laugh');
  const tQuestion = wd('question', 'question');
  const tGlad = wd('glad', 'glad');
  const tCut = wd('glue', 'cut');
  const tGlue = wd('glue', 'glue');
  const tLove = wd('glue', 'love');
  const tFinished = wd('unfinished', 'finished');
  const tSense = wd('unfinished', 'sense');
  const tJust = wd('yours', 'just');
  const tYours = wd('yours', 'yours');
  const board = { x: 900, y: 500, s: 1.15 };
  const pipX = 1640;
  const hand = [1800, 760];

  const scrapLand = [
    [90, 1000, 0],
    [420, 1035, 1],
    [880, 1045, 2],
    [1260, 1040, 3],
    [1850, 950, 5],
    [1800, 280, 6],
    [1760, 70, 7],
    [80, 120, 9],
    [70, 560, 10],
    [1860, 620, 11],
  ];
  const scrapT = scrapLand.map((_, i) => tScraps + 0.05 + i * 0.16);
  const items = {
    cup: { t: tCup - 0.42, to: [380, 310], s: 1.2, rot: -0.06 },
    faces: { t: tLaugh - 0.62, to: [790, 260], s: 1.15, rot: 0.02 },
    q: { t: tQuestion - 0.12, to: [1150, 300], s: 1.0, rot: 0.1 },
    dog: { t: tGlad - 0.62, to: [640, 770], s: 1.1, rot: -0.03 },
  };
  const FLY = 0.42;
  const snips = [tScraps + 0.25, tScraps + 0.6, tScraps + 1.0, tScraps + 1.4];
  for (const k in items) {
    snips.push(items[k].t - 0.08);
    sfx(items[k].t + FLY, 'tap', 0.5, (items[k].to[0] - 960) / 1200);
  }
  sfx(29.1, 'slide', 0.5, -0.6);
  sfx(29.55, 'thump', 0.35, -0.3);
  sfx(tScraps + 0.05, 'rustle', 0.5, 0.3);
  sfx(tScraps + 0.75, 'rustle', 0.4, -0.2);
  sfx(tLaugh - 0.02, 'laugh', 0.2, 0);
  sfx(tGlad + 0.08, 'bark', 0.35, -0.3);
  sfx(tGlad + 0.12, 'pop', 0.3, -0.2);

  const cal = { x: 1560, y: 260, s: 0.7, rot: 0.06 };
  const pieceTo = [
    [250, 840, -0.2],
    [1040, 800, 0.12],
    [1290, 480, -0.1],
    [240, 130, 0.15],
  ];
  const cell = A.calCells;
  const pieceFrom = [
    [3, 2],
    [5, 2],
    [3, 3],
    [4, 4],
  ].map(([col, row]) => [cal.x + (cell.x + (col + 0.5) * cell.cw) * cal.s, cal.y + (cell.y + (row + 0.5) * cell.ch) * cal.s]);
  const pieceT = [tCut + 0.1, tCut + 0.32, tCut + 0.54, tCut + 0.76];
  pieceT.forEach((pt, i) => {
    snips.push(pt - 0.06);
    sfx(pt + 0.38, 'tap', 0.35, (pieceTo[i][0] - 960) / 1200);
  });
  snips.forEach((s) => sfx(s, 'snip', 0.5, 0.45));
  sfx(tCut - 0.3, 'slide', 0.45, 0.6);

  const tapeT = [
    ['cup', tGlue + 0.05, 380, 205, -0.3],
    ['faces', tGlue + 0.3, 790, 150, 0.1],
    ['q', tGlue + 0.55, 1150, 165, -0.5],
    ['dog', tGlue + 0.8, 560, 650, 0.4],
    ['p1', tGlue + 1.05, 1040, 750, -0.2],
    ['p3', tGlue + 1.3, 240, 85, 0.3],
  ];
  tapeT.forEach(([, tt], i) => sfx(tt, i % 2 ? 'tape' : 'tap', i % 2 ? 0.35 : 0.3, 0));
  sfx(tLove + 0.05, 'pop', 0.25, 0);

  const extraT = 44.05;
  const extras = [
    ['sun', [1460, 560], 0.4, 0.1, [2300, 200]],
    ['star', [1190, 900], 0.5, 0.3, [600, 1400]],
    ['hand', [1470, 250], 0.32, -0.2, [1500, -400]],
    ['sandwich', [760, 545], 0.42, 0.05, [800, -400]],
    ['laurel', [250, 560], 0.95, -0.3, [-500, 600]],
    ['flower', [1320, 690], 1.3, 0.2, [2300, 900]],
    ['heart', [515, 560], 0.8, -0.2, [-400, 1300]],
  ];
  extras.forEach(([, to], i) => sfx(extraT + i * 0.09 + 0.35, 'tap', 0.25, (to[0] - 960) / 1200));
  sfx(extraT - 0.05, 'whoosh', 0.35, 0);
  sfx(tFinished - 0.15, 'pencil', 0.45, 0.3);
  sfx(tSense - 0.02, 'pop', 0.5, 0.2);
  sfx(tJust + 0.3, 'crayon', 0.6, -0.4);
  S.making = { board, items, extras };

  const itemPos = (k, t) => {
    const it = items[k];
    if (t < it.t) return null;
    const f = fly(t, it.t, it.t + FLY, hand, it.to, 260, k === 'q' ? 3 : 2);
    const L = landing(t, it.t + FLY, 0.12, 1.12);
    return { x: f.x, y: f.y, s: it.s * lerp(0.35, 1, ease.out(f.p)) * (f.p >= 1 ? L.s : 1), rot: it.rot + f.rot, lift: f.p < 1 ? f.lift : L.lift };
  };

  function drawItems(ctx, t, st) {
    const v = boilIndex(t);
    const cup = itemPos('cup', t);
    if (cup) {
      A.saucer.draw(ctx, cup.x, cup.y + 66 * cup.s, { scale: cup.s, rot: cup.rot, lift: cup.lift });
      A.cupBody.draw(ctx, cup.x, cup.y, { scale: cup.s, rot: cup.rot, lift: cup.lift, v });
      if (t > tCup + 0.1) {
        const r = rng(hash('steam', v));
        for (let i = 0; i < 3; i++) {
          const ph = st * 2.2 + i * 2.1;
          const pts = [];
          for (let k = 0; k < 9; k++) pts.push([cup.x - 34 + i * 34 + Math.sin(ph + k * 0.8) * 10, cup.y - 90 - k * 13]);
          ink(ctx, pts, r, { w: 4, alpha: 0.55 * prog(t, tCup + 0.1, tCup + 0.5), jit: 0.6 });
        }
      }
    }
    const fc = itemPos('faces', t);
    if (fc) {
      const laughing = t > tLaugh - 0.15;
      const bA = laughing ? -Math.abs(Math.sin(st * 9)) * 9 : 0;
      const bB = laughing ? -Math.abs(Math.sin(st * 9 + 1.2)) * 9 : 0;
      const sa = fc.s;
      for (const [face, hair, dx, bob, hy, seed] of [
        [A.faceA, A.hairA, -70, bA, -28, 1],
        [A.faceB, A.hairB, 70, bB, -24, 2],
      ]) {
        const x = fc.x + dx * sa;
        const y = fc.y + bob;
        face.draw(ctx, x, y, { scale: sa, rot: fc.rot + dx * 0.001, lift: fc.lift });
        ctx.save();
        ctx.translate(x, y);
        ctx.scale(sa * 1.35, sa * 1.35);
        drawFace(ctx, { expr: laughing ? 'joy' : 'smile' }, t, rng(hash('ff', seed, v)), null);
        ctx.restore();
        hair.draw(ctx, x, y + hy * sa * 0.2, { scale: sa, rot: fc.rot, v });
      }
      [
        [A.ha1, -150, -115, tLaugh + 0.02],
        [A.ha2, 140, -110, tLaugh + 0.18],
        [A.ha3, 10, 120, tLaugh + 0.34],
      ].forEach(([s, dx, dy, tt]) => {
        if (t < tt) return;
        const L = landing(t, tt, 0.15, 1.6);
        s.draw(ctx, fc.x + dx * sa * 1.2, fc.y + dy * sa * 1.1 + Math.sin(st * 6 + dx) * 4, { scale: L.s * 1.25, rot: dx * 0.0012, v });
      });
    }
    const q = itemPos('q', t);
    if (q) {
      const wig = t > tQuestion + 0.35 ? Math.sin(st * 7) * 0.13 : 0;
      A.curlyQ.draw(ctx, q.x, q.y, { scale: q.s, rot: q.rot + wig, lift: q.lift });
      if (t > tQuestion + 0.35) {
        const r = rng(hash('qs', v));
        for (let i = 0; i < 3; i++) {
          const k = (st * 0.8 + i / 3) % 1;
          sparkle(ctx, q.x + Math.cos(i * 2.1 + st) * 120, q.y - 40 + Math.sin(i * 2.1 + st) * 100, 13 * Math.sin(k * Math.PI), r, PAL.orange);
        }
      }
    }
    const dg = itemPos('dog', t);
    if (dg) {
      const s = dg.s;
      ctx.save();
      ctx.translate(dg.x, dg.y);
      ctx.rotate(dg.rot);
      ctx.scale(s, s);
      const r = rng(hash('dog', v));
      const wag = Math.sin(st * 18) * 0.5;
      const glad = t > tGlad;
      ink(ctx, spline([
        [-130, -10],
        [-165, -40 + wag * 30],
        [-178 + wag * 20, -84 + wag * 18],
      ], false, 6), r, { w: 8, taper: 0.7, jit: 0.6 });
      for (const lx of [-95, -60, 30, 62]) ink(ctx, [
        [lx, 40],
        [lx + (glad ? Math.sin(st * 9 + lx) * 5 : 0), 92],
      ], r, { w: 8, taper: 0.1, jit: 0.6 });
      A.dog.draw(ctx, 0, 0, { lift: dg.lift / s, v });
      A.dogEar.draw(ctx, 86, -112, { rot: 0.3 + (glad ? Math.sin(st * 9) * 0.15 : 0), v });
      if (glad) A.tongue.draw(ctx, 172, -30, { scale: 0.8, rot: Math.sin(st * 9) * 0.1 });
      ctx.restore();
      if (t >= tGlad + 0.1) {
        const L = landing(t, tGlad + 0.1, 0.18, 1.6);
        const fl = Math.sin(st * 3) * 6;
        A.heart.draw(ctx, dg.x + 150, dg.y - 175 + fl, { scale: 1.1 * L.s, rot: 0.15, lift: 0.4 });
      }
    }
    pieceT.forEach((pt, i) => {
      if (t < pt) return;
      const f = fly(t, pt, pt + 0.38, pieceFrom[i], pieceTo[i], 160, 2);
      const L = landing(t, pt + 0.38, 0.12, 1.12);
      A.dayPieces[i].draw(ctx, f.x, f.y, { rot: pieceTo[i][2] + f.rot, scale: 0.85 * (f.p >= 1 ? L.s : lerp(0.9, 1, f.p)), lift: f.p < 1 ? f.lift : L.lift, v });
    });
    tapeT.forEach(([, tt, x, y, rot], i) => {
      if (t < tt) return;
      const L = landing(t, tt, 0.1, 1.3);
      A.tapes[i].draw(ctx, x, y, { rot, scale: 0.75 * L.s, lift: L.lift * 0.5 });
    });
  }

  function drawExtras(ctx, t, st) {
    extras.forEach(([k, to, s, rot, from], i) => {
      const tt = extraT + i * 0.09;
      if (t < tt) return;
      const f = fly(t, tt, tt + 0.35, from, to, 120, 1.5);
      const L = landing(t, tt + 0.35, 0.1, 1.1);
      const sc = s * (f.p >= 1 ? L.s : 1);
      const o = { rot: rot + f.rot, scale: sc, lift: f.p < 1 ? f.lift : L.lift, v: boilIndex(t) };
      if (k === 'sun') {
        A.rays.draw(ctx, f.x, f.y, { ...o, rot: o.rot + st * 0.2 });
        A.sun.draw(ctx, f.x, f.y, o);
      } else if (k === 'star') A.stars[1].draw(ctx, f.x, f.y, o);
      else if (k === 'hand') A.handprint.draw(ctx, f.x, f.y, { ...o, lift: 0 });
      else if (k === 'laurel') A.laurel.draw(ctx, f.x, f.y, o);
      else if (k === 'flower') A.flower.draw(ctx, f.x, f.y, o);
      else if (k === 'heart') A.heartPink.draw(ctx, f.x, f.y, o);
      else if (k === 'sandwich') {
        [
          ['breadBot', 0],
          ['lettuce', -24],
          ['tomato', -42],
          ['cheese', -60],
          ['breadTop', -70],
        ].forEach(([n, dy]) => A[n].draw(ctx, f.x, f.y + dy * sc, o));
      }
    });
  }

  function crayonHeartInk(ctx, x, y, k, r) {
    const pts = [];
    const n = Math.floor(32 * k);
    for (let i = 0; i <= n; i++) {
      const a = (i / 32) * TAU;
      const hx = 16 * Math.pow(Math.sin(a), 3);
      const hy = -(13 * Math.cos(a) - 5 * Math.cos(2 * a) - 2 * Math.cos(3 * a) - Math.cos(4 * a));
      pts.push([x + hx * 2.2, y + hy * 2.2]);
    }
    if (pts.length > 2) ink(ctx, pts, r, { w: 7, color: PAL.red, jit: 0.8, taper: 0.4 });
  }

  function drawFinale(ctx, t, st) {
    if (t >= tFinished - 0.15) {
      const p = prog(t, tFinished - 0.15, tFinished + 0.45);
      const pts = spline(ellipsePts(1450, 815, 112, 80, 12).map(([x, y], i) => [x + (i % 3) * 3, y + (i % 2) * 4]), true, 6);
      const n = Math.floor(pts.length * p);
      const r = rng(hash('dash', boilIndex(t)));
      for (let i = 0; i + 3 < n; i += 7) ink(ctx, pts.slice(i, i + 4), r, { w: 3.2, color: '#5b5560', jit: 0.3, taper: 0.4 });
      if (p > 0.6) handText(ctx, 'more soon...', 1450, 827, rng(77), { size: 34, align: 'center', color: '#5b5560', reveal: prog(p, 0.6, 1), weight: 500 });
    }
    if (t >= tSense - 0.02) {
      const L = landing(t, tSense - 0.02, 0.18, 1.6);
      const x = 1010;
      const y = 570;
      const fr = -0.08 + Math.sin(st * 4) * 0.04;
      A.fish.draw(ctx, x, y, { scale: 0.72 * L.s, rot: fr, lift: L.lift, v: boilIndex(t) });
      ctx.save();
      ctx.translate(x, y);
      ctx.rotate(fr);
      ctx.scale(0.72 * L.s, 0.72 * L.s);
      A.topHat.draw(ctx, -70, -40, { scale: 0.42, rot: -0.25 });
      if (t > tSense + 0.5 && t < tSense + 0.75) {
        ctx.fillStyle = PAL.blue;
        ctx.beginPath();
        ctx.arc(-72, -10, 11, 0, TAU);
        ctx.fill();
        ink(ctx, [
          [-82, -9],
          [-62, -8],
        ], rng(3), { w: 3.5 });
      }
      ctx.restore();
    }
    if (t >= tJust + 0.3) {
      const p = prog(t, tJust + 0.3, tJust + 1.0);
      const s = A.mine;
      const x = 520;
      const y = 935;
      ctx.save();
      ctx.beginPath();
      ctx.rect(x - s.ox - 20, y - 120, (s.w + 40) * p, 220);
      ctx.clip();
      s.draw(ctx, x, y, { rot: -0.08, v: boilIndex(t) });
      ctx.restore();
      if (p >= 1) crayonHeartInk(ctx, x + 152, y - 32, prog(t, tJust + 1.0, tJust + 1.35), rng(hash('ch', boilIndex(t))));
    }
  }

  function drawPeople(ctx, t, st) {
    const v = boilIndex(t);
    const walkP = prog(t, 29.15, 29.85);
    const x = lerp(1110, pipX, ease.inOut(walkP));
    const walking = walkP > 0 && walkP < 1;
    const cutting = t >= tCut - 0.2 && t < tGlue;
    const open = snipOpen(t, snips, 0.38);
    const cheer = t >= tYours - 0.05;
    const shrug = t >= tSense + 0.4 && t < tJust;
    const puzzled = t > tSense && t < tJust;
    const hopY = cheer && st < tYours + 0.45 ? -Math.abs(Math.sin((st - tYours) * TAU * 1.1)) * 35 : 0;
    const pose = {
      x,
      y: 1075 + hopY,
      scale: 1.3,
      expr: t > tFinished - 0.3 && t < tSense ? 'smile' : 'joy',
      look: cutting ? [0.4, -1] : t > tSense ? [-1, 0.6] : [-1, -0.1],
      armR: cheer ? [2.7, 0.2] : cutting ? [2.3, 0.4] : [2.0, -0.3],
      armL: cheer ? [2.7, 0.2] : shrug ? [0.75, 1.7] : [0.3, 0.2],
      bob: idleBob(t, 4),
      blink: blinkAt(t, 6),
      front: (c, hands) => drawScissors(c, hands[1][0] + 8, hands[1][1] - 8, cutting ? 0.7 : -0.5, 0.5, open, { v }),
      ...(walking ? walkPose(stepped(walkP * 2.2, 8), 0.8) : {}),
    };
    if (walking) {
      pose.armR = [2.0, -0.3];
      pose.look = [1, 0];
    }
    if (shrug) pose.brows = [5, 5];
    pip(ctx, pose, t);

    if (t >= tGlue - 0.4) {
      const e = prog(st, tGlue - 0.4, tGlue + 0.1);
      const dab = t > tGlue + 0.1 ? Math.max(0, Math.sin(st * 10)) * 0.4 : 0;
      drawPerson(ctx, A.friendTeal, {
        x: lerp(-260, 130, ease.out(e)),
        y: 1085 + hopY * 0.8,
        scale: 1.25,
        ...(e < 1 ? walkPose(stepped(e * 1.6, 8), 0.8) : {}),
        armR: cheer ? [2.7, 0.2] : [2.1 + dab, -0.4 - dab],
        armL: cheer ? [2.7, 0.2] : [0.3, 0.1],
        expr: 'joy',
        look: puzzled ? [1, -0.3] : [1, -0.5],
        brows: puzzled ? [7, 3] : null,
        front: (c, hands) => {
          if (!cheer) A.glueStick.draw(c, hands[1][0] + 8, hands[1][1] - 40, { rot: 0.5 + dab, scale: 0.5 });
        },
      }, t);
      const e2 = prog(st, tGlue - 0.2, tGlue + 0.2);
      drawPerson(ctx, A.friendRed, {
        x: 1000,
        y: lerp(1600, 1110, ease.outBack(e2)) + hopY * 0.7,
        scale: 1.2,
        armL: cheer ? [2.7, 0.2] : [1.8, -0.6],
        armR: cheer ? [2.7, 0.2] : [1.0, -1.5],
        expr: 'joy',
        look: puzzled ? [-0.6, -0.8] : [-0.3, -1],
        brows: puzzled ? [3, 7] : null,
        front: (c, hands) => {
          if (!cheer) A.tapeRoll.draw(c, hands[1][0] + 10, hands[1][1] - 10, { scale: 0.55, rot: st });
        },
      }, t);
      const e3 = prog(st, tGlue - 0.1, tGlue + 0.25);
      drawPerson(ctx, A.friendLilac, {
        x: lerp(2250, 1880, ease.out(e3)),
        y: 1085 + hopY,
        scale: 1.25,
        ...(e3 < 1 ? walkPose(stepped(e3 * 1.5, 8), 0.8) : {}),
        armL: cheer ? [2.7, 0.2] : [2.2, 0.2],
        armR: cheer ? [2.7, 0.2] : [0.3, 0.1],
        expr: puzzled ? 'wow' : 'joy',
        look: [-1, -0.4],
      }, t);
    }
    if (t >= tLove) {
      for (let i = 0; i < 6; i++) {
        const ht = tLove + i * 0.12;
        if (t < ht) continue;
        const k = prog(st, ht, ht + 1.8);
        const hx = [130, 1000, 1640, 1880, 560, 1350][i];
        const hs = A[i % 2 ? 'heartPink' : 'heart'];
        hs.draw(ctx, hx + Math.sin(st * 3 + i) * 20, lerp(640, 60, k), { scale: 1.1 * ease.outBack(prog(st, ht, ht + 0.25)), rot: Math.sin(st * 2 + i) * 0.25, alpha: 1 - prog(k, 0.7, 1), lift: 0.6 });
      }
    }
  }

  scene(t0, 50.4, (ctx, t) => {
    const st = stepped(t);
    const cam = kf(t, [
      [t0, [960, 540, 1.0]],
      [tCut - 0.4, [930, 545, 1.03]],
      [tCut, [960, 540, 1.0]],
      [extraT - 0.1, [960, 545, 1.0]],
      [extraT + 1.0, [960, 585, 0.88]],
      [50.4, [960, 585, 0.91]],
    ]);
    setCam(ctx, cam[0], cam[1], cam[2]);
    paperBG(ctx, PAL.paper, viewRect(cam[0], cam[1], cam[2]));
    if (t < 29.7) S.drawNotFound(ctx, t);
    scrapLand.forEach(([x, y, k], i) => {
      const tt = scrapT[i];
      if (t < tt) return;
      const f = fly(t, tt, tt + 0.55, hand, [x, y], 300, 4);
      A.scraps[k].draw(ctx, f.x, f.y, { rot: i * 0.7 + f.rot, scale: 0.55, lift: f.p < 1 ? f.lift : 0 });
    });
    const bp = ease.out(prog(st, 29.1, 29.55));
    A.board.draw(ctx, lerp(-800, board.x, bp), board.y, { scale: board.s, rot: lerp(-0.12, -0.012, bp), lift: (1 - bp) * 0.8, shadowAlpha: 0.55 });
    if (t >= tCut - 0.35) {
      const cp = ease.out(prog(st, tCut - 0.35, tCut - 0.05));
      const out = prog(st, extraT - 0.3, extraT + 0.1);
      A.calendar.draw(ctx, lerp(2300, cal.x, cp) + out * 900, lerp(-300, cal.y, cp), { scale: cal.s, rot: cal.rot, lift: (1 - cp) * 0.7 });
      pieceT.forEach((pt, i) => {
        if (t < pt || out > 0) return;
        const [hx, hy] = pieceFrom[i];
        ctx.save();
        ctx.beginPath();
        ctx.ellipse(hx, hy, 24, 21, 0.2, 0, TAU);
        ctx.fillStyle = PAL.paper;
        ctx.fill();
        ctx.clip();
        ctx.lineWidth = 7;
        ctx.strokeStyle = 'rgba(60,40,20,0.35)';
        ctx.filter = 'blur(3px)';
        ctx.beginPath();
        ctx.ellipse(hx + 3, hy + 4, 24, 21, 0.2, 0, TAU);
        ctx.stroke();
        ctx.restore();
      });
    }
    drawExtras(ctx, t, st);
    drawItems(ctx, t, st);
    drawFinale(ctx, t, st);
    drawPeople(ctx, t, st);
  });
}

function buildEndScene() {
  const t0 = 50.0;
  const tSo = 50.75;
  const tWhat = 51.45;
  sfx(t0, 'tear', 0.55, 0.3);
  sfx(t0 + 0.05, 'whoosh', 0.35, 0.2);
  sfx(tSo, 'pencil', 0.35, 0);
  sfx(tWhat + 0.1, 'pencil', 0.4, 0);
  sfx(53.35, 'snip', 0.35, -0.5);
  sfx(53.65, 'snip', 0.3, -0.5);
  scene(t0, DURATION, (ctx, t) => {
    const st = stepped(t);
    const z = 1 + 0.03 * ease.inOutSine(prog(t, t0, DURATION));
    setCam(ctx, 960, 540, z);
    paperBG(ctx, '#efe2c6', viewRect(960, 540, z));
    ctx.save();
    ctx.strokeStyle = 'rgba(80,130,200,0.22)';
    ctx.lineWidth = 2;
    for (let y = 60; y < 1100; y += 64) {
      ctx.beginPath();
      ctx.moveTo(-100, y);
      ctx.lineTo(2100, y);
      ctx.stroke();
    }
    ctx.strokeStyle = 'rgba(220,80,80,0.35)';
    ctx.beginPath();
    ctx.moveTo(250, -100);
    ctx.lineTo(250, 1200);
    ctx.stroke();
    ctx.restore();
    const r = rng(hash('end', boilIndex(t)));
    if (t >= tSo) handText(ctx, 'So...', 960, 400, rng(hash('so', boilIndex(t))), { size: 150, align: 'center', reveal: prog(t, tSo, tSo + 0.45), weight: 700, font: FONTS.hand });
    if (t >= tWhat) {
      handText(ctx, 'what are you making?', 960, 610, rng(hash('wh', boilIndex(t))), { size: 185, align: 'center', reveal: prog(t, tWhat, tWhat + 1.3), weight: 700, font: FONTS.hand, color: PAL.red });
    }
    if (t >= 53.0) {
      const k = prog(t, 53.0, 53.5);
      const pts = [];
      const full = measure('what are you making?', FONTS.hand, 185, 700);
      const pre = measure('what are you ', FONTS.hand, 185, 700);
      const x0 = 960 - full / 2 + pre;
      const len = measure('making', FONTS.hand, 185, 700);
      for (let i = 0; i <= 30 * k; i++) pts.push([x0 + (i / 30) * len, 650 + Math.sin(i * 0.9) * 6]);
      if (pts.length > 2) ink(ctx, pts, r, { w: 6, color: PAL.red, jit: 0.8 });
    }
    if (t >= 52.6) {
      const e = ease.outBack(prog(st, 52.6, 53.1));
      drawScissors(ctx, lerp(-300, 400, e), 860, -2.2, 0.8, snipOpen(t, [53.35, 53.65], 0.45), { v: boilIndex(t), lift: 1 - e });
    }
    if (t >= 52.2) {
      const e = ease.outBack(prog(st, 52.2, 52.7));
      const wave = Math.sin(st * 7) * 0.35;
      pip(ctx, {
        x: 1600,
        y: lerp(1600, 1060, e),
        scale: 1.05,
        armR: [2.6 + wave, 0.5 + wave],
        armL: [0.25, 0.1],
        expr: 'joy',
        look: [-0.5, -0.4],
        blink: blinkAt(t, 9),
      }, t);
    }
  });
}

function buildScenes() {
  buildFiberTile();
  S.buffer = canvas(W, H);
  S.buffer2 = canvas(W, H);
  buildTitleScene();
  buildAnswersScene();
  buildLookingScene();
  buildNotFoundScene();
  buildMakingScene();
  buildEndScene();
  sfx(7.4, 'tear', 0.6, 0.4);
  sfx(7.45, 'whoosh', 0.3, 0.3);
  sfx(15.95, 'tear', 0.55, -0.4);
  sfx(16.0, 'whoosh', 0.3, -0.3);
  sfx(22.4, 'tear', 0.45, 0.4);
  sfx(22.45, 'slide', 0.35, 0.3);
}

const WIPES = [
  { a: 0, b: 1, t0: 7.4, t1: 7.9, dir: 1, seed: 11 },
  { a: 1, b: 2, t0: 15.95, t1: 16.45, dir: -1, seed: 12 },
  { a: 2, b: 3, t0: 22.4, t1: 23.0, dir: 1, seed: 13 },
  { a: 4, b: 5, t0: 50.0, t1: 50.55, dir: 1, seed: 14 },
];

function camVelocity(t) {
  const keys = t < 16.4 && t > 7.4 ? S.answers.camKeys : t > 15.95 && t < 22.95 ? S.looking.camKeys : null;
  if (!keys) return [0, 0];
  const a = kf(t - 1 / 60, keys);
  const b = kf(t + 1 / 60, keys);
  if (Math.abs(b[2] - a[2]) / a[2] > 0.004) return [0, 0];
  return [(b[0] - a[0]) * a[2] * 0.5, (b[1] - a[1]) * a[2] * 0.5];
}

function smear(ctx, dx, dy) {
  const n = Math.min(10, Math.ceil(Math.hypot(dx, dy) / 12));
  if (n < 2) return;
  const g = S.buffer2.getContext('2d');
  g.setTransform(1, 0, 0, 1, 0, 0);
  g.drawImage(ctx.canvas, 0, 0);
  ctx.save();
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  for (let i = 0; i < n; i++) {
    const k = i / (n - 1) - 0.5;
    ctx.globalAlpha = 1 / (i + 1);
    ctx.drawImage(S.buffer2, -dx * k, -dy * k);
  }
  ctx.restore();
}

function post(ctx, t) {
  ctx.save();
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  const warm = prog(t, 28.0, 29.0);
  const cool = t > 22.6 && t < 29.2 ? 1 - warm : 0;
  if (cool > 0) {
    ctx.globalCompositeOperation = 'multiply';
    ctx.globalAlpha = cool * prog(t, 22.6, 23.6);
    ctx.fillStyle = '#d9dfe6';
    ctx.fillRect(0, 0, W, H);
  }
  ctx.globalCompositeOperation = 'soft-light';
  ctx.globalAlpha = 0.18 + warm * 0.1;
  ctx.fillStyle = '#ffb36b';
  ctx.fillRect(0, 0, W, H);
  ctx.globalCompositeOperation = 'multiply';
  ctx.globalAlpha = 0.85;
  ctx.drawImage(TEX.vignette, 0, 0);
  const f = Math.floor(t * STEP_FPS);
  const fr = rng(f * 7 + 1);
  ctx.globalCompositeOperation = 'overlay';
  ctx.globalAlpha = 0.07;
  const pat = ctx.createPattern(TEX.film[f % TEX.film.length], 'repeat');
  pat.setTransform(new DOMMatrix().translate(fr() * 512, fr() * 512));
  ctx.fillStyle = pat;
  ctx.fillRect(0, 0, W, H);
  ctx.globalCompositeOperation = 'source-over';
  const flick = (fr() - 0.5) * 0.03;
  ctx.globalAlpha = Math.abs(flick);
  ctx.fillStyle = flick > 0 ? '#fff8e8' : '#1a120c';
  ctx.fillRect(0, 0, W, H);
  const fadeIn = 1 - prog(t, 0, 0.6);
  const fadeOut = prog(t, DURATION - 1.2, DURATION - 0.1);
  const fade = Math.max(fadeIn, fadeOut);
  if (fade > 0) {
    ctx.globalAlpha = fade;
    ctx.fillStyle = '#16110d';
    ctx.fillRect(0, 0, W, H);
  }
  ctx.restore();
}

function renderFrame(ctx, t) {
  t = clamp(t, 0, DURATION - 1e-4);
  const wipe = WIPES.find((w) => t >= w.t0 && t < w.t1);
  let base = SCENES.findIndex((s) => t >= s.t0 && t < s.t1);
  if (wipe) base = wipe.a;
  ctx.save();
  SCENES[base].draw(ctx, t);
  ctx.restore();
  const [vx, vy] = camVelocity(t);
  smear(ctx, vx, vy);
  if (wipe) {
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    tornWipe(ctx, (g) => {
      g.save();
      SCENES[wipe.b].draw(g, t);
      g.restore();
    }, prog(t, wipe.t0, wipe.t1), { seed: wipe.seed, dir: wipe.dir, buffer: S.buffer });
  }
  post(ctx, t);
}
