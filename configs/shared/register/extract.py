import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CORPUS = HERE / "corpus.md"


def html_blocks(html):
    html = re.sub(
        r"<style.*?</style>|<script.*?</script>|<!--.*?-->", "", html, flags=re.S
    )
    slides = re.findall(r'<section class="slide[^"]*"[^>]*>(.*?)</section>', html, re.S)
    chunks = (
        slides
        if slides
        else re.findall(r"<body[^>]*>(.*?)</body>", html, re.S) or [html]
    )
    out = []
    for chunk in chunks:
        text = re.sub(r"<[^>]+>", " ", chunk)
        text = re.sub(r"\s+", " ", text).strip()
        if text:
            out.append(text)
    return out


def markdown_blocks(text):
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    out = []
    heading = "(top)"
    buf = []
    for line in text.splitlines():
        if line.startswith("#"):
            if buf:
                out.append(f"{heading}: " + " ".join(buf).strip())
                buf = []
            heading = line.lstrip("#").strip()
            continue
        if line.strip():
            buf.append(line.strip())
    if buf:
        out.append(f"{heading}: " + " ".join(buf).strip())
    return out


def blocks(path):
    raw = path.read_text()
    if path.suffix.lower() in {".html", ".htm"}:
        return html_blocks(raw)
    return markdown_blocks(raw)


def build_prompt(paths):
    corpus = CORPUS.read_text()
    sections = []
    for path in paths:
        labelled = "\n\n".join(
            f"[{path.name} block {i}] {b}" for i, b in enumerate(blocks(path), 1)
        )
        sections.append(labelled)
    body = "\n\n".join(sections)
    return (
        f"{corpus}\n\n---\n\nApply the corpus to the text below and report per the "
        f"'What the reviewer returns' section above.\n\n{body}"
    )


def main():
    paths = [Path(a) for a in sys.argv[1:]]
    missing = [p for p in paths if not p.is_file()]
    if not paths or missing:
        print(
            f"usage: extract.py <file> [file ...]  (missing: {missing})",
            file=sys.stderr,
        )
        return 2
    print(build_prompt(paths))
    return 0


if __name__ == "__main__":
    sys.exit(main())
