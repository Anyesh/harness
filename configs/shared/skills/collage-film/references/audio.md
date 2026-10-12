# Audio

## Narration

`tts/gen.py VOICE SPEED` reads `tts/script.txt`, synthesizes each line with Kokoro-82M, inserts the given pauses, and writes `audio/vo_raw.wav` plus per-word timestamps. `af_heart` at 0.92 to 0.98 suits warm, playful films. A 1.6 s lead-in before the first line leaves room for an establishing beat.

## Score

`tools/score.py` holds the instrument table (`CH`), `note`, `chord`, `hit`, `cc`, `ramp`, `Grid`, and `word(line, w, nth)`, which returns a narration word's start time with the same matching as `wd()` in the picture. Take every cue time from `word()`, never a literal, so a script change cannot leave the score out of sync. Use `Grid(start=word("meet", "meet"), end=word("end", "wardrobe"), bars=N)` so bar downbeats land on two chosen words (the brand reveal and the end card); pick `N` so the tempo comes out between 100 and 125 bpm. Structure that worked:

- An intro before the grid that scores the opening gag beat by beat (music box lullaby, woodblock rattles, a timpani hit on the reveal, a descending xylophone run for falling objects, a bassoon "wah wah" for disappointment).
- A per-bar plan of `(chords, feel)` with feels such as full, light, sparse, rain or lonely, so the groove thins out under sad or quiet beats and returns for the payoff.
- Accent notes on key words (glockenspiel on "Snap", rising notes on "top to toe", a harp gliss into "match").
- A final hit on the end card word, then strings ramped down to the fade.

GeneralUser GS presets confirmed present: Ukulele (bank 8, program 24), Pizzicato Strings (0/45), Music Box (0/10), Glockenspiel (0/9), Xylophone (0/13), Celesta (0/8), Bassoon (0/70), Timpani (0/47), Harp (0/46). Check any new one with `fluidsynth.Synth().sfpreset_name(sfid, bank, prog)`; a missing preset falls back silently. `music.py --stems` prints per-channel RMS, so a silent channel shows up without listening.

## Mix and master

`mix.py` reads the VO, the score and `audio/sfx_cues.json`, applies the VO chain, ducks music under voice, lifts music before the first and after the last line, and writes stems plus `audio/mix_pre.wav`. `master.sh` measures integrated loudness and gains to -14 LUFS with a true-peak limiter.

SFX names available: tap, snip, whoosh, pop, slide, thump, rustle, tear, tape, pencil, bell, crayon, flip, laugh, bark (CC0, see `assets/sfx/LICENSES.md`). A camera shutter is snip plus pop.

## Checks without listening

```python
# SFX competing with the voice: 100 ms windows where SFX is within 3 dB of voice while voice is active
v, sr = sf.read('audio/stem_vo.wav'); s, _ = sf.read('audio/stem_sfx.wav'); w = int(0.1 * sr)
db = lambda a, i: 20 * np.log10(np.sqrt((a[i:i + w] ** 2).mean()) + 1e-9)
print([(i / sr, db(v, i), db(s, i)) for i in range(0, len(v) - w, w) if db(v, i) > -30 and db(s, i) > db(v, i) - 3])
```

Hits that land exactly on a spoken word (a door bang on "closet", a stamp on "Wear") are the usual offenders; gains around 0.4 to 0.5 keep them under the voice. Then run Whisper on `audio/mix.wav` and compare to the script, and `ffmpeg -i audio/mix.wav -af ebur128=peak=true -f null -` for loudness and true peak.
