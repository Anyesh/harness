import sys

from score import (
    Grid,
    chord,
    cc,
    film_duration,
    hit,
    note,
    ramp,
    stem_report,
    word,
    write,
)

END = film_duration()
MEET = word("meet", "meet")
FINAL = word("end", "wardrobe")
bar = Grid(start=MEET, end=FINAL, bars=17)

UKE = {
    "C": ["C4", "E4", "G4", "C5"],
    "Am": ["C4", "E4", "A4", "A4"],
    "F": ["C4", "F4", "A4", "A4"],
    "G": ["D4", "G4", "B4", "G4"],
    "Dm": ["D4", "F4", "A4", "A4"],
}
ROOT = {"C": "C3", "Am": "A2", "F": "F2", "G": "G2", "Dm": "D3"}
FIFTH = {"C": "G2", "Am": "E3", "F": "C3", "G": "D3", "Dm": "A2"}
TUNE = {
    "C": [(0, "E5"), (0.5, "G5"), (1.5, "A5"), (2.5, "G5")],
    "Am": [(0, "E5"), (1, "D5"), (2, "C5"), (3, "E5")],
    "F": [(0, "F5"), (0.5, "A5"), (1.5, "C6"), (2.5, "A5")],
    "G": [(0, "D5"), (1, "G5"), (2, "B5"), (3, "D6")],
    "Dm": [(0, "F5"), (1, "D5"), (2, "A4"), (3, "D5")],
}
# One entry per bar: (chords as (beat, name) pairs, feel). Feels: full, light (no claps), rain, lonely.
PLAN = [
    ([(0, "C")], "light"),
    ([(0, "Am")], "full"),
    ([(0, "F")], "full"),
    ([(0, "G")], "full"),
    ([(0, "C")], "full"),
    ([(0, "Am")], "light"),
    ([(0, "Dm")], "rain"),
    ([(0, "G")], "full"),
    ([(0, "C")], "full"),
    ([(0, "Am")], "full"),
    ([(0, "F")], "full"),
    ([(0, "G")], "full"),
    ([(0, "Am")], "lonely"),
    ([(0, "Dm"), (2, "G")], "full"),
    ([(0, "C")], "full"),
    ([(0, "Am")], "full"),
    ([(0, "F"), (2, "G")], "full"),
]
MELODY = {"glock": {0, 1, 4, 5, 8, 9, 14, 15}, "xylo": {2, 3, 10, 11}}
STRUM = [(0, 74), (1, 70), (1.5, 52), (2.5, 54), (3, 68), (3.5, 50)]


def chord_at(chords, beat):
    return [name for b, name in chords if b <= beat][-1]


def intro():
    for i, k in enumerate(["G5", "E5", "C5", "E5", "G5", "A5", "G5", "E5"]):
        note("mbox", 0.5 + i * 0.36, 0.5, k, 58)
    for i, t in enumerate([3.3, 3.55, 3.8, 4.05, 4.28]):
        hit(t, "wood_hi" if i % 2 else "wood_lo", 70 + i * 8)
    note("timp", 4.49, 0.8, "C2", 112)
    chord("stab", 4.49, 0.25, ["C3", "G3", "C4", "Eb4"], 100)
    for i, k in enumerate(
        [
            "C7",
            "A6",
            "G6",
            "E6",
            "D6",
            "C6",
            "A5",
            "G5",
            "E5",
            "D5",
            "C5",
            "A4",
            "G4",
            "E4",
            "D4",
            "C4",
        ]
    ):
        note("xylo", 4.57 + i * 0.09, 0.15, k, 78)
    note("timp", 6.05, 0.6, "G1", 96)
    for i, k in enumerate(["E3", "Eb3", "D3", "Db3"]):
        note("bassoon", 6.55 + i * 0.3, 0.27 if i < 3 else 0.7, k, 84)


