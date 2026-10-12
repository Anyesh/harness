# Lessons

Each of these cost a review round on a real film.

- **Everything starts too small.** Characters at 30 percent of frame height, garments at 120 px and notification text at 20 px all read as empty paper in the contact sheet. Aim for characters at 40 to 50 percent, hero props at 25 percent or more, and text at 27 px or more after camera zoom. Zooming a scene camera (`cam` zoom 1.2 to 1.4) is the fastest fix for a sparse scene.
- **Motion smear only on pure pans.** `stage.js` skips smear whenever zoom changes, because a zoom moves the centre and a linear smear streaks sideways. A pan that also zooms gets no smear; that is intended.
- **Rig-scale props.** Props drawn through the rig (`pose.shoe`, `pose.body`) must be built at rig scale; a boot built for a standalone shot was 2.6 times too large on the character's foot.
- **Wipe timing.** The incoming scene is drawn during the wipe, so give scenes a range that starts at the previous wipe's `t0`, and do not start a cue-word animation inside the wipe unless it should be half-hidden.
- **Collisions show up only in the contact sheet.** Rating cards held over heads overlapped because characters stood 240 px apart; window and notification collided after the notification was enlarged. Re-snap the affected times after every scale change.
- **Fonts.** A hard-coded font family list in `main.js` broke when a brand font was added; it now waits for every `document.fonts` entry. `measure()` and `textShapes()` silently fall back to a default font if the face has not loaded.
- **Ink randomness.** Seed per boil frame (`rng(hash(key, boilIndex(t)))`); seeding per draw call makes lines crawl at 30 fps instead of boiling at 8.
- **Whisper boundary artifacts.** A word scored 0.00 at a segment boundary transcribed at 0.97 when the line was checked in isolation. Re-check before regenerating narration.
- **Do not claim what you did not verify.** A product feature mentioned by a helper agent but absent from the README stayed out of the script.
- **Design a distinct hero per film.** The first product film reused the purpose-of-life puppet and the user noticed at once. Change hair shape (`hairBack`, `longHairBack()`, `HAIR.bangs`), face details (`lashes`, `freckles`), accessories (`adorn`) and palette, not just the shirt colour.
- **The vintage grade dirties brand colours.** The default warm wash, heavy vignette and full paper texture turned a product's monochrome and fabric colours beige. Product films use `GRADE` `wash: 0`, `vignette` about 0.35 and `PAPER_TEXTURE` about 0.4.
- **`post()` paints outside rounded shapes.** `makePaper`'s `post(g)` runs after the shape clip is released, so a full-bounds fill in it squared off a rounded logo tile. Clip to `inners[0]` inside `post` before filling.
- **No hard-coded cue times.** A script edit shifted every word and left stale times in the ending and the score. Derive `DURATION`, the last wipe and `GRADE` windows from `wd('end', ...)`, and every music cue from `word(line, w)` in `score.py`.
- **Background long steps.** `setup.sh` (torch install) and `render_all.sh` take minutes; run them in the background and do other work.
