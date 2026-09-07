import argparse
import re
import sys
from pathlib import Path

CORPUS = Path(__file__).resolve().parent / "corpus.md"
SETTLED = 3


def split_sections(text):
    head, sep, rest = text.partition("\n## Patterns\n")
    if not sep:
        raise SystemExit("corpus.md is missing its '## Patterns' section")
    patterns, sep2, tail = rest.partition("\n## Keeps\n")
    if not sep2:
        raise SystemExit("corpus.md is missing its '## Keeps' section")
    return head, patterns, tail


def parse_entries(patterns):
    entries = []
    for chunk in re.split(r"\n(?=### )", patterns):
        chunk = chunk.strip()
        if not chunk.startswith("### "):
            continue
        lines = chunk.splitlines()
        name = lines[0][4:].strip()
        fields = {}
        for line in lines[1:]:
            key, sep, value = line.partition(":")
            if sep and key.strip() in {
                "effect",
                "confidence",
                "rejected",
                "accepted",
                "note",
            }:
                fields[key.strip()] = value.strip()
        entries.append({"name": name, **fields})
    return entries


def render(entry):
    out = [f"### {entry['name']}"]
    for key in ("effect", "confidence", "rejected", "accepted", "note"):
        if entry.get(key):
            out.append(f"{key}: {entry[key]}")
    return "\n".join(out)


def write(head, entries, keeps_tail, retired):
    body = "\n\n".join(render(e) for e in entries)
    keeps = keeps_tail
    for entry in retired:
        line = f'- {entry["rejected"]} (overruled, was "{entry["name"]}")\n'
        keeps = re.sub(
            r"(\n\n## What the reviewer returns)", f"\n{line}\\1", keeps, count=1
        )
    CORPUS.write_text(f"{head}\n## Patterns\n\n{body}\n\n## Keeps\n{keeps}")


def adjust(name, delta):
    head, patterns, tail = split_sections(CORPUS.read_text())
    entries = parse_entries(patterns)
    match = [e for e in entries if e["name"].lower() == name.lower()]
    if not match:
        raise SystemExit(f"no entry named {name!r}. Run --show to list them.")
    entry = match[0]
    entry["confidence"] = str(int(entry.get("confidence", "0")) + delta)
    retired = []
    if int(entry["confidence"]) <= 0:
        entries.remove(entry)
        retired.append(entry)
        print(f"{entry['name']}: retired to Keeps")
    else:
        print(f"{entry['name']}: confidence now {entry['confidence']}")
    write(head, entries, tail, retired)


def add(name, effect, rejected, accepted, note):
    head, patterns, tail = split_sections(CORPUS.read_text())
    entries = parse_entries(patterns)
    if any(e["name"].lower() == name.lower() for e in entries):
        raise SystemExit(f"{name!r} already exists. Use --confirm to increment it.")
    entries.append(
        {
            "name": name,
            "effect": effect,
            "confidence": "1",
            "rejected": rejected,
            "accepted": accepted,
            "note": note or "",
        }
    )
    write(head, entries, tail, [])
    print(f"{name}: added at confidence 1")


def show():
    _, patterns, _ = split_sections(CORPUS.read_text())
    for entry in parse_entries(patterns):
        n = int(entry.get("confidence", "0"))
        state = "settled" if n >= SETTLED else "provisional"
        print(f"  {n}  {state:<12} {entry['name']}  ({entry.get('effect', '?')})")


def main():
    p = argparse.ArgumentParser(description="Read and update the register corpus.")
    p.add_argument("--show", action="store_true")
    p.add_argument("--confirm", metavar="NAME")
    p.add_argument("--overrule", metavar="NAME")
    p.add_argument("--add", metavar="NAME")
    p.add_argument("--effect", default="emphasis")
    p.add_argument("--rejected", default="")
    p.add_argument("--accepted", default="")
    p.add_argument("--note", default="")
    a = p.parse_args()

    if a.confirm:
        adjust(a.confirm, 1)
    elif a.overrule:
        adjust(a.overrule, -1)
    elif a.add:
        if not a.rejected or not a.accepted:
            raise SystemExit("--add needs --rejected and --accepted")
        add(a.add, a.effect, a.rejected, a.accepted, a.note)
    else:
        show()
    return 0


if __name__ == "__main__":
    sys.exit(main())
