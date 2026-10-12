'use strict';

const W = 1920;
const H = 1080;
const FPS = 30;
const TAU = Math.PI * 2;
const INK = '#2a211c';
const RIM = '#f7f1e3';

const PAL = {
  cream: '#f3ead6',
  paper: '#efe4cc',
  red: '#e2543a',
  tomato: '#ec6a4c',
  mustard: '#f1b134',
  orange: '#f28c38',
  teal: '#2f9c95',
  navy: '#24304d',
  night: '#1d2742',
  pink: '#f1a7a0',
  blush: '#ee8c84',
  sage: '#9db68c',
  green: '#5f9e57',
  leaf: '#7cae5a',
  kraft: '#c69c6d',
  brown: '#8a5a3b',
  sky: '#9fd0e3',
  blue: '#4a7fc1',
  lilac: '#b9a3d6',
  gray: '#9a958c',
  stone: '#b8b2a6',
  skin: '#f6d6b8',
  skin2: '#d9a27a',
  skin3: '#9c6a4a',
  white: '#fbf8f0',
};

function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function hash(...parts) {
  const s = parts.join('|');
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619);
  return h >>> 0;
}

const lerp = (a, b, t) => a + (b - a) * t;
const clamp = (x, a = 0, b = 1) => Math.max(a, Math.min(b, x));
const prog = (t, a, b) => clamp((t - a) / (b - a));
const rr = (r, a, b) => a + (b - a) * r();

const ease = {
  lin: (t) => t,
  in: (t) => t * t * t,
  out: (t) => 1 - Math.pow(1 - t, 3),
  out2: (t) => 1 - (1 - t) * (1 - t),
  inOut: (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2),
  inOutSine: (t) => -(Math.cos(Math.PI * t) - 1) / 2,
  outBack: (t, s = 1.70158) => 1 + (s + 1) * Math.pow(t - 1, 3) + s * Math.pow(t - 1, 2),
  outElastic: (t) => (t <= 0 ? 0 : t >= 1 ? 1 : Math.pow(2, -10 * t) * Math.sin(((t * 10 - 0.75) * TAU) / 3) + 1),
  outBounce: (t) => {
    const n = 7.5625;
    const d = 2.75;
    if (t < 1 / d) return n * t * t;
    if (t < 2 / d) return n * (t -= 1.5 / d) * t + 0.75;
    if (t < 2.5 / d) return n * (t -= 2.25 / d) * t + 0.9375;
    return n * (t -= 2.625 / d) * t + 0.984375;
  },
};

// Stop-motion look: object motion is sampled on 12fps "twos" while the camera stays smooth at 30fps.
const STEP_FPS = 12;
const stepped = (t, fps = STEP_FPS) => Math.floor(t * fps + 1e-6) / fps;
const boilIndex = (t, n = 3, off = 0) => (Math.floor(t * 8 + off) % n + n) % n;

function canvas(w, h) {
  const c = document.createElement('canvas');
  c.width = Math.max(1, Math.ceil(w));
  c.height = Math.max(1, Math.ceil(h));
  return c;
}

function periodicNoise(r, octaves = 5, base = 3, persistence = 0.55) {
  const comps = [];
  let amp = 1;
  let f = base;
  let tot = 0;
  for (let o = 0; o < octaves; o++) {
    for (let k = 0; k < 2; k++) comps.push([Math.max(1, Math.round(f * (0.75 + r() * 0.6))), r() * TAU, amp * (0.6 + r() * 0.8)]);
    tot += amp * 2;
    amp *= persistence;
    f *= 2;
  }
  return (u) => {
    let s = 0;
    for (const [fr, ph, a] of comps) s += a * Math.sin(fr * u * TAU + ph);
    return (s / tot) * 2.2;
  };
}

function smoothNoise(r, octaves = 3, base = 1.3) {
  const comps = [];
  let amp = 1;
  let f = base;
  let tot = 0;
  for (let o = 0; o < octaves; o++) {
    comps.push([f * (0.7 + r() * 0.6), r() * TAU, amp]);
    tot += amp;
    amp *= 0.5;
    f *= 2.1;
  }
  return (u) => {
    let s = 0;
    for (const [fr, ph, a] of comps) s += a * Math.sin(fr * u * TAU + ph);
    return s / tot;
  };
}

function ellipsePts(cx, cy, rx, ry, n = 72, rot = 0) {
  const out = [];
  const c = Math.cos(rot);
  const s = Math.sin(rot);
  for (let i = 0; i < n; i++) {
    const a = (i / n) * TAU;
    const x = Math.cos(a) * rx;
    const y = Math.sin(a) * ry;
    out.push([cx + x * c - y * s, cy + x * s + y * c]);
  }
  return out;
}

function arcPts(cx, cy, rx, ry, a0, a1, n = 24) {
  const out = [];
  for (let i = 0; i <= n; i++) {
    const a = lerp(a0, a1, i / n);
    out.push([cx + Math.cos(a) * rx, cy + Math.sin(a) * ry]);
  }
  return out;
}

function rectPts(x, y, w, h) {
  return [
    [x, y],
    [x + w, y],
    [x + w, y + h],
    [x, y + h],
  ];
}

function roundRectPts(x, y, w, h, rad, n = 6) {
  const out = [];
  const corners = [
    [x + w - rad, y + rad, -Math.PI / 2],
    [x + w - rad, y + h - rad, 0],
    [x + rad, y + h - rad, Math.PI / 2],
    [x + rad, y + rad, Math.PI],
  ];
  for (const [cx, cy, a0] of corners) for (let i = 0; i <= n; i++) {
    const a = a0 + (i / n) * (Math.PI / 2);
    out.push([cx + Math.cos(a) * rad, cy + Math.sin(a) * rad]);
  }
  return out;
}

function starPts(cx, cy, r1, r2, n = 5, rot = -Math.PI / 2) {
  const out = [];
  for (let i = 0; i < n * 2; i++) {
    const a = rot + (i / (n * 2)) * TAU;
    const r = i % 2 ? r2 : r1;
    out.push([cx + Math.cos(a) * r, cy + Math.sin(a) * r]);
  }
  return out;
}

function spline(pts, closed = false, seg = 10) {
  const n = pts.length;
  if (n < 3) return pts.slice();
  const out = [];
  const get = (i) => (closed ? pts[(i + n) % n] : pts[clamp(i, 0, n - 1)]);
  const last = closed ? n : n - 1;
  for (let i = 0; i < last; i++) {
    const p0 = get(i - 1);
    const p1 = get(i);
    const p2 = get(i + 1);
    const p3 = get(i + 2);
    for (let j = 0; j < seg; j++) {
      const t = j / seg;
      const t2 = t * t;
      const t3 = t2 * t;
      out.push([
        0.5 * (2 * p1[0] + (-p0[0] + p2[0]) * t + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2 + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3),
        0.5 * (2 * p1[1] + (-p0[1] + p2[1]) * t + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2 + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3),
      ]);
    }
  }
  if (!closed) out.push(pts[n - 1].slice());
  return out;
}

