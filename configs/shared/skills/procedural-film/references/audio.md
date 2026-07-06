# Audio synthesis

Everything is numpy at 44100 Hz stereo, written with the stdlib `wave` module. Build the whole mix in a float array `mix = np.zeros((n, 2))`, add signals at offsets, normalize once at the end.

```python
def add(sig, t0, pan=0.5):
    i0 = int(t0 * SR)
    seg = min(len(sig), n - i0)
    if seg > 0:
        mix[i0:i0 + seg, 0] += sig[:seg] * (1 - pan)
        mix[i0:i0 + seg, 1] += sig[:seg] * pan

pcm = (mix / np.abs(mix).max() * 0.85 * 32767).astype(np.int16)
with wave.open(path, "wb") as f:
    f.setnchannels(2); f.setsampwidth(2); f.setframerate(SR)
    f.writeframes(pcm.tobytes())
```

## Ambient bed (any film)

- **Drones**: 2 to 4 sines on a chord (110, 164.81, 220, 329.63 Hz works; it is A2, E3, A3, E4). Each with a slow amplitude LFO `0.7 + 0.3 sin(2pi 0.05 t + phase)`. Detune the right channel by a factor of 1.0015 to 1.002 for width. Amplitudes 0.01 to 0.03; the bed should be felt, not heard.
- **Bells**: sine plus 0.35 x second harmonic, `exp(-t * 1.6)` decay over about 3 s, amplitude about 0.05, random pan. Pentatonic set that always works: 440, 493.88, 554.37, 659.25, 739.99, 880. Space them 2.5 to 5 s apart, or place them deliberately at emotional beats.
- **Air**: white noise convolved with a 600-sample hanning window (cheap lowpass), amplitude about 0.05 for dark films; for paper films use sparse vinyl crackle instead: a few impulses per second convolved with a 50-sample hanning, amplitude about 0.01.
- **Envelope**: `clip(t / 3, 0, 1) * clip((D - t) / 4.5, 0, 1)` over the whole mix, optionally a gaussian swell (`1 + 0.35 exp(-(t - peak)^2 / 2 sigma^2)`) centered on the film's emotional peak.

## Typewriter kit (event-driven)

Drive these from the same event schedule as the video so sync is exact.

- **Keystroke**: 50 ms. Noise burst `exp(-t * 110)` convolved with a 26-sample hanning, plus a body sine at 950 to 1500 Hz decaying `exp(-t * 190)`, mixed 0.9 : 0.5, total amplitude 0.09 to 0.16, pan randomized 0.35 to 0.65.
- **Space bar**: same recipe but body at 520 to 700 Hz and amplitude 0.05 to 0.09. The softer, deeper thock matters; uniform clicks sound fake.
- **Margin ding**: 2093 Hz plus 0.4 x 5274 Hz, `exp(-t * 3.2)` over 1.4 s, amplitude 0.04, panned slightly right (the bell sits on one side of a real machine).
- **Carriage return**: 0.22 s of noise convolved with a 120-sample hanning, `sin^2` envelope (swoosh up and down), amplitude 0.045, starting 0.12 s after the ding.
- **Strikeout**: four keystroke clicks 70 ms apart at 1.2 x amplitude.

## Mixing judgment

- Peak-normalize to 0.85 to 0.88; never let the sum clip before normalizing (keep component amplitudes at the levels above and there is headroom).
- If the film has a coda in a different world, let the bed continue across the crossfade and mark the transition with two or three bells rather than a new texture.
- Silence is a tool: the pause before a strikeout or a signature reads as thought.
