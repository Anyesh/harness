import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
d = json.loads((root / "audio/vo_timeline.json").read_text())
lines = {
    l["id"]: {"s": l["start"], "e": l["end"], "text": l["text"], "words": [[w["w"], w["s"], w["e"]] for w in l["words"]]}
    for l in d["lines"]
}
(root / "web/timeline.js").write_text("'use strict';\nconst VO = " + json.dumps(lines) + ";\n")
print("lines", len(lines), file=sys.stderr)