function polyLength(pts, closed) {
  let L = 0;
  const n = pts.length;
  for (let i = 0; i < (closed ? n : n - 1); i++) {
    const a = pts[i];
    const b = pts[(i + 1) % n];
    L += Math.hypot(b[0] - a[0], b[1] - a[1]);
  }
  return L;
}

function turnAngle(pts, i, closed) {
  const n = pts.length;
  if (!closed && (i === 0 || i === n - 1)) return Math.PI;
  const a = pts[(i - 1 + n) % n];
  const b = pts[i];
  const c = pts[(i + 1) % n];
  const a1 = Math.atan2(b[1] - a[1], b[0] - a[0]);
  const a2 = Math.atan2(c[1] - b[1], c[0] - b[0]);
  let d = Math.abs(a2 - a1);
  if (d > Math.PI) d = TAU - d;
  return d;
}

// Walks the outline at caller-chosen intervals but always keeps sharp vertices so rectangles stay rectangles.
function resample(pts, closed, stepFn, cornerAngle = 0.45) {
  const n = pts.length;
  const segs = closed ? n : n - 1;
  const out = [];
  let need = typeof stepFn === 'function' ? stepFn() : stepFn;
  let acc = 0;
  out.push(pts[0].slice());
  for (let i = 0; i < segs; i++) {
    const a = pts[i];
    const b = pts[(i + 1) % n];
    const len = Math.hypot(b[0] - a[0], b[1] - a[1]);
    let pos = 0;
    while (acc + (len - pos) >= need) {
      pos += need - acc;
      const t = pos / len;
      out.push([lerp(a[0], b[0], t), lerp(a[1], b[1], t)]);
      acc = 0;
      need = typeof stepFn === 'function' ? stepFn() : stepFn;
    }
    acc += len - pos;
    const bi = (i + 1) % n;
    if (turnAngle(pts, bi, closed) > cornerAngle && (closed ? bi !== 0 : true)) {
      out.push(b.slice());
      acc = 0;
    }
  }
  if (closed && out.length > 1) {
    const f = out[0];
    const l = out[out.length - 1];
    if (Math.hypot(f[0] - l[0], f[1] - l[1]) < 1) out.pop();
  }
  if (!closed) {
    const e = pts[n - 1];
    const l = out[out.length - 1];
    if (Math.hypot(e[0] - l[0], e[1] - l[1]) > 0.5) out.push(e.slice());
  }
  return out;
}

function normalsOf(pts, closed) {
  const n = pts.length;
  const out = [];
  for (let i = 0; i < n; i++) {
    const a = closed ? pts[(i - 1 + n) % n] : pts[Math.max(0, i - 1)];
    const b = closed ? pts[(i + 1) % n] : pts[Math.min(n - 1, i + 1)];
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const l = Math.hypot(dx, dy) || 1;
    out.push([dy / l, -dx / l]);
  }
  return out;
}

function signedArea(pts) {
  let s = 0;
  for (let i = 0; i < pts.length; i++) {
    const a = pts[i];
    const b = pts[(i + 1) % pts.length];
    s += a[0] * b[1] - b[0] * a[1];
  }
  return s / 2;
}

function boundsOf(list) {
  let x0 = Infinity;
  let y0 = Infinity;
  let x1 = -Infinity;
  let y1 = -Infinity;
  for (const pts of list) for (const [x, y] of pts) {
    if (x < x0) x0 = x;
    if (y < y0) y0 = y;
    if (x > x1) x1 = x;
    if (y > y1) y1 = y;
  }
  return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
}

function tracePath(ctx, pts, closed = true) {
  ctx.beginPath();
  ctx.moveTo(pts[0][0], pts[0][1]);
  for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0], pts[i][1]);
  if (closed) ctx.closePath();
}

function outward(pts) {
  const sgn = signedArea(pts) > 0 ? 1 : -1;
  return normalsOf(pts, true).map(([x, y]) => [x * sgn, y * sgn]);
}

// A hand-cut scissor edge: short straight facets with tiny angular errors, as real cut paper has.
function cutOutline(pts, r, o = {}) {
  const minSeg = o.minSeg ?? 9;
  const maxSeg = o.maxSeg ?? 26;
  const jit = o.jitter ?? 1.1;
  const base = resample(pts, true, () => rr(r, minSeg, maxSeg));
  const nm = outward(base);
  return base.map((p, i) => {
    const d = (r() - 0.5) * 2 * jit;
    return [p[0] + nm[i][0] * d, p[1] + nm[i][1] * d];
  });
}

// Torn edge: the coloured face tears raggedly and the paler paper core shows as a fibrous rim outside it.
function tornOutline(pts, r, o = {}) {
  const amp = o.amp ?? 4;
  const rough = o.rough ?? 1.3;
  const rim = o.rim ?? 5;
  const base = resample(pts, true, o.step ?? 2.2);
  const nm = outward(base);
  const L = base.length;
  const n1 = periodicNoise(r, 6, o.freq ?? 4, 0.62);
  const n2 = periodicNoise(r, 4, 3, 0.6);
  const outer = [];
  const inner = [];
  for (let i = 0; i < L; i++) {
    const u = i / L;
    const d = amp * n1(u) + rough * (r() - 0.5) * 2;
    const rimW = rim * clamp(0.55 + 0.75 * n2(u), 0.05, 1.6);
    const din = d - rimW + rough * 0.6 * (r() - 0.5) * 2;
    outer.push([base[i][0] + nm[i][0] * d, base[i][1] + nm[i][1] * d]);
    inner.push([base[i][0] + nm[i][0] * din, base[i][1] + nm[i][1] * din]);
  }
  return { outer, inner };
}

const TEX = {};

function tileNoise(size, cells, r) {
  const g = new Float32Array(cells * cells);
  for (let i = 0; i < g.length; i++) g[i] = r();
  const out = new Float32Array(size * size);
  const sc = cells / size;
  for (let y = 0; y < size; y++) {
    const fy = y * sc;
    const y0 = Math.floor(fy);
    const ty = fy - y0;
    const sy = ty * ty * (3 - 2 * ty);
    const ya = (y0 % cells) * cells;
    const yb = ((y0 + 1) % cells) * cells;
    for (let x = 0; x < size; x++) {
      const fx = x * sc;
      const x0 = Math.floor(fx);
      const tx = fx - x0;
      const sx = tx * tx * (3 - 2 * tx);
      const xa = x0 % cells;
      const xb = (x0 + 1) % cells;
      const top = lerp(g[ya + xa], g[ya + xb], sx);
      const bot = lerp(g[yb + xa], g[yb + xb], sx);
      out[y * size + x] = lerp(top, bot, sy);
    }
  }
  return out;
}

