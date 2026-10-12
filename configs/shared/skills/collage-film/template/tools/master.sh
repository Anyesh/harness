#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
I=$(ffmpeg -hide_banner -i audio/mix_pre.wav -af ebur128 -f null - 2>&1 | grep -E "^\s+I:" | tail -1 | awk '{print $2}')
G=$(python3 -c "print(round(-14.0-($I),2))")
ffmpeg -hide_banner -y -loglevel error -i audio/mix_pre.wav -af "volume=${G}dB,alimiter=limit=0.79:attack=4:release=60:level=false,aresample=48000" -c:a pcm_s24le audio/mix.wav
mkdir -p web/audio && ffmpeg -hide_banner -y -loglevel error -i audio/mix.wav -c:a aac -b:a 256k web/audio/mix.m4a
ffmpeg -hide_banner -i audio/mix.wav -af ebur128=peak=true -f null - 2>&1 | grep -E "^\s+(I|Peak):"