def groove():
    for b, (chords, feel) in enumerate(PLAN):
        for beat, vel in STRUM:
            name = chord_at(chords, beat)
            if feel == "rain" or (feel == "lonely" and beat > 0):
                continue
            chord(
                "uke",
                bar(b, beat),
                0.42,
                UKE[name],
                vel - (16 if feel == "lonely" else 0),
                spread=0.012 if vel > 60 else -0.01,
            )
        for beat in (0, 2):
            name = chord_at(chords, beat)
            note("pizz", bar(b, beat), 0.4, ROOT[name], 88)
            if feel != "lonely":
                note("pizz", bar(b, beat + 1.5), 0.25, FIFTH[name], 66)
        if feel == "full":
            for beat in (1, 3):
                hit(bar(b, beat), "clap", 72)
        if feel in ("full", "light"):
            for e in range(8):
                hit(bar(b, e * 0.5), "shaker", 46 if e % 2 else 36)
        for inst, bars in MELODY.items():
            if b in bars:
                for beat, k in TUNE[chord_at(chords, 0)]:
                    note(inst, bar(b, beat), 0.4, k, 64 if inst == "glock" else 72)
        if feel == "rain":
            for i, k in enumerate(["A6", "F6", "D6", "A5", "F6", "D6", "A6", "C6"]):
                note("celesta", bar(b, i * 0.5), 0.3, k, 52)
        if feel == "lonely":
            for beat, k in [(0, "A4"), (1, "C5"), (2, "E5"), (3, "D5")]:
                note("celesta", bar(b, beat), 0.6, k, 56)


def accents():
    note("glock", word("snap", "snap"), 0.5, "C7", 82)
    for t, k in [
        (word("outfit", "top"), "C6"),
        (word("outfit", "to"), "E6"),
        (word("outfit", "toe"), "G6"),
    ]:
        note("glock", t, 0.4, k, 84)
    note("glock", word("skip", "wear"), 0.5, "G6", 74)
    skip = word("skip", "skip")
    note("bassoon", skip, 0.35, "G2", 96)
    note("bassoon", skip + 0.21, 0.45, "C2", 90)
    for i in range(8):
        note("bassoon", bar(10, i * 0.5), 0.2, "C3" if i % 2 else "G2", 58)
    note("timp", word("forgot", "forgot"), 0.5, "G2", 84)
    match = word("pair", "match")
    for i, k in enumerate(["C5", "E5", "G5", "C6", "E6", "G6", "C7"]):
        note("harp", match - 0.27 + i * 0.04, 0.8, k, 76)
    note("glock", match, 0.7, "E6", 86)
    note("timp", word("self", "yourself") + 0.7, 0.5, "C2", 92)
    note("glock", word("self", "open"), 0.6, "G6", 80)


def strings_and_finale():
    cc("strings", 0, 11, 0)
    chord("strings", bar(14), bar(17) - bar(14), ["C3", "G3", "E4"], 70)
    ramp("strings", bar(14), bar(15), 0, 96)
    chord("uke", FINAL, 2.5, UKE["C"], 92, spread=0.015)
    note("pizz", FINAL, 0.8, "C2", 100)
    note("timp", FINAL, 0.9, "C2", 100)
    chord("strings", FINAL, 6.0, ["C3", "G3", "E4", "C5"], 82)
    ramp("strings", FINAL + 1.5, END - 0.5, 110, 0)
    for w, k in [("snap", "G5"), ("organize", "C6"), ("wear", "E6")]:
        note("glock", word("end", w), 0.8, k, 84)
    note("glock", word("end", "wear") + 0.02, 1.2, "C7", 70)
    for i, k in enumerate(["C5", "E5", "G5", "C6", "G5", "E5"]):
        note("mbox", word("end", "wear") + 1.0 + i * 0.42, 0.8, k, 50 - i * 4)


intro()
groove()
accents()
strings_and_finale()

if __name__ == "__main__":
    stem_report(END) if "--stems" in sys.argv else write(END)
