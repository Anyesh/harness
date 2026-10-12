import json
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
from kokoro import KPipeline

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "audio"
SR = 24000

VOICE = sys.argv[1] if len(sys.argv) > 1 else "af_heart"
SPEED = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0

LEAD_IN = 1.6

# (id, text, pause after in seconds)
LINES = [
    ("q", "What is the purpose of life?", 0.9),
    ("long", "People have been asking that for a very, very long time.", 0.7),
    ("happy", "Some say it's to be happy.", 0.3),
    ("good", "Some say, to be good.", 0.3),
    ("mark", "Some say, to leave a mark.", 0.45),
    ("snacks", "And some say... snacks.", 1.0),
    ("look", "So we go looking.", 0.25),
    ("stars", "Up in the stars.", 0.2),
    ("rocks", "Under rocks.", 0.2),
    ("books", "Inside very big books.", 0.8),
    (
        "find",
        "But maybe purpose isn't something you find, lying around somewhere.",
        0.7,
    ),
    ("make", "Maybe it's something you make.", 1.1),
    ("scraps", "Out of small, ordinary scraps.", 0.35),
    ("cup", "A warm cup in the morning.", 0.25),
    ("laugh", "A friend's laugh.", 0.25),
    ("question", "A question you can't stop asking.", 0.25),
    ("glad", "Someone who's glad you're here.", 0.8),
    (
        "glue",
        "Cut them from your days, and glue them together with the people you love.",
        0.75,
    ),
    (
        "unfinished",
        "It doesn't have to be finished, or make sense to anyone else.",
        0.45,
    ),
    ("yours", "It just has to be yours.", 0.0),
]


def trim(audio, thresh=0.002):
    idx = np.where(np.abs(audio) > thresh)[0]
    if len(idx) == 0:
        return audio, 0
    a = max(idx[0] - int(0.09 * SR), 0)
    b = min(idx[-1] + int(0.06 * SR), len(audio))
    return audio[a:b], a


def main():
    pipe = KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M")
    chunks = [np.zeros(int(LEAD_IN * SR), dtype=np.float32)]
    cursor = LEAD_IN
    timeline = []
    for lid, text, pause in LINES:
        audio_parts, words = [], []
        offset = 0.0
        for res in pipe(text, voice=VOICE, speed=SPEED):
            a = (
                res.audio.numpy()
                if hasattr(res.audio, "numpy")
                else np.asarray(res.audio)
            )
            for tok in res.tokens or []:
                if tok.start_ts is None:
                    continue
                words.append(
                    {
                        "w": tok.text,
                        "s": offset + tok.start_ts,
                        "e": offset + (tok.end_ts or tok.start_ts),
                    }
                )
            audio_parts.append(a)
            offset += len(a) / SR
        audio = np.concatenate(audio_parts).astype(np.float32)
        audio, cut = trim(audio)
        shift = cut / SR
        dur = len(audio) / SR
        for w in words:
            w["s"] = round(cursor + w["s"] - shift, 3)
            w["e"] = round(cursor + w["e"] - shift, 3)
        timeline.append(
            {
                "id": lid,
                "text": text,
                "start": round(cursor, 3),
                "end": round(cursor + dur, 3),
                "words": words,
            }
        )
        chunks.append(audio)
        chunks.append(np.zeros(int(pause * SR), dtype=np.float32))
        cursor += dur + pause
    vo = np.concatenate(chunks)
    sf.write(OUT / "vo_raw.wav", vo, SR)
    (OUT / "vo_timeline.json").write_text(
        json.dumps(
            {
                "voice": VOICE,
                "speed": SPEED,
                "duration": round(len(vo) / SR, 3),
                "lines": timeline,
            },
            indent=1,
        )
    )
    print(f"total {len(vo) / SR:.2f}s")
    for t in timeline:
        print(f"{t['start']:6.2f}-{t['end']:6.2f} {t['id']:10s} {t['text']}")


if __name__ == "__main__":
    main()
