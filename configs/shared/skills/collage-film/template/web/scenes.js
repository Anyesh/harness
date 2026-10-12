'use strict';

const END_T = wd('bye', 'film');
const DURATION = Math.ceil(END_T + 2);
const POSTER_T = 2.5;
const PAPER_TEXTURE = 1;
const WIPES = [];

function GRADE() {
  return { wash: 0.18, vignette: 0.85, cool: 0, warm: 0 };
}

function buildScenes() {
  buildStage();
  const titleT = 0.6;
  A.title.forEach((c, i) => sfx(titleT + i * 0.08, 'tap', 0.3, -0.4 + i * 0.2));

  scene(0, DURATION, (ctx, t) => {
    let x = 960 - 300;
    A.title.forEach((c, i) => {
      const tt = titleT + i * 0.08;
      if (t >= tt) {
        const L = landing(t, tt, 0.17, 1.35);
        c.draw(ctx, x + c.cw / 2, 330 + c.dy, { rot: c.tilt, scale: L.s, lift: L.lift });
      }
      x += c.cw + 8;
    });
    drawPerson(ctx, A.hero, { x: 960, y: 1040, scale: 1.4, expr: 'joy', armR: [2.6, 0.3], look: [0, -0.5], blink: blinkAt(t) }, t);
  }, { cam: [[0, [960, 540, 1]], [DURATION, [960, 540, 1.04]]] });
}
