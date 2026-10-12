import functools
import json
import random
from pathlib import Path

import fluidsynth
import numpy as np
import soundfile as sf
from pedalboard import HighpassFilter, Pedalboard, Reverb

ROOT = Path(__file__).resolve().parent.parent
SR = 48000
SF2 = ROOT / "assets/sf/GeneralUser-GS.sf2"
NOTE = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
DRUM = {
    "kick": 36,
    "snare": 38,
    "clap": 39,
    "shaker": 82,
    "tamb": 54,
    "wood_hi": 76,
    "wood_lo": 77,
    "tri": 81,
    "cabasa": 69,
    "hat": 42,
}

# name: (channel, GM program, bank, pan -1..1, volume 0..127); channel 9 is the GM drum kit
CH = {
    "pizz": (0, 45, 0, -0.2, 100),
    "glock": (1, 9, 0, 0.3, 100),
    "bassoon": (2, 70, 0, -0.1, 92),
    "piano": (3, 0, 0, 0.0, 96),
    "strings": (4, 49, 0, 0.0, 88),
    "guitar": (5, 24, 0, -0.35, 96),
    "bass": (6, 32, 0, 0.0, 100),
    "celesta": (7, 8, 0, 0.22, 100),
    "flute": (8, 73, 0, 0.15, 78),
    "drums": (9, 0, 128, 0.0, 90),
    "harp": (10, 46, 0, 0.35, 96),
    "timp": (11, 47, 0, 0.0, 100),
    "xylo": (12, 13, 0, 0.2, 82),
    "mbox": (13, 10, 0, 0.0, 100),
    "stab": (14, 48, 0, 0.0, 90),
    "uke": (15, 24, 8, 0.3, 92),
}

events = []
_rnd = random.Random(7)


def n(name):
    if isinstance(name, int):
        return name
    letter, rest = name[0], name[1:]
    acc = 0
    while rest and rest[0] in "b#":
        acc += -1 if rest[0] == "b" else 1
        rest = rest[1:]
    return 12 * (int(rest) + 1) + NOTE[letter] + acc


def film_duration():
    return float(json.loads((ROOT / "audio/film.json").read_text())["duration"])


@functools.cache
def _vo_lines():
    return {
        l["id"]: l
        for l in json.loads((ROOT / "audio/vo_timeline.json").read_text())["lines"]
    }


# Invariant: matches exactly like wd() in stage.js, so music and picture cue off the same word time.
def word(line, w, nth=0):
    words = [x for x in _vo_lines()[line]["words"] if any(c.isalpha() for c in x["w"])]
    if isinstance(w, int):
        return words[w]["s"]
    hits = [x["s"] for x in words if x["w"].lower() == w]
    if len(hits) <= nth:
        raise KeyError(f"word {w!r} (#{nth}) not in line {line!r}")
    return hits[nth]


def note(inst, t, dur, key, vel, human=True):
    key = n(key)
    if human:
        t += _rnd.uniform(-0.007, 0.007)
        vel = int(np.clip(vel + _rnd.randint(-5, 5), 1, 127))
    ch = CH[inst][0]
    events.append((max(0.0, t), 1, ch, key, vel))
    events.append((max(0.0, t + dur), 0, ch, key, 0))


def chord(inst, t, dur, keys, vel, spread=0.0):
    for i, k in enumerate(keys):
        note(inst, t + i * spread, dur, k, vel)


def cc(inst, t, ctrl, val):
    events.append((t, 2, CH[inst][0], ctrl, int(val)))


def ramp(inst, t0, t1, v0, v1, ctrl=11, steps=24):
    for i in range(steps + 1):
        cc(inst, t0 + (t1 - t0) * i / steps, ctrl, v0 + (v1 - v0) * i / steps)


def hit(t, name, vel):
    note("drums", t, 0.2, DRUM[name], vel)


class Grid:
    """Bar/beat clock for one tempo section; pick start and bar count so downbeats land on chosen words."""

    def __init__(self, start, end=None, bars=None, bpm=None):
        self.start = start
        self.beat = (end - start) / (bars * 4) if bpm is None else 60 / bpm

    def __call__(self, bar, beat=0.0):
        return self.start + (bar * 4 + beat) * self.beat


def render(end):
    fs = fluidsynth.Synth(gain=0.45, samplerate=float(SR))
    sfid = fs.sfload(str(SF2))
    for ch, prog, bank, pan, vol in CH.values():
        fs.program_select(ch, sfid, bank, prog)
        fs.cc(ch, 7, vol)
        fs.cc(ch, 10, int(64 + pan * 63))
        fs.cc(ch, 91, 0)
        fs.cc(ch, 93, 0)
        fs.cc(ch, 11, 127)
    out = []
    cur = 0
    for t, kind, ch, a, b in sorted(events, key=lambda e: (e[0], e[1])):
        target = int(t * SR)
        if target > cur:
            out.append(fs.get_samples(target - cur))
            cur = target
        if kind == 1:
            fs.noteon(ch, a, b)
        elif kind == 0:
            fs.noteoff(ch, a)
        else:
            fs.cc(ch, a, b)
    total = int(end * SR)
    if total > cur:
        out.append(fs.get_samples(total - cur))
    fs.delete()
    pcm = np.concatenate(out).astype(np.float32) / 32768.0
    return pcm.reshape(-1, 2)[:total]


def write(end):
    dry = render(end)
    board = Pedalboard(
        [
            HighpassFilter(cutoff_frequency_hz=35),
            Reverb(
                room_size=0.55, damping=0.55, wet_level=0.2, dry_level=0.85, width=1.0
            ),
        ]
    )
    wet = board(dry.T.copy(), SR).T
    wet = wet / np.abs(wet).max() * 0.7
    sf.write(ROOT / "audio/music.wav", wet, SR, subtype="PCM_24")
    print(f"music {len(wet) / SR:.2f}s events {len(events)}")


def stem_report(end):
    """Per-channel RMS so silent or missing presets show up without listening."""
    base = list(events)
    for name, (ch, *_r) in CH.items():
        events[:] = [e for e in base if e[2] == ch or e[1] == 2]
        notes = sum(1 for e in events if e[1] == 1)
        if notes:
            a = render(end)
            print(
                f"{name:8s} {20 * np.log10(np.sqrt((a**2).mean()) + 1e-9):6.1f} dBFS notes {notes}"
            )
    events[:] = base