function fbmTile(size, r, octaves) {
  const acc = new Float32Array(size * size);
  let tot = 0;
  for (const [cells, w] of octaves) {
    const n = tileNoise(size, cells, r);
    for (let i = 0; i < acc.length; i++) acc[i] += n[i] * w;
    tot += w;
  }
  for (let i = 0; i < acc.length; i++) acc[i] /= tot;
  return acc;
}

function buildTextures() {
  const r = rng(7);
  const S = 512;

  const grain = canvas(S, S);
  {
    const g = grain.getContext('2d');
    const img = g.createImageData(S, S);
    const n = fbmTile(S, r, [
      [4, 1.0],
      [16, 0.7],
      [64, 0.45],
      [128, 0.35],
    ]);
    for (let i = 0; i < S * S; i++) {
      const v = 255 - (n[i] * 30 + r() * 16 + 4);
      img.data[i * 4] = v;
      img.data[i * 4 + 1] = v - 1;
      img.data[i * 4 + 2] = v - 4;
      img.data[i * 4 + 3] = 255;
    }
    g.putImageData(img, 0, 0);
    g.lineCap = 'round';
    for (let i = 0; i < 700; i++) {
      const x = r() * S;
      const y = r() * S;
      const a = r() * TAU;
      const l = 4 + r() * 22;
      g.strokeStyle = `rgba(120,100,70,${0.04 + r() * 0.08})`;
      g.lineWidth = 0.4 + r() * 0.7;
      g.beginPath();
      g.moveTo(x, y);
      g.quadraticCurveTo(x + Math.cos(a + 0.6) * l * 0.5, y + Math.sin(a + 0.6) * l * 0.5, x + Math.cos(a) * l, y + Math.sin(a) * l);
      g.stroke();
    }
  }
  TEX.grain = grain;

  const crayon = canvas(S, S);
  {
    const g = crayon.getContext('2d');
    const img = g.createImageData(S, S);
    const n = fbmTile(S, r, [
      [32, 0.5],
      [128, 1.0],
      [256, 0.8],
    ]);
    for (let i = 0; i < S * S; i++) {
      const v = n[i] + (r() - 0.5) * 0.35;
      const a = clamp((v - 0.3) * 3.2);
      img.data[i * 4] = 0;
      img.data[i * 4 + 1] = 0;
      img.data[i * 4 + 2] = 0;
      img.data[i * 4 + 3] = a * 255;
    }
    g.putImageData(img, 0, 0);
  }
  TEX.crayon = crayon;

  const mottle = canvas(S, S);
  {
    const g = mottle.getContext('2d');
    const img = g.createImageData(S, S);
    const n = fbmTile(S, r, [
      [3, 1.0],
      [6, 0.8],
      [12, 0.5],
      [24, 0.25],
    ]);
    for (let i = 0; i < S * S; i++) {
      const v = clamp(0.5 + (n[i] - 0.5) * 1.6) * 255;
      img.data[i * 4] = v;
      img.data[i * 4 + 1] = v;
      img.data[i * 4 + 2] = v;
      img.data[i * 4 + 3] = 255;
    }
    g.putImageData(img, 0, 0);
  }
  TEX.mottle = mottle;

  TEX.film = [];
  for (let k = 0; k < 6; k++) {
    const c = canvas(S, S);
    const g = c.getContext('2d');
    const img = g.createImageData(S, S);
    for (let i = 0; i < S * S; i++) {
      const v = 128 + (r() + r() + r() - 1.5) * 90;
      img.data[i * 4] = v;
      img.data[i * 4 + 1] = v;
      img.data[i * 4 + 2] = v;
      img.data[i * 4 + 3] = 255;
    }
    g.putImageData(img, 0, 0);
    TEX.film.push(c);
  }

  const vig = canvas(W, H);
  {
    const g = vig.getContext('2d');
    const grd = g.createRadialGradient(W / 2, H * 0.48, H * 0.35, W / 2, H / 2, H * 1.05);
    grd.addColorStop(0, 'rgba(255,255,255,1)');
    grd.addColorStop(0.65, 'rgba(236,226,210,1)');
    grd.addColorStop(1, 'rgba(150,128,105,1)');
    g.fillStyle = grd;
    g.fillRect(0, 0, W, H);
  }
  TEX.vignette = vig;
}

function grainFill(ctx, alpha = 1, scale = 1, offx = 0, offy = 0) {
  const pat = ctx.createPattern(TEX.grain, 'repeat');
  pat.setTransform(new DOMMatrix().translate(offx, offy).scale(scale));
  ctx.save();
  ctx.globalCompositeOperation = 'multiply';
  ctx.globalAlpha = alpha;
  ctx.fillStyle = pat;
  ctx.fillRect(-5000, -5000, 10000, 10000);
  ctx.restore();
}

function mottleFill(ctx, alpha, scale = 2, mode = 'soft-light', offx = 0, offy = 0) {
  const pat = ctx.createPattern(TEX.mottle, 'repeat');
  pat.setTransform(new DOMMatrix().translate(offx, offy).scale(scale));
  ctx.save();
  ctx.globalCompositeOperation = mode;
  ctx.globalAlpha = alpha;
  ctx.fillStyle = pat;
  ctx.fillRect(-5000, -5000, 10000, 10000);
  ctx.restore();
}

function shadeColor(hex, k) {
  const n = parseInt(hex.slice(1), 16);
  let r = (n >> 16) & 255;
  let g = (n >> 8) & 255;
  let b = n & 255;
  if (k < 0) {
    r *= 1 + k;
    g *= 1 + k;
    b *= 1 + k;
  } else {
    r += (255 - r) * k;
    g += (255 - g) * k;
    b += (255 - b) * k;
  }
  return `rgb(${r | 0},${g | 0},${b | 0})`;
}

function makeBackdrop(w, h, color, seed, o = {}) {
  const c = canvas(w, h);
  const g = c.getContext('2d');
  const r = rng(seed);
  g.fillStyle = color;
  g.fillRect(0, 0, w, h);
  mottleFill(g, o.mottle ?? 0.35, 3.2, 'soft-light', r() * 500, r() * 500);
  mottleFill(g, 0.12, 1.1, 'multiply', r() * 500, r() * 500);
  if (o.pattern) o.pattern(g, { x: 0, y: 0, w, h }, r);
  grainFill(g, o.grain ?? 0.9, 1.4, r() * 500, r() * 500);
  g.lineCap = 'round';
  for (let i = 0; i < (o.fibers ?? 900); i++) {
    const x = r() * w;
    const y = r() * h;
    const a = r() * TAU;
    const l = 6 + r() * 30;
    const light = r() < 0.5;
    g.strokeStyle = light ? `rgba(255,252,240,${0.05 + r() * 0.12})` : `rgba(60,40,20,${0.03 + r() * 0.06})`;
    g.lineWidth = 0.5 + r() * 0.9;
    g.beginPath();
    g.moveTo(x, y);
    g.quadraticCurveTo(x + Math.cos(a + 0.8) * l * 0.5, y + Math.sin(a + 0.8) * l * 0.5, x + Math.cos(a) * l, y + Math.sin(a) * l);
    g.stroke();
  }
  for (let i = 0; i < (o.specks ?? 260); i++) {
    g.fillStyle = `rgba(50,35,20,${0.08 + r() * 0.25})`;
    g.beginPath();
    g.arc(r() * w, r() * h, 0.4 + r() * 1.2, 0, TAU);
    g.fill();
  }
  return c;
}

