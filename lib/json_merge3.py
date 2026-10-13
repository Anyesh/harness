"""Three-way merge of a harness-rendered JSON config into a user's local copy.

Usage: json_merge3.py OURS THEIRS OUT [BASE]

OURS is the new harness render, THEIRS the file on disk, BASE the harness render
the local file was last reconciled against (omit when unknown). Writes the merge
to OUT and prints one line per conflict: path, local value, harness value, tab
separated. Exits 3 without writing when THEIRS is not strict JSON.

Rules:
- Objects merge key by key. Keys only in THEIRS are local additions and stay,
  unless BASE shows the harness used to ship them unchanged, in which case the
  harness dropped them and they go.
- Arrays are ordered sets: OURS in order, then THEIRS entries that neither side
  of the harness knows. Entries the harness dropped since BASE go. Harness
  entries missing locally come back, because the harness guarantees its hooks.
- Scalars take whichever side moved away from BASE. When both moved (or there
  is no BASE and they differ), the local value wins and the path is reported.
"""

import json
import sys

MISSING = object()
REMOVED = "(removed)"


def merge(base, ours, theirs, path, conflicts):
    if isinstance(ours, dict) and isinstance(theirs, dict):
        return merge_objects(
            base if isinstance(base, dict) else {}, ours, theirs, path, conflicts
        )
    if isinstance(ours, list) and isinstance(theirs, list):
        return merge_arrays(base if isinstance(base, list) else [], ours, theirs)
    if ours == theirs:
        return ours
    if base is not MISSING and theirs == base:
        return ours
    if base is not MISSING and ours == base:
        return theirs
    conflicts.append((path, theirs, ours))
    return theirs


def merge_objects(base, ours, theirs, path, conflicts):
    result = {}
    for key, value in ours.items():
        if key in theirs:
            result[key] = merge(
                base.get(key, MISSING), value, theirs[key], join(path, key), conflicts
            )
        else:
            result[key] = value
    for key, value in theirs.items():
        if key in ours:
            continue
        if key not in base:
            result[key] = value
        elif value != base[key]:
            conflicts.append((join(path, key), value, MISSING))
            result[key] = value
    return result


def merge_arrays(base, ours, theirs):
    result = list(ours)
    for item in theirs:
        if item not in ours and item not in base:
            result.append(item)
    return result


def join(path, key):
    return f"{path}.{key}" if path else key


def show(value):
    if value is MISSING:
        return REMOVED
    text = json.dumps(value, separators=(",", ":"))
    return text if len(text) <= 120 else text[:117] + "..."


def load(path, label):
    try:
        with open(path) as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        sys.stderr.write(f"{label} {path} is not strict JSON ({e})\n")
        return MISSING


def main(argv):
    if len(argv) not in (4, 5):
        sys.stderr.write(__doc__)
        return 2
    ours = load(argv[1], "harness render")
    if ours is MISSING:
        return 1
    theirs = load(argv[2], "local file")
    if theirs is MISSING:
        return 3
    base = load(argv[4], "merge base") if len(argv) == 5 else MISSING

    conflicts = []
    merged = merge(base, ours, theirs, "", conflicts)
    with open(argv[3], "w") as f:
        json.dump(merged, f, indent=2, ensure_ascii=False)
        f.write("\n")
    for path, local, harness in conflicts:
        print(f"{path}\t{show(local)}\t{show(harness)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
