---
name: terminal-gif
description: >
  Create polished GIF recordings of terminal commands for READMEs and documentation.
  Records real command output with asciinema, edits the cast file to compress idle time
  and stagger output for visual clarity, then converts to GIF with agg. Handles the
  full workflow: recording, timing adjustments, color-coded output, and final rendering.
  Triggers on: "terminal gif", "record terminal", "create gif", "demo gif", "README gif",
  "asciinema", "record command output".
allowed-tools:
  - Read
  - Write
  - Bash
---

# Terminal GIF — Polished Terminal Recordings

Create animated GIF recordings of terminal commands that look good in READMEs and docs.

## Tools

- **asciinema**: records terminal sessions to `.cast` files (asciicast v2 format)
- **agg**: converts `.cast` files to `.gif` (https://github.com/asciinema/agg)

Install agg if not available:

```bash
curl -sL https://github.com/asciinema/agg/releases/latest/download/agg-x86_64-unknown-linux-gnu -o /tmp/agg && chmod +x /tmp/agg
```

## Workflow

### Step 1: Record the real command

Capture actual output so timing data and content are authentic:

```bash
asciinema rec --overwrite --cols 90 --rows <rows> -c "<command>" /tmp/recording.cast
```

Choose `--rows` based on expected output height. 24 is standard, increase for longer output.

### Step 2: Inspect the raw cast file

Read the `.cast` file. It will look like this:

```json
{"version": 2, "width": 90, "height": 24, "timestamp": 1775123807, "env": {"SHELL": "/bin/zsh", "TERM": "tmux-256color"}}
[0.095, "o", "some output\r\n"]
[26.159, "o", "rest of output after long wait\r\n"]
```

The problem with raw recordings: commands that do network calls or heavy computation produce long gaps with no output, followed by a burst of text. This makes the GIF mostly blank.

### Step 3: Create an edited cast file

Rewrite the cast file with staggered timing. Rules:

1. **Start with the command itself** in bold: `\u001b[1m$ command here\u001b[0m`
2. **Header/config lines**: space 0.1-0.2s apart for a quick cascade effect
3. **Idle wait before results**: compress to 2-3 seconds max
4. **Individual results**: space 1.5-2s apart so each one is readable
5. **Sub-lines** (failure details, indented output): space 0.2-0.3s apart
6. **Summary line**: add after a 0.5s pause
7. **Final pause**: 2-3s of idle at the end so the viewer can read the summary before it loops

Use ANSI color codes for colored output:
- Green: `\u001b[32mTEXT\u001b[0m`
- Red: `\u001b[31mTEXT\u001b[0m`
- Bold: `\u001b[1mTEXT\u001b[0m`
- Yellow: `\u001b[33mTEXT\u001b[0m`

Always use `\r\n` for line endings in cast files.

### Step 4: Render the GIF

```bash
/tmp/agg --font-size 16 /tmp/recording-edited.cast output.gif
```

Useful agg flags:
- `--font-size 16`: readable text size (default 14 is small)
- `--speed <N>`: playback speed multiplier
- `--theme <name>`: color theme (asciinema, monokai, solarized-dark, solarized-light)
- `--cols <N>` / `--rows <N>`: override dimensions

### Step 5: Verify

Extract the last frame with Pillow to confirm the final state looks right (the Read tool only shows the first frame of animated GIFs):

```python
from PIL import Image
gif = Image.open("output.gif")
n = 0
try:
    while True:
        gif.seek(n)
        n += 1
except EOFError:
    pass
gif.seek(n - 1)
gif.save("/tmp/last-frame.png")
```

Then read `/tmp/last-frame.png` to visually verify.

## Example: edited cast file

```json
{"version": 2, "width": 90, "height": 28, "timestamp": 1775124301, "env": {"SHELL": "/bin/zsh", "TERM": "tmux-256color"}}
[0.5, "o", "\u001b[1m$ mycommand run tests/example.yaml\u001b[0m\r\n"]
[1.0, "o", "\r\n"]
[1.2, "o", "Config line 1\r\n"]
[1.4, "o", "Config line 2\r\n"]
[1.6, "o", "\r\n"]
[4.0, "o", "  [\u001b[32mPASS\u001b[0m] first test (2.1s)\r\n"]
[6.0, "o", "  [\u001b[31mFAIL\u001b[0m] second test (3.4s)\r\n"]
[6.3, "o", "         failure detail line\r\n"]
[8.0, "o", "  [\u001b[32mPASS\u001b[0m] third test (1.8s)\r\n"]
[8.5, "o", "\r\n"]
[8.7, "o", "  2/3 passed (7.3s)\r\n"]
[11.0, "o", ""]
```

## Sizing guidelines

| Content | Recommended cols x rows |
|---|---|
| Short command, few lines output | 80 x 16 |
| Medium output (5-15 lines) | 90 x 24 |
| Long output or wide lines | 100 x 30 |
| Very dense output | 120 x 36 |

Keep GIF file size under 500KB for README use. If it's larger, reduce rows/cols or trim content.
