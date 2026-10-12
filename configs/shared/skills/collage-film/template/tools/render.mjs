// Usage: node render.mjs <out.mp4> [startSec endSec]
import { chromium } from 'playwright-core';
import { spawn } from 'node:child_process';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const out = path.resolve(process.argv[2] || path.join(root, 'render/purpose-of-life.mp4'));
const FPS = 30;

const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--allow-file-access-from-files'] });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
const errors = [];
page.on('pageerror', (e) => errors.push(String(e)));
await page.goto('file://' + path.join(root, 'web/index.html') + '?capture');
await page.evaluate(() => window.__ready);
const duration = await page.evaluate(() => window.__duration());
const start = Number(process.argv[3] ?? 0);
const end = Number(process.argv[4] ?? duration);
const first = Math.round(start * FPS);
const last = Math.round(end * FPS);

const ff = spawn('ffmpeg', [
  '-hide_banner', '-loglevel', 'error', '-y',
  '-f', 'image2pipe', '-c:v', 'png', '-framerate', String(FPS), '-i', '-',
  ...(process.env.NOAUDIO ? [] : ['-ss', String(start), '-t', String(end - start), '-i', path.join(root, 'audio/mix.wav')]),
  '-map', '0:v', ...(process.env.NOAUDIO ? [] : ['-map', '1:a']),
  '-c:v', 'libx264', '-preset', 'slow', '-crf', '15', '-tune', 'film', '-pix_fmt', 'yuv420p', '-profile:v', 'high',
  '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
  ...(process.env.NOAUDIO ? [] : ['-c:a', 'aac', '-b:a', '256k', '-ar', '48000']),
  '-movflags', '+faststart', '-shortest', out,
], { stdio: ['pipe', 'inherit', 'inherit'] });

const t0 = Date.now();
for (let f = first; f < last; f++) {
  const b64 = await page.evaluate((t) => {
    window.__renderFrame(t);
    return document.getElementById('c').toDataURL('image/png').split(',')[1];
  }, f / FPS);
  const buf = Buffer.from(b64, 'base64');
  if (!ff.stdin.write(buf)) await new Promise((r) => ff.stdin.once('drain', r));
  if ((f - first) % 150 === 0) console.log(`frame ${f}/${last} ${((Date.now() - t0) / 1000).toFixed(0)}s`);
}
ff.stdin.end();
await new Promise((r) => ff.on('close', r));
await browser.close();
console.log(`done ${out} in ${((Date.now() - t0) / 1000).toFixed(0)}s`);
if (errors.length) console.log('PAGE ERRORS:\n' + errors.join('\n'));
