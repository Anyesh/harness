#!/usr/bin/env python3
"""Fetch collage-film's third-party assets into a shared cache.

usage: fetch.py CACHE_DIR

Fonts and the soundfont are downloaded as-is. SFX are rebuilt with ffmpeg from
their CC0 sources listed in sfx.tsv, because the clips were trimmed and filtered
after download and exist nowhere upstream in that form. Every download is checked
against a pinned sha256 and a mismatch aborts, so a changed upstream file cannot
silently alter a film.
"""

import csv
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
UA = "Mozilla/5.0"
SOUNDFONT_URL = (
    "https://raw.githubusercontent.com/mrbumpy409/GeneralUser-GS/"
    "97049183643d5fc5a9322a69c5b09efb667c6c3a/GeneralUser-GS.sf2"
)
SOUNDFONT_SHA256 = "9575028c7a1f589f5770fccc8cff2734566af40cd26ed836944e9a5152688cfe"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def verified(path, expected):
    got = sha256(path)
    if got != expected:
        sys.exit(f"sha256 mismatch for {path}: expected {expected}, got {got}")
    return path


def curl(*args):
    subprocess.run(["curl", "-sfL", "--retry", "3", "-A", UA, *args], check=True)


def rows(manifest):
    with open(HERE / manifest, newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def download(url, expected, dest):
    if dest.exists() and sha256(dest) == expected:
        return
    part = dest.with_name(dest.name + ".part")
    curl("-o", str(part), url)
    verified(part, expected)
    part.replace(dest)


def fetch_fonts(cache):
    out = cache / "fonts"
    out.mkdir(parents=True, exist_ok=True)
    for row in rows("fonts.tsv"):
        download(row["url"], row["sha256"], out / row["filename"])


def fetch_bigsoundbank(sound_id, dest):
    # The site serves WAVs only through its download form: the first POST sets a
    # session cookie and starts a countdown that must elapse before the second POST.
    with tempfile.TemporaryDirectory() as tmp:
        jar = str(Path(tmp) / "cookies")
        curl(
            "-c",
            jar,
            "-d",
            f"format=wav&id={sound_id}&button=Download",
            "-o",
            os.devnull,
            "https://bigsoundbank.com/download.php",
        )
        time.sleep(6)
        curl(
            "-b",
            jar,
            "-e",
            "https://bigsoundbank.com/download.php",
            "-d",
            f"id={sound_id}&format=wav&antibot_hp=",
            "-o",
            str(dest),
            "https://bigsoundbank.com/modules/telecharger.php",
        )


def fetch_source(row, raw):
    kind, key = row["source_key"].split(":")
    if kind == "bsb":
        src = raw / f"bsb-{key}.wav"
        if not src.exists():
            fetch_bigsoundbank(key, src)
    else:
        archive = raw / f"kenney-{kind}.zip"
        if not archive.exists():
            curl("-o", str(archive), row["download_url"])
        src = raw / f"kenney-{kind}-{Path(row['zip_member']).name}"
        if not src.exists():
            with zipfile.ZipFile(archive) as zf:
                src.write_bytes(zf.read(row["zip_member"]))
    return verified(src, row["source_sha256"])


def build_clip(row, src, out):
    dur = float(row["dur_s"])
    fade = float(row["fade_out_s"])
    chain = []
    if int(row["highpass_hz"]):
        chain.append(f"highpass=f={row['highpass_hz']}")
    chain.append(
        "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.005"
    )
    chain.append(f"atrim=duration={dur}")
    chain.append(f"afade=t=out:st={round(dur - fade, 4)}:d={fade}")
    if int(row["pre_resample"]):
        chain.append("aresample=48000")
    if float(row["gain_db"]):
        chain.append(f"volume={row['gain_db']}dB")
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-y",
            "-ss",
            row["start_s"],
            "-i",
            str(src),
            "-af",
            ",".join(chain),
            "-ac",
            "2",
            "-ar",
            "48000",
            "-c:a",
            "pcm_s24le",
            str(out / f"{row['name']}.wav"),
        ],
        check=True,
    )


def fetch_sfx(cache):
    out = cache / "sfx"
    stamp = sha256(HERE / "sfx.tsv")
    if (out / ".manifest").is_file() and (out / ".manifest").read_text() == stamp:
        return
    # Built in a staging dir and swapped in whole, so an interrupted run never
    # leaves a partial sfx/ that a later run would accept.
    staging = cache / "sfx.partial"
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    with tempfile.TemporaryDirectory(dir=cache) as raw:
        for row in rows("sfx.tsv"):
            build_clip(row, fetch_source(row, Path(raw)), staging)
    shutil.copy(HERE / "LICENSES.md", staging / "LICENSES.md")
    (staging / ".manifest").write_text(stamp)
    shutil.rmtree(out, ignore_errors=True)
    staging.replace(out)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: fetch.py CACHE_DIR")
    cache = Path(sys.argv[1])
    cache.mkdir(parents=True, exist_ok=True)
    fetch_fonts(cache)
    download(SOUNDFONT_URL, SOUNDFONT_SHA256, cache / "GeneralUser-GS.sf2")
    fetch_sfx(cache)


if __name__ == "__main__":
    main()
