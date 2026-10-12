#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
WORKERS=${WORKERS:-4}
OUT=${1:-../render/film.mp4}
DUR=$(python3 -c "import json;print(json.load(open('../audio/film.json'))['duration'])")
mkdir -p ../render/parts
rm -f ../render/parts/*
list=../render/parts/list.txt
for ((i = 0; i < WORKERS; i++)); do
  A=$(python3 -c "print($DUR*$i/$WORKERS)")
  B=$(python3 -c "print($DUR*($i+1)/$WORKERS)")
  NOAUDIO=1 node render.mjs ../render/parts/p$i.mp4 $A $B > ../render/parts/p$i.log 2>&1 &
  echo "file 'p$i.mp4'" >> $list
done
wait
ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i $list -i ../audio/mix.wav -map 0:v -map 1:a -c:v copy -c:a aac -b:a 256k -ar 48000 -movflags +faststart -shortest "$OUT"
ffmpeg -hide_banner -loglevel error -y -i "$OUT" -c:v libx264 -preset slow -crf 20 -tune film -pix_fmt yuv420p -c:a copy -movflags +faststart "${OUT%.mp4}-share.mp4"
ffprobe -v error -count_frames -show_entries stream=codec_name,nb_read_frames,duration -of compact "$OUT"
