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
END = 57.0

random.seed(7)

NOTE = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def n(name):
    letter, rest = name[0], name[1:]
    acc = 0
    while rest and rest[0] in "b#":
        acc += -1 if rest[0] == "b" else 1
        rest = rest[1:]
    return 12 * (int(rest) + 1) + NOTE[letter] + acc


# channel: (program, bank, pan -1..1, volume 0..127)
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
}

events = []


def note(inst, t, dur, key, vel, human=True):
    if isinstance(key, str):
        key = n(key)
    if human:
        t += random.uniform(-0.007, 0.007)
        vel = int(np.clip(vel + random.randint(-5, 5), 1, 127))
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


DRUM = {
    "kick": 36,
    "shaker": 82,
    "tamb": 54,
    "wood_hi": 76,
    "wood_lo": 77,
    "tri": 81,
    "cabasa": 69,
}


def hit(t, name, vel):
    note("drums", t, 0.2, DRUM[name], vel)


# ---- part 1: 104 bpm, downbeat on "What" (1.6s), 9 bars to 22.37s
B1 = 60 / 104
T1 = 1.6


def t1(bar, beat=0.0):
    return T1 + (bar * 4 + beat) * B1


P1 = {
    "F": ("F2", "C3", ["A3", "C4", "F4"]),
    "Dm7": ("D2", "A2", ["F3", "A3", "C4"]),
    "Bb": ("Bb1", "F2", ["F3", "Bb3", "D4"]),
    "C7": ("C2", "G2", ["E3", "G3", "Bb3"]),
    "Gm7": ("G1", "D2", ["F3", "Bb3", "D4"]),
    "C": ("C2", "G2", ["E3", "G3", "C4"]),
    "Dm": ("D2", "A2", ["F3", "A3", "D4"]),
}
prog1 = [
    ["F"],
    ["Dm7"],
    ["Bb"],
    ["C7"],
    ["F"],
    ["Gm7", "C7"],
    ["Bb"],
    ["C"],
    ["Dm", "C"],
]

harp_intro = ["F3", "A3", "C4", "F4", "A4", "C5", "F5", "A5", "C6"]
for i, k in enumerate(harp_intro):
    note("harp", 0.55 + i * 0.075, 1.6, k, 52 + i * 3)
note("glock", 1.25, 1.2, "C6", 50)

for bar, chs in enumerate(prog1):
    half = len(chs) == 2
    for j, name in enumerate(chs):
        root, fifth, stab = P1[name]
        b0 = j * 2 if half else 0
        note("pizz", t1(bar, b0), 0.4, root, 86)
        if not half:
            note("pizz", t1(bar, 2), 0.4, fifth, 74)
        stab_beats = [b0 + 1] if half else [1, 3]
        for sb in stab_beats:
            chord("pizz", t1(bar, sb), 0.3, stab, 62)
        if bar in (2, 4, 6, 7) and not half:
            chord("pizz", t1(bar, 3.5), 0.25, stab, 48)
    if 2 <= bar <= 5:
        for e in range(8):
            hit(t1(bar, e * 0.5), "shaker", 34 if e % 2 else 44)
    if bar >= 6:
        for b in range(4):
            hit(
                t1(bar, b),
                "wood_hi" if b % 2 == 0 else "wood_lo",
                52 if b % 2 == 0 else 40,
            )

melA = {
    0: [
        ("C5", 0, 1),
        ("A4", 1, 0.5),
        ("C5", 1.5, 0.5),
        ("F5", 2, 1),
        ("E5", 3, 0.5),
        ("D5", 3.5, 0.5),
    ],
    1: [("C5", 0, 1.5), ("A4", 1.5, 0.5), ("D5", 2, 1), ("C5", 3, 1)],
    2: [
        ("Bb4", 0, 0.5),
        ("D5", 0.5, 0.5),
        ("F5", 1, 1),
        ("G5", 2, 0.5),
        ("F5", 2.5, 0.5),
        ("D5", 3, 1),
    ],
    3: [
        ("E5", 0, 0.5),
        ("G5", 0.5, 0.5),
        ("C6", 1, 1),
        ("Bb5", 2, 0.5),
        ("G5", 2.5, 0.5),
        ("E5", 3, 1),
    ],
    4: [
        ("C5", 0, 1),
        ("A4", 1, 0.5),
        ("C5", 1.5, 0.5),
        ("F5", 2, 1),
        ("A5", 3, 0.5),
        ("G5", 3.5, 0.5),
    ],
    5: [
        ("F5", 0, 0.5),
        ("D5", 0.5, 0.5),
        ("Bb4", 1, 1),
        ("E5", 2, 0.5),
        ("G5", 2.5, 0.5),
        ("C6", 3, 1),
    ],
}
for bar, notes in melA.items():
    for k, b, d in notes:
        note("glock", t1(bar, b), d * B1 * 0.9, n(k) + 12, 50)

