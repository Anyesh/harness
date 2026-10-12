---
name: collage-film
description: Make a whimsical cut-paper collage animation (30 to 60 s) with real narration, an original score and foley, entirely with free local tools. Visuals are procedural JS canvas (torn paper, boiling ink, crayon, stop-motion camera), narration is Kokoro TTS with word timestamps, music is composed in Python and rendered through a General MIDI soundfont, foley is CC0 recordings fetched on first use. Outputs a 1080p MP4 at -14 LUFS plus a self-contained HTML player. Use for explainer films, product launch videos, demo videos, animated stories, or any "make a fun video about X" request where narration and visuals must sync.
---

# Collage Film

A paper-puppet film made in code: every prop is a cut-paper sprite generated at load time, scenes are pure functions of time drawn onto one canvas, and every animation beat is keyed to a narration word timestamp. No paid APIs, no stock footage, no editor. Two finished films built this way are in `references/examples/` (a philosophical short and a product video); read the product one before writing a product film.

## Method, in order

1. **Research and write the script first.** For a product, read its README and frontend for real claims and brand (logo, colours, fonts); never put an unverified claim in the narration. Write `tts/script.txt` as `id | text | pause-after-seconds`, one line per beat, 35 to 50 s of speech for a ~50 s film. Spell words the way they should be *spoken* (a brand pun can be spoken as the plain word and shown spelled on screen).
2. **Scaffold.** `bash <this skill's directory>/template/setup.sh <project-dir>` copies the template, builds a uv venv, installs node deps, and copies fonts, SFX and a soundfont link from `~/.cache/collage-film/`. On the first run it fills that cache with `assets/fetch.py`: fonts and the soundfont are downloaded at pinned commits, and the SFX are rebuilt from their CC0 sources (`assets/sfx.tsv`), all checked against sha256. The first run takes several minutes (torch, Kokoro, about 4 minutes of SFX downloads); run it in the background.
3. **Narration.** `.venv/bin/python tts/gen.py af_heart 0.98` then `python3 tools/mk_timeline.py` (writes `web/timeline.js` and `audio/vo_timeline.json`). Check with `.venv/bin/python tts/check.py audio/vo_raw.wav`; a low-confidence word at a segment boundary can be an artifact, so re-check that line in isolation before regenerating.
4. **Storyboard against word times.** Print every word with its start time, then write one scene per narration line or two, naming the cue word for each beat (door bursts on "closet", stamp lands on "Wear"). See `references/method.md`.
5. **Art, then scenes.** `web/art.js` builds every sprite into `A` once (`buildArt`); `web/scenes.js` sets `DURATION`, `POSTER_T`, `WIPES`, optional `GRADE(t)`, and `buildScenes()` registers scenes with `scene(t0, t1, draw, { cam, table })` and SFX with `sfx(t, name, gain, pan)`. Look up times with `wd(lineId, word)`, never hard-code them. API cheat sheet in `references/method.md`.
6. **Look at it.** `cd tools && node snap.mjs out.jpg 4 480 t1 t2 ...` renders a contact sheet; Read the image. Review every scene at 2 or 3 times. Fix scale first (see lessons), then collisions and legibility.
7. **Audio.** `node cues.mjs` (exports SFX cues and duration), write `tools/music.py` on a `Grid` whose downbeats hit chosen words, `.venv/bin/python tools/music.py --stems` to confirm every channel sounds, then `music.py`, `mix.py`, `bash master.sh`. Details and checks in `references/audio.md`.
8. **Render and bundle.** `bash tools/render_all.sh ../render/<name>.mp4` (parallel headless Chrome, `WORKERS=4`), then `python3 tools/bundle.py "<Title>" "<credit line>"` for a single-file HTML player.
9. **Verify** (all must pass): ffprobe shows `DURATION*30` frames and equal audio/video length; `ffmpeg -af ebur128=peak=true` gives about -14 LUFS and true peak at or below -1 dBFS; Whisper on `audio/mix.wav` reproduces the script; a final contact sheet across the runtime has no empty, clipped or broken frames.

## Rules that matter most

- Characters and hero props fill 40 to 50 percent of frame height. Every first pass in both example films was too small; zoom the scene camera or scale the sprites before anything else.
- Every beat lands on a word. If nothing on screen changes when a noun is spoken, the film feels unsynced even when it is.
- SFX that land exactly on a word must sit under the voice; check with the stem comparison in `references/audio.md`.
- Keep template tools data-driven (duration from `audio/film.json`, times from the VO timeline) so the next film needs no tool edits. No literal cue times anywhere: `wd()` in scenes, `word()` in `music.py`, and `DURATION` derived from the last line.
- Design a distinct hero for every film (hair, face details, accessories, palette). A product film also drops the vintage grade (`wash: 0`, `vignette` about 0.35, `PAPER_TEXTURE` about 0.4) so brand colours stay true.

## References

- `references/method.md`: storyboarding, scene structure, engine and rig API cheat sheet.
- `references/lessons.md`: mistakes already made and how to avoid them.
- `references/audio.md`: TTS, score composition, mix, mastering and audio verification without listening.
- `references/examples/`: complete `scenes.js`, `art.js`, `music.py` and script for two films.