class Sprite {
  constructor(frames, shadow, ox, oy, w, h, res, shadowPad) {
    this.frames = frames;
    this.shadow = shadow;
    this.ox = ox;
    this.oy = oy;
    this.w = w;
    this.h = h;
    this.res = res;
    this.shadowPad = shadowPad;
  }

  // lift raises the paper off the page: the shadow grows, softens and drifts down-right (light is top-left).
  draw(ctx, x, y, o = {}) {
    const rot = o.rot ?? 0;
    const sx = (o.sx ?? 1) * (o.scale ?? 1);
    const sy = (o.sy ?? 1) * (o.scale ?? 1);
    const alpha = o.alpha ?? 1;
    if (alpha <= 0.001 || sx === 0 || sy === 0) return;
    const lift = o.lift ?? 0;
    const f = this.frames[(o.v ?? 0) % this.frames.length];
    if (this.shadow && o.shadow !== false) {
      const k = Math.abs(sx);
      const dx = (3 + lift * 14) * k;
      const dy = (5 + lift * 22) * k;
      ctx.save();
      ctx.globalAlpha = alpha * (o.shadowAlpha ?? 0.42) * (1 - lift * 0.35);
      ctx.translate(x + dx, y + dy);
      ctx.rotate(rot);
      ctx.scale(sx * (1 + lift * 0.04), sy * (1 + lift * 0.04));
      const p = this.shadowPad;
      ctx.drawImage(this.shadow, -this.ox - p, -this.oy - p, this.w + p * 2, this.h + p * 2);
      ctx.restore();
    }
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.translate(x, y);
    ctx.rotate(rot);
    ctx.scale(sx, sy);
    ctx.drawImage(f, -this.ox, -this.oy, this.w, this.h);
    ctx.restore();
  }
}

const SCRATCH = { c: null };
function scratchCanvas(w, h) {
  if (!SCRATCH.c || SCRATCH.c.width < w || SCRATCH.c.height < h) SCRATCH.c = canvas(Math.max(w, SCRATCH.c?.width || 0), Math.max(h, SCRATCH.c?.height || 0));
  const g = SCRATCH.c.getContext('2d');
  g.setTransform(1, 0, 0, 1, 0, 0);
  g.clearRect(0, 0, SCRATCH.c.width, SCRATCH.c.height);
  return SCRATCH.c;
}

/*
 * Builds a cut-paper sprite. Options:
 *   shape: closed point list in local coords (origin = anchor)
 *   edge: 'cut' | 'torn'; color; pattern(ctx, bounds, r); ink(ctx, r, variant) for line work on top
 *   variants: number of boil frames (only the ink layer changes between them)
 */
function traceMulti(ctx, list) {
  ctx.beginPath();
  for (const pts of list) {
    ctx.moveTo(pts[0][0], pts[0][1]);
    for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0], pts[i][1]);
    ctx.closePath();
  }
}

function makePaper(o) {
  const shapes = o.shapes ?? [o.shape];
  const seed = o.seed ?? hash(JSON.stringify(shapes[0].slice(0, 3)), o.color);
  const r = rng(seed);
  const res = o.res ?? 1.25;
  const variants = o.ink ? (o.variants ?? 3) : 1;
  const outers = [];
  const inners = [];
  for (const shape of shapes) {
    if (o.edge === 'torn') {
      const t = tornOutline(shape, r, { amp: o.amp ?? 3.5, rough: o.rough ?? 1.2, rim: o.rim ?? 5, freq: o.freq });
      outers.push(t.outer);
      inners.push(t.inner);
    } else if (o.edge === 'none') {
      outers.push(shape);
      inners.push(shape);
    } else {
      const c = cutOutline(shape, r, { jitter: o.jitter ?? 1.0, minSeg: o.minSeg, maxSeg: o.maxSeg });
      outers.push(c);
      inners.push(c);
    }
  }
  const pad = o.pad ?? 24;
  const b = boundsOf([...outers, ...(o.extraBounds || [])]);
  const bx = b.x - pad;
  const by = b.y - pad;
  const bw = b.w + pad * 2;
  const bh = b.h + pad * 2;

  const base = canvas(bw * res, bh * res);
  const g = base.getContext('2d');
  g.scale(res, res);
  g.translate(-bx, -by);
  if (o.under) o.under(g, rng(seed + 5));
  if (o.edge === 'torn') {
    traceMulti(g, outers);
    g.fillStyle = o.rimColor ?? RIM;
    g.fill('evenodd');
  }
  g.save();
  traceMulti(g, inners);
  g.clip('evenodd');
  g.fillStyle = o.color;
  g.fillRect(bx, by, bw, bh);
  if (o.pattern) o.pattern(g, { x: bx, y: by, w: bw, h: bh }, rng(seed + 11));
  mottleFill(g, o.mottle ?? 0.28, 1.6, 'soft-light', r() * 400, r() * 400);
  grainFill(g, o.grain ?? 0.85, 0.9, r() * 400, r() * 400);
  const lg = g.createLinearGradient(b.x, b.y, b.x + b.w, b.y + b.h);
  lg.addColorStop(0, 'rgba(255,255,255,0.10)');
  lg.addColorStop(1, 'rgba(0,0,0,0.07)');
  g.fillStyle = lg;
  g.fillRect(bx, by, bw, bh);
  g.globalCompositeOperation = 'multiply';
  g.strokeStyle = 'rgba(80,55,35,0.22)';
  g.lineWidth = 2.2;
  g.filter = 'blur(1.2px)';
  traceMulti(g, inners);
  g.stroke();
  g.restore();
  if (o.edge === 'torn') {
    g.save();
    traceMulti(g, outers);
    g.clip('evenodd');
    grainFill(g, 0.5, 0.6, r() * 300, r() * 300);
    g.restore();
  }
  if (o.post) o.post(g, rng(seed + 17), { outers, inners });

  const frames = [];
  for (let v = 0; v < variants; v++) {
    if (!o.ink) {
      frames.push(base);
      break;
    }
    const f = canvas(base.width, base.height);
    const fg = f.getContext('2d');
    fg.drawImage(base, 0, 0);
    fg.scale(res, res);
    fg.translate(-bx, -by);
    o.ink(fg, rng(seed * 7 + v * 131 + 3), v, { outers, inners, outer: outers[0], inner: inners[0] });
    frames.push(f);
  }

  let shadow = null;
  const sp = 16;
  if (o.shadow !== false) {
    const sr = 0.5;
    shadow = canvas((bw + sp * 2) * sr, (bh + sp * 2) * sr);
    const sg = shadow.getContext('2d');
    sg.scale(sr, sr);
    sg.translate(-bx + sp, -by + sp);
    sg.filter = `blur(${(o.shadowBlur ?? 5) * sr}px)`;
    sg.fillStyle = 'rgba(40,25,10,1)';
    traceMulti(sg, outers);
    sg.fill('evenodd');
    if (o.shadowExtra) o.shadowExtra(sg);
  }
  const sprite = new Sprite(frames, shadow, -bx, -by, bw, bh, res, sp);
  sprite.bounds = b;
  return sprite;
}

