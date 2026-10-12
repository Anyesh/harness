// Usage: node snap.mjs <out.jpg> <cols> <thumbWidth> t1 t2 ...   (one contact sheet of the given times)
import { chromium } from 'playwright-core';
import fs from 'node:fs';
import path from 'node:path';

const [out, colsArg, widthArg, ...times] = process.argv.slice(2);
const cols = Number(colsArg);
const tw = Number(widthArg);
const page_url = 'file://' + path.resolve(import.meta.dirname, '../web/index.html') + '?capture';

const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--allow-file-access-from-files', '--disable-gpu-vsync'] });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
const errors = [];
page.on('pageerror', (e) => errors.push(String(e.stack || e)));
page.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warning') errors.push(m.text()); });
await page.goto(page_url);
const t0 = Date.now();
await page.evaluate(() => window.__ready);
const bootMs = Date.now() - t0;
const data = await page.evaluate(({ times, cols, tw }) => {
  const th = Math.round((tw * 9) / 16);
  const rows = Math.ceil(times.length / cols);
  const sheet = document.createElement('canvas');
  sheet.width = cols * tw;
  sheet.height = rows * th;
  const g = sheet.getContext('2d');
  g.fillStyle = '#000';
  g.fillRect(0, 0, sheet.width, sheet.height);
  const src = document.getElementById('c');
  const ms = [];
  times.forEach((t, i) => {
    const a = performance.now();
    window.__renderFrame(Number(t));
    ms.push(performance.now() - a);
    const x = (i % cols) * tw;
    const y = Math.floor(i / cols) * th;
    g.drawImage(src, x, y, tw, th);
    g.fillStyle = 'rgba(0,0,0,.6)';
    g.fillRect(x, y, 64, 22);
    g.fillStyle = '#fff';
    g.font = '15px monospace';
    g.fillText(Number(t).toFixed(2), x + 5, y + 16);
  });
  return { url: sheet.toDataURL('image/jpeg', 0.88), ms };
}, { times, cols, tw });
fs.writeFileSync(out, Buffer.from(data.url.split(',')[1], 'base64'));
console.log(`boot ${bootMs}ms, frame ms avg ${(data.ms.reduce((a, b) => a + b, 0) / data.ms.length).toFixed(0)} max ${Math.max(...data.ms).toFixed(0)}`);
if (errors.length) console.log('ERRORS:\n' + errors.slice(0, 10).join('\n'));
await browser.close();
