#!/usr/bin/env bash
set -euo pipefail
SKILL="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:?usage: setup.sh <project-dir>}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/collage-film"
mkdir -p "$DEST"/{audio,render,assets/sf,assets/sfx,web/fonts,web/audio}
cp -rn "$SKILL"/template/{web,tts,tools} "$DEST"/
cd "$DEST"
[ -d .venv ] || uv venv -q .venv --python 3.12
uv pip install -q --python .venv/bin/python "kokoro>=0.9.4" soundfile numpy scipy pedalboard pyfluidsynth faster-whisper "av>=14" torch --index-strategy unsafe-best-match --extra-index-url https://download.pytorch.org/whl/cpu
.venv/bin/python "$SKILL/assets/fetch.py" "$CACHE"
cp -n "$CACHE"/fonts/*.ttf web/fonts/
cp -n "$CACHE"/sfx/* assets/sfx/
ln -sf "$CACHE/GeneralUser-GS.sf2" assets/sf/GeneralUser-GS.sf2
(cd tools && npm i --silent)
echo "ready: $DEST"