function rdp(pts, eps) {
  if (pts.length < 3) return pts;
  const keep = new Uint8Array(pts.length);
  keep[0] = keep[pts.length - 1] = 1;
  const stack = [[0, pts.length - 1]];
  while (stack.length) {
    const [a, b] = stack.pop();
    let dmax = 0;
    let idx = -1;
    const [x1, y1] = pts[a];
    const [x2, y2] = pts[b];
    const dx = x2 - x1;
    const dy = y2 - y1;
    const len = Math.hypot(dx, dy) || 1;
    for (let i = a + 1; i < b; i++) {
      const d = Math.abs(dy * pts[i][0] - dx * pts[i][1] + x2 * y1 - y2 * x1) / len;
      if (d > dmax) {
        dmax = d;
        idx = i;
      }
    }
    if (dmax > eps && idx > 0) {
      keep[idx] = 1;
      stack.push([a, idx], [idx, b]);
    }
  }
  return pts.filter((_, i) => keep[i]);
}

// Marching squares over an alpha mask; segments are linked into closed loops (outer outlines and holes alike).
function contoursFromCanvas(c, scale = 1, thresh = 128, eps = 0.9) {
  const w = c.width;
  const h = c.height;
  const data = c.getContext('2d').getImageData(0, 0, w, h).data;
  const inside = (x, y) => x >= 0 && y >= 0 && x < w && y < h && data[(y * w + x) * 4 + 3] >= thresh;
  const key = (x, y) => x * 4 + ',' + y * 4;
  const next = new Map();
  const add = (ax, ay, bx2, by2) => next.set(key(ax, ay), [bx2, by2, key(bx2, by2), ax, ay]);
  for (let y = -1; y < h; y++) for (let x = -1; x < w; x++) {
    const tl = inside(x, y);
    const tr = inside(x + 1, y);
    const br = inside(x + 1, y + 1);
    const bl = inside(x, y + 1);
    const code = (tl ? 8 : 0) | (tr ? 4 : 0) | (br ? 2 : 0) | (bl ? 1 : 0);
    if (code === 0 || code === 15) continue;
    const T = [x + 0.5, y];
    const R = [x + 1, y + 0.5];
    const B = [x + 0.5, y + 1];
    const L = [x, y + 0.5];
    const seg = (p, q) => add(p[0], p[1], q[0], q[1]);
    switch (code) {
      case 1: seg(L, B); break;
      case 2: seg(B, R); break;
      case 3: seg(L, R); break;
      case 4: seg(R, T); break;
      case 5: seg(L, T); seg(R, B); break;
      case 6: seg(B, T); break;
      case 7: seg(L, T); break;
      case 8: seg(T, L); break;
      case 9: seg(T, B); break;
      case 10: seg(T, R); seg(B, L); break;
      case 11: seg(T, R); break;
      case 12: seg(R, L); break;
      case 13: seg(R, B); break;
      case 14: seg(B, L); break;
    }
  }
  const loops = [];
  const used = new Set();
  for (const [k0, v0] of next) {
    if (used.has(k0)) continue;
    const loop = [];
    let k = k0;
    let v = v0;
    while (v && !used.has(k)) {
      used.add(k);
      loop.push([v[3] * scale, v[4] * scale]);
      k = v[2];
      v = next.get(k);
    }
    if (loop.length > 8) {
      let far = 0;
      let fd = 0;
      for (let i = 1; i < loop.length; i++) {
        const d = Math.hypot(loop[i][0] - loop[0][0], loop[i][1] - loop[0][1]);
        if (d > fd) {
          fd = d;
          far = i;
        }
      }
      // Closed loops are split at the farthest point because RDP needs distinct chord endpoints.
      const simp = rdp(loop.slice(0, far + 1), eps * scale).concat(rdp(loop.slice(far).concat([loop[0]]), eps * scale).slice(1, -1));
      if (simp.length >= 3 && Math.abs(signedArea(simp)) > 20 * scale * scale) loops.push(simp);
    }
  }
  return loops;
}

/* Draw anything with canvas commands inside box {x,y,w,h}; returns its outline contours in the same coordinates. */
function shapeFromDraw(box, fn, q = 1) {
  const c = canvas(box.w * q + 4, box.h * q + 4);
  const g = c.getContext('2d');
  g.translate(2, 2);
  g.scale(q, q);
  g.translate(-box.x, -box.y);
  g.fillStyle = '#000';
  g.strokeStyle = '#000';
  g.lineCap = 'round';
  g.lineJoin = 'round';
  fn(g);
  return contoursFromCanvas(c, 1 / q).map((pts) => pts.map(([x, y]) => [x - 2 / q + box.x, y - 2 / q + box.y]));
}

function textShapes(str, font, size, o = {}) {
  const m = scratchMeasure();
  m.font = `${o.weight ?? 400} ${size}px ${font}`;
  const tm = m.measureText(str);
  const w = Math.ceil(tm.actualBoundingBoxLeft + tm.actualBoundingBoxRight) + 8;
  const asc = tm.actualBoundingBoxAscent;
  const desc = tm.actualBoundingBoxDescent;
  const box = { x: -w / 2, y: -(asc + desc) / 2 - 4, w, h: asc + desc + 8 };
  const shapes = shapeFromDraw(box, (g) => {
    g.font = `${o.weight ?? 400} ${size}px ${font}`;
    g.textBaseline = 'alphabetic';
    if (o.stroke) {
      g.lineWidth = o.stroke;
      g.strokeText(str, -w / 2 + 4 + tm.actualBoundingBoxLeft, (asc - desc) / 2);
    }
    g.fillText(str, -w / 2 + 4 + tm.actualBoundingBoxLeft, (asc - desc) / 2);
  }, o.q ?? 1);
  return { shapes, w, h: asc + desc };
}

