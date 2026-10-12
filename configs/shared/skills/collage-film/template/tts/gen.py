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

# script.txt: one line per VO line as "id | text | pause_after_seconds"; lines starting with # are ignored.
LINES = [
    (a.strip(), b.strip(), float(c))
    for a, b, c in (ln.split("|") for ln in (ROOT / "tts/script.txt").read_text().splitlines() if ln.strip() and not ln.startswith("#"))
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
