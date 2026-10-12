'use strict';

(() => {
  const cv = document.getElementById('c');
  const ctx = cv.getContext('2d');
  const audio = document.getElementById('audio');
  const playBtn = document.getElementById('play');
  const seek = document.getElementById('seek');
  const timeEl = document.getElementById('time');
  const cover = document.getElementById('cover');
  const loading = document.getElementById('loading');
  const capture = new URLSearchParams(location.search).has('capture');

  async function boot() {
    await Promise.all([...document.fonts].map((f) => f.load().catch(() => null)));
    buildTextures();
    buildArt();
    buildScenes();
    loading.hidden = true;
  }

  const ready = boot();
  window.__ready = ready.then(() => true);
  window.__duration = () => DURATION;
  window.__renderFrame = (t) => renderFrame(ctx, t);
  window.__cues = () => SFX_CUES.slice().sort((a, b) => a.t - b.t);

  if (capture) return;

  const POSTER = typeof POSTER_T === 'number' ? POSTER_T : 4;
  let playing = false;
  let started = false;
  let clockStart = 0;
  let clockOffset = 0;
  const audioOk = () => audio.readyState >= 2 && !audio.error;
  const now = () => (playing ? (audioOk() ? audio.currentTime : clockOffset + (performance.now() - clockStart) / 1000) : clockOffset);

  function setPlaying(p) {
    playing = p;
    if (p) started = true;
    document.body.classList.toggle('paused', !p);
    playBtn.textContent = p ? 'Pause' : 'Play';
    if (p) {
      clockStart = performance.now();
      if (audioOk()) {
        audio.currentTime = clockOffset;
        audio.play().catch(() => {});
      }
    } else {
      clockOffset = now();
      audio.pause();
    }
  }

  playBtn.onclick = () => setPlaying(!playing);
  cover.onclick = () => {
    cover.hidden = true;
    setPlaying(true);
  };
  seek.oninput = () => {
    started = true;
    clockOffset = (seek.value / 1000) * DURATION;
    clockStart = performance.now();
    if (audioOk()) audio.currentTime = clockOffset;
  };
  window.addEventListener('keydown', (e) => {
    if (e.code === 'Space') {
      e.preventDefault();
      if (!cover.hidden) cover.hidden = true;
      setPlaying(!playing);
    }
  });

  ready.then(() => {
    cover.hidden = false;
    const loop = () => {
      let t = now();
      if (!started && !playing) t = POSTER;
      if (t >= DURATION) {
        t = DURATION;
        if (playing) {
          setPlaying(false);
          clockOffset = 0;
        }
      }
      renderFrame(ctx, Math.min(t, DURATION - 1e-3));
      const shown = started || playing ? t : 0;
      seek.value = (shown / DURATION) * 1000;
      timeEl.textContent = `${shown.toFixed(1)}s`;
      requestAnimationFrame(loop);
    };
    loop();
  });
})();