function makeInkSprite(bnds, inkFn, o = {}) {
  const res = o.res ?? 1.25;
  const variants = o.variants ?? 3;
  const seed = o.seed ?? 99;
  const pad = 16;
  const bx = bnds.x - pad;
  const by = bnds.y - pad;
  const bw = bnds.w + pad * 2;
  const bh = bnds.h + pad * 2;
  const frames = [];
  for (let v = 0; v < variants; v++) {
    const f = canvas(bw * res, bh * res);
    const g = f.getContext('2d');
    g.scale(res, res);
    g.translate(-bx, -by);
    inkFn(g, rng(seed * 7 + v * 131 + 3), v);
    frames.push(f);
  }
  return new Sprite(frames, null, -bx, -by, bw, bh, res, 0);
}

function jitterLine(pts, r, amt) {
  if (amt <= 0) return pts;
  const nx = smoothNoise(r, 3, 1.1);
  const ny = smoothNoise(r, 3, 1.1);
  const L = pts.length;
  const ox = (r() - 0.5) * amt * 0.6;
  const oy = (r() - 0.5) * amt * 0.6;
  return pts.map((p, i) => [p[0] + nx(i / L) * amt + ox, p[1] + ny(i / L) * amt + oy]);
}

/*
 * Brush-pen stroke rendered as a filled polygon so width can swell and taper like real ink.
 * o.w width, o.jit boil wobble in px, o.taper 0..1, o.closed with overshoot for hand-drawn loops.
 */
function ink(ctx, pts, r, o = {}) {
  const w = o.w ?? 4;
  const jit = o.jit ?? 1.1;
  let src = pts;
  if (o.closed) {
    const n = pts.length;
    const over = Math.max(2, Math.round(n * (o.overshoot ?? 0.08)));
    src = pts.concat(pts.slice(0, over + 1).map((p, i) => [p[0] + (i / over) * 2.5, p[1] + (i / over) * 1.5]));
  }
  let p = resample(src, false, o.step ?? 2.5, 9);
  if (p.length < 2) return;
  p = jitterLine(p, r, jit);
  const n = p.length;
  const nm = normalsOf(p, false);
  const L = polyLength(p, false);
  const wn = smoothNoise(r, 3, 2.2);
  const taperLen = Math.min(L * 0.35, o.taperLen ?? 26);
  const taper = o.taper ?? 0.85;
  const left = [];
  const right = [];
  let s = 0;
  for (let i = 0; i < n; i++) {
    if (i > 0) s += Math.hypot(p[i][0] - p[i - 1][0], p[i][1] - p[i - 1][1]);
    let k = 1;
    if (taperLen > 0) {
      const e = Math.min(s, L - s) / taperLen;
      k = lerp(1, Math.sqrt(clamp(e, 0.04, 1)), taper);
      if (o.startBlunt && s < L / 2) k = 1;
    }
    const ww = (w / 2) * k * (1 + (o.wvar ?? 0.28) * wn(s / Math.max(L, 1)));
    left.push([p[i][0] + nm[i][0] * ww, p[i][1] + nm[i][1] * ww]);
    right.push([p[i][0] - nm[i][0] * ww, p[i][1] - nm[i][1] * ww]);
  }
  ctx.save();
  ctx.fillStyle = o.color ?? INK;
  ctx.globalAlpha *= o.alpha ?? 1;
  tracePath(ctx, left.concat(right.reverse()));
  ctx.fill();
  const capR = (w / 2) * (1 - taper) * 0.98;
  if (capR > 0.3) {
    ctx.beginPath();
    ctx.arc(p[0][0], p[0][1], capR, 0, TAU);
    ctx.arc(p[n - 1][0], p[n - 1][1], capR, 0, TAU);
    ctx.fill();
  }
  ctx.restore();
}

function inkDot(ctx, x, y, rad, r, color = INK) {
  const n = periodicNoise(r, 2, 2, 0.5);
  const pts = [];
  const m = 18;
  const k = 0.12;
  for (let i = 0; i < m; i++) {
    const a = (i / m) * TAU;
    const rr2 = rad * (1 + k * n(i / m));
    pts.push([x + Math.cos(a) * rr2, y + Math.sin(a) * rr2 * 1.05]);
  }
  ctx.save();
  ctx.fillStyle = color;
  tracePath(ctx, pts);
  ctx.fill();
  ctx.restore();
}

// Crayon marks: strokes go to a scratch canvas in device space, then a speckle mask eats holes into them like wax on tooth.
function crayon(ctx, pts, r, o = {}) {
  const c = ctx.canvas;
  const sc = scratchCanvas(c.width, c.height);
  const g = sc.getContext('2d');
  g.setTransform(ctx.getTransform());
  g.lineCap = 'round';
  g.lineJoin = 'round';
  const passes = o.passes ?? 3;
  for (let k = 0; k < passes; k++) {
    const q = jitterLine(resample(pts, !!o.closed, 3, 9), r, o.jit ?? 1.6);
    g.strokeStyle = o.color ?? '#333';
    g.globalAlpha = o.passAlpha ?? 0.55;
    g.lineWidth = (o.w ?? 7) * rr(r, 0.7, 1.05);
    tracePath(g, q, !!o.closed);
    g.stroke();
  }
  g.setTransform(1, 0, 0, 1, 0, 0);
  g.globalAlpha = 1;
  g.globalCompositeOperation = 'destination-out';
  const pat = g.createPattern(TEX.crayon, 'repeat');
  pat.setTransform(new DOMMatrix().translate(r() * 300, r() * 300).scale(o.grainScale ?? 0.7));
  g.fillStyle = pat;
  g.globalAlpha = o.bite ?? 0.75;
  g.fillRect(0, 0, c.width, c.height);
  g.globalCompositeOperation = 'source-over';
  g.globalAlpha = 1;
  ctx.save();
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.globalAlpha *= o.alpha ?? 1;
  ctx.drawImage(sc, 0, 0, c.width, c.height, 0, 0, c.width, c.height);
  ctx.restore();
}

function crayonFill(ctx, shape, r, o = {}) {
  const b = boundsOf([shape]);
  const gap = o.gap ?? 7;
  const ang = o.angle ?? -0.5;
  const cx = b.x + b.w / 2;
  const cy = b.y + b.h / 2;
  const R0 = Math.hypot(b.w, b.h) / 2 + 10;
  const pts = [];
  let dir = 1;
  for (let d = -R0; d <= R0; d += gap) {
    const ux = Math.cos(ang);
    const uy = Math.sin(ang);
    const px = -uy;
    const py = ux;
    const a = [cx + px * d - ux * R0 * dir, cy + py * d - uy * R0 * dir];
    const bb = [cx + px * d + ux * R0 * dir, cy + py * d + uy * R0 * dir];
    pts.push(a, bb);
    dir *= -1;
  }
  ctx.save();
  tracePath(ctx, shape);
  ctx.clip();
  crayon(ctx, pts, r, { w: o.w ?? gap * 1.5, color: o.color, passes: o.passes ?? 2, jit: 2, bite: o.bite ?? 0.6, alpha: o.alpha ?? 0.9 });
  ctx.restore();
}

