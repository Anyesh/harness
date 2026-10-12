import sys

from score import Grid, chord, film_duration, hit, note, stem_report, word, write

END = film_duration()
bar = Grid(start=word("hello", "hello"), bpm=104)

for b, (root, stab) in enumerate(
    [("F2", ["A3", "C4", "F4"]), ("C2", ["G3", "C4", "E4"])]
):
    note("pizz", bar(b, 0), 0.4, root, 86)
    chord("pizz", bar(b, 1), 0.3, stab, 62)
    chord("pizz", bar(b, 3), 0.3, stab, 62)
    for e in range(8):
        hit(bar(b, e * 0.5), "shaker", 40)
note("glock", bar(0, 0), 0.6, "C6", 60)
note("glock", word("bye", "film"), 0.8, "G6", 64)

if __name__ == "__main__":
    stem_report(END) if "--stems" in sys.argv else write(END)
