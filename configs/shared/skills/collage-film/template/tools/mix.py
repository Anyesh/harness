import json
import random
from pathlib import Path

import numpy as np
import soundfile as sf
from pedalboard import (
    Compressor,
    HighpassFilter,
    Limiter,
    LowShelfFilter,
    Pedalboard,
    PeakFilter,
    Reverb,
)
from scipy.signal import butter, resample_poly, sosfilt

ROOT = Path(__file__).resolve().parent.parent
SR = 48000
DUR = float(json.loads((ROOT / "audio/film.json").read_text())["duration"])
N = int(DUR * SR)
rnd = random.Random(11)

SFX_FILES = {
    "tap": ["paper_tap_1", "paper_tap_2", "paper_tap_3"],
    "snip": ["scissors_snip_2", "scissors_snip_4"],
    "whoosh": ["whoosh_4", "whoosh_5"],
    "pop": ["pop_1", "pop_5", "pop_3"],
    "slide": ["paper_slide_1", "paper_slide_2"],
    "thump": ["book_thump_3", "book_thump_4"],
    "rustle": ["paper_rustle_1", "paper_rustle_2", "paper_rustle_3"],
    "tear": ["paper_tear_1", "paper_tear_4", "paper_tear_2"],
    "tape": ["tape_2", "tape_1"],
    "pencil": ["pencil_scribble_2", "pencil_scribble_1"],
    "bell": ["bell_ding_1"],
    "crayon": ["crayon_scribble_2"],
    "flip": ["page_flip_3", "page_flip_4"],
    "laugh": ["kid_laugh_1"],
    "bark": ["dog_bark_2"],
}
# Category trims: per-clip max length (s) and base level in dB relative to the -14 dBFS loudness anchor.
CAT = {
    "tap": (0.25, -9),
    "snip": (0.35, -6),
    "whoosh": (0.8, -12),
    "pop": (0.5, -8),
    "slide": (0.9, -8),
    "thump": (0.4, -4),
    "rustle": (0.9, -8),
    "tear": (1.0, -6),
    "tape": (0.8, -10),
    "pencil": (1.2, -9),
    "bell": (1.8, -8),
    "crayon": (1.0, -10),
    "flip": (0.9, -8),
    "laugh": (1.6, -14),
    "bark": (0.6, -12),
}


def load(path):
    a, sr = sf.read(path, dtype="float32", always_2d=True)
    if sr != SR:
        a = resample_poly(a, SR, sr, axis=0).astype(np.float32)
    if a.shape[1] == 1:
        a = np.repeat(a, 2, axis=1)
    return a