function blush(ctx, x, y, rad, r, color = PAL.blush, alpha = 0.55) {
  ctx.save();
  const grd = ctx.createRadialGradient(x, y, 0, x, y, rad);
  grd.addColorStop(0, color);
  grd.addColorStop(1, 'rgba(0,0,0,0)');
  ctx.globalAlpha *= alpha;
  ctx.fillStyle = grd;
  ctx.beginPath();
  ctx.arc(x, y, rad, 0, TAU);
  ctx.fill();
  ctx.restore();
  crayonFill(ctx, ellipsePts(x, y, rad * 0.62, rad * 0.5, 20), r, { color, gap: 3.5, w: 4, alpha: 0.5, angle: 0.4 });
}

const FONTS = {
  hand: '"Caveat", cursive',
  brush: '"Caveat Brush", cursive',
  kalam: '"Kalam", cursive',
  marker: '"Permanent Marker", cursive',
  gochi: '"Gochi Hand", cursive',
  patrick: '"Patrick Hand", cursive',
  type: '"Special Elite", monospace',
  courier: '"Courier Prime", monospace',
  reenie: '"Reenie Beanie", cursive',
};
const RANSOM_FONTS = ['"Abril Fatface"', '"Bowlby One"', '"Alfa Slab One"', '"Rye"', '"Ultra"', '"Courier Prime"', '"Playfair Display"', '"Bungee"', '"Old Standard TT"', '"Shrikhand"', '"Special Elite"', '"Permanent Marker"'];

// Draws text glyph by glyph with per-letter wobble so lettering reads as written, not typeset.
function handText(ctx, str, x, y, r, o = {}) {
  const size = o.size ?? 60;
  ctx.save();
  ctx.font = `${o.weight ?? 600} ${size}px ${o.font ?? FONTS.hand}`;
  ctx.fillStyle = o.color ?? INK;
  ctx.textBaseline = 'alphabetic';
  const ls = o.spacing ?? 0;
  const widths = [...str].map((ch) => ctx.measureText(ch).width + ls);
  const total = widths.reduce((a, b) => a + b, 0) - ls;
  let cx = x - (o.align === 'center' ? total / 2 : o.align === 'right' ? total : 0);
  const reveal = o.reveal ?? 1;
  const chars = [...str];
  const nVis = reveal * chars.length;
  const j = o.jit ?? 1;
  for (let i = 0; i < chars.length; i++) {
    const vis = clamp(nVis - i);
    if (vis > 0) {
      ctx.save();
      ctx.translate(cx + widths[i] / 2, y + (r() - 0.5) * 3 * j);
      ctx.rotate((r() - 0.5) * 0.09 * j);
      const s = o.pop ? ease.outBack(vis) : 1;
      ctx.scale(s, s);
      ctx.globalAlpha *= Math.min(1, vis * 2);
      if (o.stroke) {
        ctx.lineWidth = o.stroke;
        ctx.strokeStyle = o.strokeColor ?? RIM;
        ctx.lineJoin = 'round';
        ctx.strokeText(chars[i], -widths[i] / 2 + ls / 2, 0);
      }
      ctx.fillText(chars[i], -widths[i] / 2 + ls / 2, 0);
      ctx.restore();
    } else {
      r();
      r();
    }
    cx += widths[i];
  }
  ctx.restore();
  return total;
}

function measure(str, font, size, weight = 600) {
  const c = scratchMeasure();
  c.font = `${weight} ${size}px ${font}`;
  return c.measureText(str).width;
}
let MEASURE_CTX = null;
function scratchMeasure() {
  if (!MEASURE_CTX) MEASURE_CTX = canvas(4, 4).getContext('2d');
  return MEASURE_CTX;
}

