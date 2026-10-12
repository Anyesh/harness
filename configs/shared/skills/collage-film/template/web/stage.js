'use strict';

const SFX_CUES = [];
const SCENES = [];
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

function viewRect(cx, cy, z) {
  const w = W / z + 80;
  const h = H / z + 80;
  return { x: cx - w / 2, y: cy - h / 2, w, h };
}

// Built from tileable patterns anchored in world space so that camera moves never reveal a seam.
function paperBG(ctx, color, view) {
  const { x, y, w, h } = view;
  const k = typeof PAPER_TEXTURE === 'number' ? PAPER_TEXTURE : 1;
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
    ctx.globalAlpha = alpha * k;
    ctx.fillStyle = pat;
    ctx.fillRect(x, y, w, h);
  }
  ctx.restore();
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

/*
 * Registers a scene. o.cam: camera keyframes [[t, [cx, cy, zoom]], ...]; when given, the scene's
 * camera is applied and the paper table drawn before draw(ctx, t, cam) runs, and fast pans get motion smear.
 */
function scene(t0, t1, draw, o = {}) {
  const s = { t0, t1, draw, cam: o.cam, table: o.table ?? PAL.paper };
  SCENES.push(s);
  return s;
}

function drawScene(s, ctx, t) {
  ctx.save();
  if (s.cam) {
    const [cx, cy, z] = kf(t, s.cam);
    setCam(ctx, cx, cy, z);
    paperBG(ctx, s.table, viewRect(cx, cy, z));
    s.draw(ctx, t, { cx, cy, z, view: viewRect(cx, cy, z) });
  } else {
    s.draw(ctx, t);
  }
  ctx.restore();
}

// Smear only pure pans: during a zoom the centre moves too, and a linear smear would streak sideways.
function camVelocity(s, t) {
  if (!s.cam) return [0, 0];
  const a = kf(t - 1 / 60, s.cam);
  const b = kf(t + 1 / 60, s.cam);
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

/*
 * Film finish: optional grade from GRADE(t) -> {cool, warm} (0..1), warm soft-light wash,
 * vignette, 12fps film grain and exposure flicker, fade in from and out to black.
 */
function post(ctx, t) {
  const g = typeof GRADE === 'function' ? GRADE(t) : { cool: 0, warm: 0 };
  ctx.save();
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  if (g.cool > 0) {
    ctx.globalCompositeOperation = 'multiply';
    ctx.globalAlpha = g.cool;
    ctx.fillStyle = '#d9dfe6';
    ctx.fillRect(0, 0, W, H);
  }
  ctx.globalCompositeOperation = 'soft-light';
  ctx.globalAlpha = (g.wash ?? 0.18) + (g.warm ?? 0) * 0.1;
  ctx.fillStyle = '#ffb36b';
  ctx.fillRect(0, 0, W, H);
  ctx.globalCompositeOperation = 'multiply';
  ctx.globalAlpha = g.vignette ?? 0.85;
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
  const fade = Math.max(1 - prog(t, 0, 0.6), prog(t, DURATION - 1.2, DURATION - 0.1));
  if (fade > 0) {
    ctx.globalAlpha = fade;
    ctx.fillStyle = '#16110d';
    ctx.fillRect(0, 0, W, H);
  }
  ctx.restore();
}

function buildStage() {
  buildFiberTile();
  S.buffer = canvas(W, H);
  S.buffer2 = canvas(W, H);
}

// WIPES entries: { a, b, t0, t1, dir, seed } with a/b as SCENES indexes; the incoming scene is torn in over the outgoing one.
function renderFrame(ctx, t) {
  t = clamp(t, 0, DURATION - 1e-4);
  const wipe = (typeof WIPES !== 'undefined' ? WIPES : []).find((w) => t >= w.t0 && t < w.t1);
  let base = SCENES.findIndex((s) => t >= s.t0 && t < s.t1);
  if (wipe) base = wipe.a;
  if (base < 0) base = SCENES.length - 1;
  const s = SCENES[base];
  drawScene(s, ctx, t);
  const [vx, vy] = camVelocity(s, t);
  smear(ctx, vx, vy);
  if (wipe) {
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    tornWipe(ctx, (g) => drawScene(SCENES[wipe.b], g, t), prog(t, wipe.t0, wipe.t1), { seed: wipe.seed, dir: wipe.dir, buffer: S.buffer });
  }
  post(ctx, t);
}
