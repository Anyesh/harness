import base64
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WEB = ROOT / "web"
TITLE = sys.argv[1] if len(sys.argv) > 1 else "Untitled Film"
CREDIT = sys.argv[2] if len(sys.argv) > 2 else "Drawn live in your browser with canvas. Space plays and pauses."


def b64(path):
    return base64.b64encode(path.read_bytes()).decode()


index = (WEB / "index.html").read_text()
font_css = re.sub(
    r"url\(fonts/([^)]+)\)",
    lambda m: f'url(data:font/ttf;base64,{b64(WEB / "fonts" / m.group(1))}) format("truetype")',
    "\n".join(re.findall(r"@font-face \{[^}]+\}", index)),
)
scripts = "\n".join(f"<script>\n{(WEB / s).read_text()}\n</script>" for s in re.findall(r'<script src="([^"]+)"></script>', index))
audio = b64(WEB / "audio/mix.m4a")

page = f"""<title>{TITLE}</title>
<style>
{font_css}
/* Layout: one screening table; the film is the page, controls sit on a paper strip beneath it. */
:root {{
  color-scheme: dark;
  --table: #1e1814;
  --table-edge: #2b221c;
  --paper: #efe4cc;
  --ink: #2a211c;
  --accent: #e2543a;
  --muted: #b7a88f;
  --hand: "Caveat", "Patrick Hand", "Comic Sans MS", cursive;
  --body: "Patrick Hand", "Trebuchet MS", system-ui, sans-serif;
}}
html, body {{ height: 100%; }}
body {{ margin: 0; background: radial-gradient(120% 90% at 50% 40%, var(--table-edge), var(--table)); color: var(--paper); font: 18px/1.4 var(--body); }}
.wrap {{ min-height: 100%; box-sizing: border-box; display: grid; place-content: center; gap: 14px; padding-inline: 16px; padding-block: 20px; }}
.frame {{ position: relative; width: min(100%, calc((100vh - 140px) * 16 / 9), 1600px); margin-inline: auto; }}
canvas {{ display: block; width: 100%; max-width: 100%; aspect-ratio: 16 / 9; height: auto; background: var(--paper); border-radius: 2px; box-shadow: 0 1px 0 rgba(255,255,255,.04), 0 24px 70px rgba(0,0,0,.55); }}
#cover {{ position: absolute; inset: 0; display: grid; place-items: end start; padding: 0 0 6% 5% !important; background: transparent; border: 0; cursor: pointer; }}
#cover span {{ display: inline-flex; align-items: center; gap: 12px; background: var(--paper); color: var(--ink); font: 700 clamp(22px, 3.2vw, 40px)/1 var(--hand); padding: 10px 26px 12px; transform: rotate(-2deg); box-shadow: 3px 5px 0 rgba(0,0,0,.35); }}
#cover span::before {{ content: ""; width: 0; height: 0; border-left: .7em solid var(--accent); border-top: .42em solid transparent; border-bottom: .42em solid transparent; }}
#cover:focus-visible span, button:focus-visible {{ outline: 3px solid var(--accent); outline-offset: 3px; }}
#ui {{ width: min(100%, calc((100vh - 140px) * 16 / 9), 1600px); margin-inline: auto; display: flex; gap: 14px; align-items: center; }}
#ui button {{ font: 700 22px/1 var(--hand); background: var(--paper); color: var(--ink); border: 0; padding: 6px 16px 8px; cursor: pointer; transform: rotate(-1deg); min-width: 84px; }}
#ui input[type=range] {{ flex: 1; min-width: 0; accent-color: var(--accent); }}
#time {{ font-variant-numeric: tabular-nums; color: var(--muted); min-width: 4.5ch; text-align: right; }}
#loading {{ position: absolute; left: 16px; top: 12px; color: var(--ink); font: 22px var(--hand); }}
.credit {{ width: min(100%, calc((100vh - 140px) * 16 / 9), 1600px); margin-inline: auto; color: var(--muted); font-size: 15px; }}
</style>
<div class="wrap">
  <div class="frame">
    <canvas id="c" width="1920" height="1080"></canvas>
    <div id="loading">cutting out paper scraps&hellip;</div>
    <button id="cover" hidden aria-label="Play the film"><span>play with sound</span></button>
  </div>
  <div id="ui"><button id="play">Play</button><input id="seek" type="range" min="0" max="1000" value="0" aria-label="Scrub through the film"><span id="time">0.0s</span></div>
  <p class="credit">{CREDIT}</p>
</div>
<audio id="audio" preload="auto" src="data:audio/mp4;base64,{audio}"></audio>
<div id="stage" hidden></div>
{scripts}
"""
out = WEB / "dist"
out.mkdir(exist_ok=True)
slug = re.sub(r"[^a-z0-9]+", "-", TITLE.lower()).strip("-")
(out / f"{slug}.html").write_text(page)
print(out / f"{slug}.html", f"{len(page) / 1e6:.1f} MB")