const PATTERNS = {
  stripes(c1, w = 14, angle = 0.6, alpha = 1) {
    return (g, b) => {
      g.save();
      g.translate(b.x + b.w / 2, b.y + b.h / 2);
      g.rotate(angle);
      g.fillStyle = c1;
      g.globalAlpha = alpha;
      const R0 = Math.hypot(b.w, b.h);
      for (let x = -R0; x < R0; x += w * 2) g.fillRect(x, -R0, w, R0 * 2);
      g.restore();
    };
  },
  dots(c1, sp = 26, rad = 5, alpha = 1) {
    return (g, b) => {
      g.save();
      g.fillStyle = c1;
      g.globalAlpha = alpha;
      for (let y = b.y, row = 0; y < b.y + b.h + sp; y += sp * 0.87, row++) for (let x = b.x + (row % 2 ? sp / 2 : 0); x < b.x + b.w + sp; x += sp) {
        g.beginPath();
        g.arc(x, y, rad, 0, TAU);
        g.fill();
      }
      g.restore();
    };
  },
  gingham(c1, sp = 22, alpha = 0.35) {
    return (g, b) => {
      g.save();
      g.fillStyle = c1;
      g.globalAlpha = alpha;
      for (let x = b.x; x < b.x + b.w; x += sp * 2) g.fillRect(x, b.y, sp, b.h);
      for (let y = b.y; y < b.y + b.h; y += sp * 2) g.fillRect(b.x, y, b.w, sp);
      g.restore();
    };
  },
  grid(c1 = 'rgba(70,120,190,0.35)', sp = 24) {
    return (g, b) => {
      g.save();
      g.strokeStyle = c1;
      g.lineWidth = 1.1;
      for (let x = b.x - (b.x % sp); x < b.x + b.w; x += sp) {
        g.beginPath();
        g.moveTo(x, b.y);
        g.lineTo(x, b.y + b.h);
        g.stroke();
      }
      for (let y = b.y - (b.y % sp); y < b.y + b.h; y += sp) {
        g.beginPath();
        g.moveTo(b.x, y);
        g.lineTo(b.x + b.w, y);
        g.stroke();
      }
      g.restore();
    };
  },
  lined(c1 = 'rgba(80,130,200,0.45)', sp = 30, margin = true) {
    return (g, b) => {
      g.save();
      g.strokeStyle = c1;
      g.lineWidth = 1.4;
      for (let y = b.y + sp; y < b.y + b.h; y += sp) {
        g.beginPath();
        g.moveTo(b.x, y);
        g.lineTo(b.x + b.w, y);
        g.stroke();
      }
      if (margin) {
        g.strokeStyle = 'rgba(220,80,80,0.5)';
        g.beginPath();
        g.moveTo(b.x + 60, b.y);
        g.lineTo(b.x + 60, b.y + b.h);
        g.stroke();
      }
      g.restore();
    };
  },
  newsprint(size = 11, color = 'rgba(40,35,30,0.62)') {
    const words = 'the of and to in a is that for it as was with be by on not he this are or his from at which but have an they you were her she there one all we their what so up out if about who get them make can like time just him know take people into year your good some could see other than then now look only come over think also back after use two how our work first well way even new want because any these give day most us life purpose small things morning friend laugh glad here question ordinary days love scraps cut glue paper'.split(' ');
    return (g, b, r) => {
      g.save();
      g.fillStyle = color;
      g.font = `${size}px "Old Standard TT", "Playfair Display", serif`;
      const colW = 150;
      const lh = size * 1.25;
      for (let cx = b.x + 6; cx < b.x + b.w; cx += colW + 14) {
        let y = b.y + lh;
        if (r() < 0.5) {
          g.save();
          g.font = `700 ${size * 2.1}px "Playfair Display", serif`;
          g.fillText(words[(r() * words.length) | 0].toUpperCase(), cx, y + size);
          g.restore();
          y += lh * 2.4;
        }
        while (y < b.y + b.h + lh) {
          let line = '';
          while (g.measureText(line).width < colW - 20) line += words[(r() * words.length) | 0] + ' ';
          g.fillText(line, cx, y);
          y += lh;
        }
      }
      g.restore();
    };
  },
  halftone(c1, sp = 9, angle = 0.3) {
    return (g, b, r) => {
      g.save();
      g.fillStyle = c1;
      const cx = b.x + b.w * (0.2 + r() * 0.6);
      const cy = b.y + b.h * (0.2 + r() * 0.6);
      const R0 = Math.hypot(b.w, b.h) * 0.6;
      g.translate(cx, cy);
      g.rotate(angle);
      for (let y = -R0; y < R0; y += sp) for (let x = -R0; x < R0; x += sp) {
        const d = Math.hypot(x, y) / R0;
        const rad = sp * 0.5 * clamp(1.05 - d);
        if (rad > 0.3) {
          g.beginPath();
          g.arc(x, y, rad, 0, TAU);
          g.fill();
        }
      }
      g.restore();
    };
  },
  staff(color = 'rgba(40,30,30,0.55)') {
    return (g, b, r) => {
      g.save();
      g.strokeStyle = color;
      g.fillStyle = color;
      g.lineWidth = 1.2;
      for (let y0 = b.y + 30; y0 < b.y + b.h; y0 += 90) {
        for (let k = 0; k < 5; k++) {
          g.beginPath();
          g.moveTo(b.x, y0 + k * 9);
          g.lineTo(b.x + b.w, y0 + k * 9);
          g.stroke();
        }
        for (let x = b.x + 20; x < b.x + b.w; x += 34 + r() * 20) {
          const ny = y0 + Math.round(r() * 8) * 4.5;
          g.beginPath();
          g.ellipse(x, ny, 5.5, 4, -0.4, 0, TAU);
          g.fill();
          g.beginPath();
          g.moveTo(x + 5, ny);
          g.lineTo(x + 5, ny - 28);
          g.stroke();
        }
      }
      g.restore();
    };
  },
  speckle(c1, n = 300, alpha = 0.5) {
    return (g, b, r) => {
      g.save();
      g.fillStyle = c1;
      g.globalAlpha = alpha;
      for (let i = 0; i < n; i++) {
        g.beginPath();
        g.arc(b.x + r() * b.w, b.y + r() * b.h, 0.8 + r() * 2.2, 0, TAU);
        g.fill();
      }
      g.restore();
    };
  },
  chain(...fns) {
    return (g, b, r) => fns.forEach((f) => f(g, b, r));
  },
};

function makeTape(w, h, seed, color = 'rgba(236,222,180,0.78)') {
  const r = rng(seed);
  const shape = [];
  const n = 7;
  for (let i = 0; i <= n; i++) shape.push([-w / 2 + (i / n) * w, -h / 2]);
  for (let i = 0; i <= 5; i++) shape.push([w / 2 + (i % 2 ? 4 : -2) * r(), -h / 2 + (i / 5) * h]);
  for (let i = n; i >= 0; i--) shape.push([-w / 2 + (i / n) * w, h / 2]);
  for (let i = 5; i >= 0; i--) shape.push([-w / 2 + (i % 2 ? -4 : 2) * r(), -h / 2 + (i / 5) * h]);
  return makePaper({ shape, color, edge: 'none', seed, shadowBlur: 2, grain: 0.5, mottle: 0.1, res: 1.25 });
}

function tornWipe(ctx, drawB, p, o = {}) {
  if (p <= 0) return;
  const seed = o.seed ?? 1;
  const dir = o.dir ?? 1;
  const r = rng(seed);
  const n1 = smoothNoise(r, 4, 3.5);
  const tilt = o.tilt ?? 0.12;
  const pe = (o.ease ?? ease.inOut)(clamp(p));
  const edgeX = lerp(dir > 0 ? W + 220 : -220, dir > 0 ? -260 : W + 260, pe);
  const pts = [];
  const rim = [];
  const steps = 140;
  const rn = rng(seed + 9);
  for (let i = 0; i <= steps; i++) {
    const y = -40 + (i / steps) * (H + 80);
    const d = n1(i / steps) * 38 + (rn() - 0.5) * 5 + (y - H / 2) * tilt;
    pts.push([edgeX + d, y]);
    rim.push([edgeX + d - dir * (6 + 5 * Math.abs(n1(i / steps + 0.3))) + (rn() - 0.5) * 3, y]);
  }
  const far = dir > 0 ? W + 400 : -400;
  const region = pts.concat([
    [far, H + 60],
    [far, -60],
  ]);
  const rimRegion = rim.concat([
    [far, H + 60],
    [far, -60],
  ]);
  const buf = o.buffer;
  const bg = buf.getContext('2d');
  bg.setTransform(1, 0, 0, 1, 0, 0);
  bg.clearRect(0, 0, W, H);
  drawB(bg);
  ctx.save();
  ctx.filter = 'blur(14px)';
  ctx.fillStyle = 'rgba(40,25,10,0.38)';
  ctx.translate(-dir * 10, 8);
  tracePath(ctx, rimRegion);
  ctx.fill();
  ctx.restore();
  ctx.save();
  tracePath(ctx, rimRegion);
  ctx.fillStyle = RIM;
  ctx.fill();
  ctx.clip();
  grainFill(ctx, 0.6, 0.8);
  ctx.restore();
  ctx.save();
  tracePath(ctx, region);
  ctx.clip();
  ctx.drawImage(buf, 0, 0);
  ctx.restore();
}