def loud50(a):
    m = a.mean(1)
    w = int(0.05 * SR)
    fr = [
        np.sqrt((m[i : i + w] ** 2).mean())
        for i in range(0, max(1, len(m) - w), w // 2)
    ]
    return max(fr) + 1e-9


def prep(name, maxlen):
    a = load(ROOT / f"assets/sfx/{name}.wav")
    env = np.abs(a).max(1)
    on = int(np.argmax(env > env.max() * 0.12))
    a = a[max(0, on - int(0.004 * SR)) :]
    a = a[: int(maxlen * SR)]
    fade = min(len(a), int(0.06 * SR))
    a[-fade:] *= np.linspace(1, 0, fade)[:, None]
    a *= 10 ** (-14 / 20) / loud50(a)
    return a


def pitch(a, ratio):
    up = int(round(1000 * ratio))
    return resample_poly(a, 1000, up, axis=0).astype(np.float32)


def thud(length=0.35):
    t = np.arange(int(length * SR)) / SR
    f = 95 * np.exp(-t * 6) + 48
    ph = 2 * np.pi * np.cumsum(f) / SR
    s = np.sin(ph) * np.exp(-t * 14) * 0.5
    return np.stack([s, s], 1).astype(np.float32)


def soft_whoosh(length, pan_from, pan_to):
    n = int(length * SR)
    noise = np.array([rnd.gauss(0, 1) for _ in range(n)], dtype=np.float32)
    t = np.linspace(0, 1, n)
    out = np.zeros(n, dtype=np.float32)
    for lo, hi, peak in [(250, 700, 0.35), (700, 1800, 0.5), (1800, 5000, 0.62)]:
        sos = butter(2, [lo, hi], btype="band", fs=SR, output="sos")
        band = sosfilt(sos, noise)
        env = np.exp(-((t - peak) ** 2) / (2 * 0.16**2))
        out += band * env
    out *= 10 ** (-14 / 20) / (np.sqrt((out**2).mean()) * 2.2)
    pan = np.linspace(pan_from, pan_to, n)
    return np.stack([out * np.sqrt((1 - pan) / 2), out * np.sqrt((1 + pan) / 2)], 1)


def place(bus, clip, t, gain_db, pan=0.0):
    i = int(t * SR)
    if i >= N or i < 0:
        return
    c = clip[: N - i] * 10 ** (gain_db / 20)
    if pan:
        lg = np.sqrt((1 - pan) / 2) * np.sqrt(2)
        rg = np.sqrt((1 + pan) / 2) * np.sqrt(2)
        c = c * np.array([lg, rg], dtype=np.float32)
    bus[i : i + len(c)] += c


def build_sfx():
    cues = json.loads((ROOT / "audio/sfx_cues.json").read_text())
    pools = {k: [prep(f, CAT[k][0]) for f in fs] for k, fs in SFX_FILES.items()}
    bus = np.zeros((N, 2), dtype=np.float32)
    counters = {k: 0 for k in pools}
    for c in cues:
        k = c["name"]
        maxlen, base = CAT[k]
        clip = pools[k][counters[k] % len(pools[k])]
        counters[k] += 1
        g = base - 5 + 20 * np.log10(max(c["gain"], 1e-3)) + rnd.uniform(-1.5, 1.5)
        pan = float(np.clip(c["pan"], -0.8, 0.8))
        if k in ("tap", "snip", "pop"):
            clip = pitch(clip, rnd.uniform(0.92, 1.08))
        if k == "whoosh":
            place(
                bus,
                soft_whoosh(0.45, -0.6 * np.sign(pan or 1), 0.6 * np.sign(pan or 1)),
                c["t"] - 0.1,
                g + 2,
                0,
            )
            g -= 8
        if k == "thump":
            place(bus, thud(), c["t"], g + 1, 0)
        place(bus, clip, c["t"], g, pan)
    room = Pedalboard(
        [Reverb(room_size=0.25, damping=0.6, wet_level=0.12, dry_level=0.95, width=0.8)]
    )
    return room(bus.T.copy(), SR).T


def build_vo():
    a, sr = sf.read(ROOT / "audio/vo_raw.wav", dtype="float32")
    a = resample_poly(a, SR, sr).astype(np.float32)
    chain = Pedalboard(
        [
            HighpassFilter(cutoff_frequency_hz=75),
            LowShelfFilter(cutoff_frequency_hz=220, gain_db=1.5),
            PeakFilter(cutoff_frequency_hz=3200, gain_db=2.0, q=0.8),
            PeakFilter(cutoff_frequency_hz=7000, gain_db=-1.5, q=1.0),
            Compressor(threshold_db=-20, ratio=2.5, attack_ms=6, release_ms=90),
            Reverb(
                room_size=0.12, damping=0.7, wet_level=0.045, dry_level=1.0, width=0.3
            ),
            Limiter(threshold_db=-4.0, release_ms=60),
        ]
    )
    out = chain(a[None, :], SR)[0]
    out = out[:N] if len(out) >= N else np.pad(out, (0, N - len(out)))
    rms = np.sqrt((out[np.abs(out) > 1e-3] ** 2).mean())
    out *= 10 ** (-19 / 20) / rms
    return np.stack([out, out], 1)


def duck_env(vo, depth_db=8.0):
    m = np.abs(vo[:, 0])
    w = int(0.03 * SR)
    rms = np.sqrt(np.convolve(m**2, np.ones(w) / w, mode="same"))
    db = 20 * np.log10(rms + 1e-6)
    target = np.clip((db + 48) / 18, 0, 1)
    env = np.zeros_like(target)
    att = np.exp(-1 / (0.025 * SR))
    rel = np.exp(-1 / (0.45 * SR))
    e = 0.0
    for i, x in enumerate(target):
        c = att if x > e else rel
        e = c * e + (1 - c) * x
        env[i] = e
    return 10 ** (-depth_db * env / 20)


def main():
    vo = build_vo()
    music, sr = sf.read(ROOT / "audio/music.wav", dtype="float32", always_2d=True)
    music = music[:N]
    music *= 10 ** (-2.0 / 20)
    t = np.arange(len(music)) / SR
    vo_lines = json.loads((ROOT / "audio/vo_timeline.json").read_text())["lines"]
    first, last = vo_lines[0]["start"], vo_lines[-1]["end"]
    lift_db = 3.0 * np.clip(1 - (t - (first - 0.4)) / 0.6, 0, 1) + 4.0 * np.clip((t - last) / 1.0, 0, 1)
    music *= (10 ** (lift_db / 20))[:, None]
    music *= duck_env(vo)[:, None]
    sfx = build_sfx()
    mix = vo + music + sfx
    master = Pedalboard(
        [
            Compressor(threshold_db=-14, ratio=1.8, attack_ms=12, release_ms=160),
            Limiter(threshold_db=-2.0, release_ms=80),
        ]
    )
    out = master(mix.T.copy(), SR).T
    fade = int(0.6 * SR)
    out[-fade:] *= np.linspace(1, 0, fade)[:, None]
    for name, x in [
        ("stem_vo", vo),
        ("stem_music", music),
        ("stem_sfx", sfx),
        ("mix_pre", out),
    ]:
        sf.write(ROOT / f"audio/{name}.wav", x, SR, subtype="PCM_24")
    print(
        "peaks",
        {
            k: round(float(20 * np.log10(np.abs(v).max() + 1e-9)), 1)
            for k, v in [("vo", vo), ("music", music), ("sfx", sfx), ("mix", out)]
        },
    )


if __name__ == "__main__":
    main()
