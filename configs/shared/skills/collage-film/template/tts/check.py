import sys

import soundfile as sf
from faster_whisper import WhisperModel
from scipy.signal import resample_poly

audio, sr = sf.read(sys.argv[1], dtype="float32")
if audio.ndim > 1:
    audio = audio.mean(axis=1)
audio = resample_poly(audio, 16000, sr).astype("float32")
m = WhisperModel("small.en", device="cpu", compute_type="int8")
segs, _ = m.transcribe(audio, word_timestamps=True, vad_filter=False)
for s in segs:
    print(f"{s.start:6.2f}-{s.end:6.2f} {s.text.strip()}  [min word prob {min(w.probability for w in s.words):.2f}]")