bassoon = {
    6: ["Bb2", "D3", "F3", "D3", "Bb2", "D3", "F3", "A3"],
    7: ["C3", "E3", "G3", "E3", "C3", "E3", "G3", "Bb3"],
    8: ["D3", "F3", "A3", "F3", "C3", "E3", "G3", None],
}
for bar, ks in bassoon.items():
    for i, k in enumerate(ks):
        if k:
            note("bassoon", t1(bar, i * 0.5), 0.22, k, 78 if i % 2 == 0 else 66)
for i, k in enumerate(["F5", "G5", "A5", "C6"]):
    note("flute", t1(7, 2 + i * 0.25), 0.2, k, 58)
note("flute", t1(8, 0), 1.0, "D6", 56)

# sync points from the picture
for i, k in enumerate(["C6", "E6", "G6"]):
    note("glock", 8.85 + i * 0.06, 0.6, k, 70)
note("timp", 3.33, 1.5, "F2", 72)
note("glock", 3.33, 1.0, "C7", 58)
for t, k in zip([4.11, 4.69, 5.49, 6.01, 6.44], ["A5", "C6", "D6", "F6", "A6"]):
    note("glock", t, 0.5, k, 64)
note("celesta", 10.76, 1.0, "F6", 60)
note("timp", 12.64, 1.2, "F2", 84)
for i, k in enumerate(["C5", "E5", "G5", "Bb5", "C6"]):
    note("xylo", 14.62 + i * 0.05, 0.3, k, 70)
note("glock", 14.9, 0.8, "C7", 56)
for i, k in enumerate(["E6", "G6", "C7", "E7", "G7"]):
    note("glock", 18.12 + i * 0.045, 0.5, k, 60 - i * 3)
for i, k in enumerate(["C5", "E5", "G5"]):
    note("xylo", 19.72 + i * 0.07, 0.25, k, 62)
note("timp", 21.35, 1.6, "D2", 96)
note("pizz", 21.35, 0.4, "D2", 96)
note("bassoon", 21.55, 0.25, "A2", 72)
note("bassoon", 21.8, 0.5, "D2", 70)

# ---- part C: 22.37 .. 28.23, rubato pads
C0 = 22.37
pads = [
    (C0, 24.4, ["D3", "A3", "C4", "F4"], ["D2", "A2", "E3", "F3", "A3", "E4"]),
    (24.4, 26.4, ["Bb2", "F3", "A3", "D4"], ["Bb1", "F2", "D3", "A3", "D4", "F4"]),
    (26.4, 27.3, ["G2", "D3", "F3", "Bb3"], ["G1", "D2", "Bb2", "F3"]),
    (27.3, 28.02, ["C3", "G3", "Bb3", "D4", "F4"], ["C2", "G2", "D3", "F3"]),
]
cc("strings", C0 - 0.1, 11, 40)
ramp("strings", C0, 23.4, 40, 92)
for a, b, voicing, arp in pads:
    chord("strings", a, b - a + 0.05, voicing, 66)
    step = (b - a) / max(len(arp), 1)
    step = min(step, 0.36)
    for i, k in enumerate(arp):
        note("piano", a + i * step, 1.6, k, 46 - i * 2)
ramp("strings", 27.3, 28.0, 92, 110)
for t, k in [
    (22.95, "A4"),
    (23.7, "G4"),
    (24.45, "F4"),
    (25.2, "D4"),
    (25.95, "C4"),
    (26.6, "D4"),
    (27.33, "F4"),
    (27.78, "G4"),
]:
    note("piano", t, 0.9, k, 50)
note("celesta", 27.33, 1.5, "A5", 50)

# ---- part D: 104 bpm, downbeat on "make" (28.23), bar 9 lands on "yours" (49.02)
T2 = 28.23
B2 = (49.02 - T2) / 36


def t2(bar, beat=0.0):
    return T2 + (bar * 4 + beat) * B2


