#!/usr/bin/env python3
"""Fetch collage-film's fonts and soundfont into a shared cache.

usage: fetch.py CACHE_DIR

Every download is checked against a pinned sha256 and a mismatch aborts, so a
changed upstream file cannot silently alter a film.
"""

import csv
import hashlib
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
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


def download(url, expected, dest):
    if dest.exists() and sha256(dest) == expected:
        return
    part = dest.with_name(dest.name + ".part")
    subprocess.run(["curl", "-sfL", "--retry", "3", "-o", str(part), url], check=True)
    got = sha256(part)
    if got != expected:
        sys.exit(f"sha256 mismatch for {url}: expected {expected}, got {got}")
    part.replace(dest)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: fetch.py CACHE_DIR")
    cache = Path(sys.argv[1])
    (cache / "fonts").mkdir(parents=True, exist_ok=True)
    with open(HERE / "fonts.tsv", newline="") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            download(row["url"], row["sha256"], cache / "fonts" / row["filename"])
    download(SOUNDFONT_URL, SOUNDFONT_SHA256, cache / "GeneralUser-GS.sf2")


if __name__ == "__main__":
    main()
