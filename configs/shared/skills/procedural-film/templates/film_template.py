import math
import subprocess
import wave

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

W, H, FPS = 1280, 720, 30
SR = 44100
BG = (6, 7, 10)
AMBER = (255, 196, 130)
CYAN = (140, 190, 255)
INK = (225, 228, 235)

SANS = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 30)
MONO = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 28)

SCENES = [
    (0.0, 8.0, "scene_one", "a cursor, waiting"),
    (8.0, 16.0, "scene_two", "a constellation breathing"),
    (16.0, 24.0, "scene_three", "and a goodbye"),
]
DURATION = SCENES[-1][1]


def smooth(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def fade(t, t0, t1, edge=0.8):
    if t < t0 or t > t1:
        return 0.0
    return smooth((t - t0) / edge) * smooth((t1 - t) / edge)


def scale_color(color, a):
    return tuple(int(c * max(0.0, min(1.0, a))) for c in color)


def caption(overlay, text, alpha, y=H - 96, font=SANS, color=INK):
    if alpha <= 0.01:
        return
    d = ImageDraw.Draw(overlay)
    w = d.textlength(text, font=font)
    d.text(((W - w) / 2, y), text, font=font, fill=color + (int(255 * alpha),))


NODE_RNG = np.random.default_rng(7)
NODES = [
    (
        NODE_RNG.uniform(160, W - 160),
        NODE_RNG.uniform(90, H - 220),
        NODE_RNG.uniform(0.4, 1.4),
        NODE_RNG.uniform(0, math.tau),
    )
    for _ in range(30)
]
EDGES = [
    (i, j)
    for i in range(len(NODES))
    for j in range(i + 1, len(NODES))
    if math.dist(NODES[i][:2], NODES[j][:2]) < 240
]


def scene_one(d, overlay, t):
    a = fade(t, 0.5, 8.5, 1.0)
    if int(t * 2) % 2 == 0:
        d.rectangle(
            [W / 2 - 8, H / 2 - 15, W / 2 + 7, H / 2 + 15],
            fill=scale_color(AMBER, 0.9 * a),
        )
    caption(overlay, SCENES[0][3], fade(t, 2.0, 7.5))


def scene_two(d, overlay, t):
    lt = t - SCENES[1][0]
    vis = fade(t, SCENES[1][0], SCENES[1][1] + 0.5, 1.2)
    for i, j in EDGES:
        x1, y1, w1, p1 = NODES[i]
        x2, y2, w2, p2 = NODES[j]
        pulse = 0.5 + 0.5 * math.sin(lt * w1 + p1) * math.sin(lt * w2 + p2)
        d.line([x1, y1, x2, y2], fill=scale_color(CYAN, 0.3 * pulse * vis))
    for x, y, w, p in NODES:
        pulse = 0.55 + 0.45 * math.sin(lt * w + p)
        r = 2.5 + 1.5 * pulse
        d.ellipse([x - r, y - r, x + r, y + r], fill=scale_color(INK, pulse * vis))
    caption(overlay, SCENES[1][3], fade(t, 9.5, 15.0))


def scene_three(d, overlay, t):
    lt = t - SCENES[2][0]
    vis = fade(t, SCENES[2][0], SCENES[2][1], 1.2)
    text = "every film ends. make the ending count."
    n = min(len(text), int(lt * 14))
    tw = MONO.getlength(text)
    d.text(
        ((W - tw) / 2, H / 2 - 14),
        text[:n],
        font=MONO,
        fill=scale_color(AMBER, 0.9 * vis),
    )
    caption(overlay, SCENES[2][3], fade(t, 19.0, 23.0))


def render_frame(t):
    art = Image.new("RGB", (W, H), (0, 0, 0))
    overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(art)
    for t0, t1, name, _ in SCENES:
        if t0 - 1.0 <= t <= t1 + 1.0:
            globals()[name](d, overlay, t)
    glow = art.filter(ImageFilter.GaussianBlur(7))
    frame = ImageChops.add(Image.new("RGB", (W, H), BG), ImageChops.add(glow, art))
    frame = frame.convert("RGBA")
    frame.alpha_composite(overlay)
    a = min(1.0, t / 1.5) * min(1.0, max(0.0, (DURATION - t) / 2.5))
    frame = frame.convert("RGB")
    if a < 1.0:
        frame = Image.blend(Image.new("RGB", (W, H), (0, 0, 0)), frame, a)
    return frame


def build_score(path):
    rng = np.random.default_rng(7)
    n = int(SR * DURATION)
    ts = np.arange(n) / SR
    mix = np.zeros((n, 2))
    for freq, amp in [(110.0, 0.03), (164.81, 0.016), (220.0, 0.012)]:
        lfo = 0.7 + 0.3 * np.sin(2 * np.pi * 0.05 * ts + freq)
        mix[:, 0] += amp * lfo * np.sin(2 * np.pi * freq * ts)
        mix[:, 1] += amp * lfo * np.sin(2 * np.pi * freq * 1.0015 * ts)
    t_event = 3.0
    scale = [440.0, 493.88, 554.37, 659.25, 880.0]
    while t_event < DURATION - 4:
        f = float(rng.choice(scale))
        i0 = int(t_event * SR)
        seg = min(n - i0, int(3.0 * SR))
        tt = np.arange(seg) / SR
        bell = np.sin(2 * np.pi * f * tt) + 0.35 * np.sin(2 * np.pi * 2 * f * tt)
        bell *= 0.05 * np.exp(-tt * 1.6)
        pan = rng.uniform(0.3, 0.7)
        mix[i0 : i0 + seg, 0] += bell * (1 - pan)
        mix[i0 : i0 + seg, 1] += bell * pan
        t_event += rng.uniform(2.5, 5.0)
    noise = rng.standard_normal(n)
    kernel = np.hanning(600)
    mix += 0.04 * np.convolve(noise, kernel / kernel.sum(), mode="same")[:, None]
    env = np.clip(ts / 3.0, 0, 1) * np.clip((DURATION - ts) / 4.0, 0, 1)
    mix *= env[:, None]
    pcm = (mix / np.abs(mix).max() * 0.85 * 32767).astype(np.int16)
    with wave.open(path, "wb") as f:
        f.setnchannels(2)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes(pcm.tobytes())


def main():
    build_score("score.wav")
    cmd = [
        "ffmpeg",
        "-y",
        "-f",
        "rawvideo",
        "-pix_fmt",
        "rgb24",
        "-s",
        f"{W}x{H}",
        "-r",
        str(FPS),
        "-i",
        "-",
        "-i",
        "score.wav",
        "-c:v",
        "libx264",
        "-preset",
        "medium",
        "-crf",
        "18",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-b:a",
        "192k",
        "-shortest",
        "film.mp4",
    ]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.DEVNULL)
    total = int(DURATION * FPS)
    for i in range(total):
        proc.stdin.write(render_frame(i / FPS).tobytes())
        if i % 300 == 0:
            print(f"frame {i}/{total}", flush=True)
    proc.stdin.close()
    proc.wait()
    print("done: film.mp4")


if __name__ == "__main__":
    main()