cc("strings", 28.2, 11, 70)
P2 = {
    "F": ("F2", ["F2", "C3", "A3", "C4", "F4"], ["A3", "C4", "F4"]),
    "Am7": ("A1", ["A2", "E3", "C4", "E4", "G4"], ["G3", "C4", "E4"]),
    "Bbmaj7": ("Bb1", ["Bb2", "F3", "D4", "F4", "A4"], ["A3", "D4", "F4"]),
    "C": ("C2", ["C3", "G3", "E4", "G4", "C5"], ["G3", "C4", "E4"]),
    "Dm7": ("D2", ["D3", "A3", "F4", "A4", "C5"], ["F3", "A3", "C4"]),
    "Gm7": ("G1", ["G2", "D3", "Bb3", "D4", "F4"], ["F3", "Bb3", "D4"]),
    "C7": ("C2", ["C3", "G3", "E4", "G4", "Bb4"], ["E3", "G3", "Bb3"]),
    "Bb": ("Bb1", ["Bb2", "F3", "D4", "F4", "Bb4"], ["F3", "Bb3", "D4"]),
}
prog2 = [
    ["F"],
    ["Am7"],
    ["Bbmaj7"],
    ["C"],
    ["F"],
    ["Dm7"],
    ["Gm7"],
    ["C7"],
    ["Bb", "C"],
]

chord("pizz", T2, 0.5, ["F2", "A3", "C4", "F4"], 78)
chord("stab", T2, 0.7, ["F3", "A3", "C4", "F4"], 60)
note("timp", T2, 1.5, "F2", 66)
for k in ["F6", "A6", "C7"]:
    note("glock", T2, 1.5, k, 72)
for i, k in enumerate(["F4", "A4", "C5", "F5", "A5", "C6", "F6"]):
    note("harp", T2 + 0.1 + i * 0.05, 1.5, k, 60 + i * 3)

guitar_pat = [0, 1, 2, 1, 3, 1, 2, 4]
for bar, chs in enumerate(prog2):
    half = len(chs) == 2
    for j, name in enumerate(chs):
        root, arp, pad = P2[name]
        b0 = j * 2 if half else 0
        span = 2 if half else 4
        for e in range(span * 2):
            beat = b0 + e * 0.5
            if bar == 0 and beat < 1.5:
                continue
            idx = guitar_pat[e % 8]
            note("guitar", t2(bar, beat), B2 * 1.2, arp[idx], 60 if e % 2 == 0 else 50)
        if bar >= 1:
            note("bass", t2(bar, b0), B2 * 1.7, root, 84)
            if not half:
                note("bass", t2(bar, 2), B2 * 1.7, n(root) + 7, 72)
        if bar >= 4:
            chord("strings", t2(bar, b0), span * B2 + 0.05, pad, 58 + (bar - 4) * 4)
    if bar >= 2:
        for e in range(8):
            hit(
                t2(bar, e * 0.5),
                "shaker",
                30 + (bar >= 5) * 8 if e % 2 else 40 + (bar >= 5) * 8,
            )
    if bar >= 5:
        hit(t2(bar, 1), "tamb", 40)
        hit(t2(bar, 3), "tamb", 44)
        hit(t2(bar, 0), "kick", 52)
        hit(t2(bar, 2.5), "kick", 40)
ramp("strings", t2(4), t2(8, 4), 70, 112)

melD = {
    1: [("E5", 0, 1), ("C5", 1, 0.5), ("D5", 1.5, 0.5), ("E5", 2, 1), ("G5", 3, 1)],
    2: [("F5", 0, 1.5), ("D5", 1.5, 0.5), ("A4", 2, 2)],
    3: [("G4", 0, 0.5), ("A4", 0.5, 0.5), ("C5", 1, 1), ("E5", 2, 1), ("D5", 3, 1)],
    4: [("C5", 0, 1), ("A4", 1, 0.5), ("C5", 1.5, 0.5), ("F5", 2, 2)],
    5: [("F5", 0, 0.5), ("E5", 0.5, 0.5), ("D5", 1, 1), ("A5", 2, 1), ("G5", 3, 1)],
    6: [("F5", 0, 1.5), ("D5", 1.5, 0.5), ("Bb4", 2, 2)],
    7: [("C5", 0, 0.5), ("D5", 0.5, 0.5), ("E5", 1, 1), ("G5", 2, 1), ("Bb5", 3, 1)],
    8: [("A5", 0, 2), ("G5", 2, 1), ("E5", 3, 1)],
}
for bar, notes in melD.items():
    for k, b, d in notes:
        note("celesta", t2(bar, b), d * B2 * 0.95, k, 66)
        if bar >= 5:
            note("flute", t2(bar, b), d * B2 * 0.9, n(k) - 12, 52 + (bar - 5) * 4)

# picture sync in part D
for t, k in [(32.86, "C7"), (34.61, "E6"), (35.54, "G6"), (38.2, "A6")]:
    note("glock", t, 0.8, k, 50)
for i, k in enumerate(["C6", "D6", "E6", "G6", "A6", "C7"]):
    note("glock", 44.05 + i * 0.09, 0.6, k, 48)
note("xylo", 46.45, 0.3, "C6", 60)
note("xylo", 46.58, 0.3, "F6", 60)

# ---- "yours" resolution and outro
TY = 49.02
note("timp", TY, 2.5, "F2", 56)
note("bass", TY, 3.0, "F1", 86)
chord("strings", TY, 3.6, ["F2", "C3", "A3", "C4", "F4", "A4"], 70)
chord("guitar", TY, 3.0, ["F2", "C3", "F3", "A3", "C4", "F4"], 62, spread=0.03)
for i, k in enumerate(["F3", "A3", "C4", "F4", "A4", "C5", "F5", "A5", "C6", "F6"]):
    note("harp", TY + i * 0.06, 2.5, k, 58 + i * 2)
note("celesta", TY, 2.5, "F5", 70)
note("glock", TY, 2.0, "A6", 52)
ramp("strings", TY + 0.5, 52.4, 112, 50)

OB = 0.42
mbox = [
    ("C6", 1),
    ("A5", 0.5),
    ("C6", 0.5),
    ("F6", 1),
    ("E6", 0.5),
    ("D6", 0.5),
    ("C6", 2),
    ("A5", 1),
    ("Bb5", 0.5),
    ("G5", 0.5),
    ("F5", 3),
]
t = 50.75
for k, d in mbox:
    note("mbox", t, d * OB * 1.6, k, 74)
    t += d * OB
cc("strings", 50.4, 11, 48)
chord("strings", 50.6, 2.2, ["F3", "A3", "C4"], 52)
chord("strings", 52.8, 1.5, ["Bb2", "F3", "A3", "D4"], 50)
chord("strings", 54.25, 2.4, ["F2", "C3", "A3", "C4"], 52)
ramp("strings", 54.6, 56.6, 48, 0)
for i, k in enumerate(["F3", "C4", "F4", "A4", "C5", "F5"]):
    note("harp", 54.25 + i * 0.08, 2.0, k, 50)
note("pizz", 55.35, 0.5, "F3", 70)
note("celesta", 55.35, 1.5, "F6", 52)


def render():
    fs = fluidsynth.Synth(gain=0.45, samplerate=float(SR))
    sfid = fs.sfload(str(SF2))
    for name, (ch, prog, bank, pan, vol) in CH.items():
        fs.program_select(ch, sfid, bank, prog)
        fs.cc(ch, 7, vol)
        fs.cc(ch, 10, int(64 + pan * 63))
        fs.cc(ch, 91, 0)
        fs.cc(ch, 93, 0)
        fs.cc(ch, 11, 127)
    evs = sorted(events, key=lambda e: (e[0], e[1]))
    out = []
    cur = 0
    for t, kind, ch, a, b in evs:
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
    total = int(END * SR)
    if total > cur:
        out.append(fs.get_samples(total - cur))
    fs.delete()
    pcm = np.concatenate(out).astype(np.float32) / 32768.0
    return pcm.reshape(-1, 2)[:total]


def main():
    dry = render()
    board = Pedalboard(
        [
            HighpassFilter(cutoff_frequency_hz=35),
            Reverb(
                room_size=0.55, damping=0.55, wet_level=0.2, dry_level=0.85, width=1.0
            ),
        ]
    )
    wet = board(dry.T.copy(), SR).T
    peak = np.abs(wet).max()
    wet = wet / peak * 0.7
    sf.write(ROOT / "audio/music.wav", wet, SR, subtype="PCM_24")
    (ROOT / "audio/music_sections.json").write_text(
        json.dumps({"T1": T1, "B1": B1, "T2": T2, "B2": B2})
    )
    print(
        f"music {len(wet) / SR:.2f}s peak_before_norm {peak:.3f} events {len(events)}"
    )


if __name__ == "__main__":
    main()
