#!/usr/bin/env bash
# Rebuilds <vault>/wiki/index.md from each folder's own index.md.
# Usage: wiki-index-build.sh <vault> [--if-changed]

VAULT="${1:-}"
MODE="${2:-}"

[[ "$VAULT" == /* && -d "$VAULT/wiki" ]] || exit 0

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/harness"
STAMP="$STATE_DIR/wiki-index.$(printf '%s' "$VAULT" | cksum | cut -d' ' -f1).stamp"

if [[ "$MODE" == "--if-changed" && -f "$STAMP" ]]; then
    [[ -n "$(find "$VAULT/wiki" -mindepth 1 ! -path "$VAULT/wiki/index.md" \( -name '*.md' -o -type d \) -newer "$STAMP" -print -quit 2>/dev/null)" ]] || exit 0
fi

# Stamped before the scan, so a page written during it is newer than the stamp.
mkdir -p "$STATE_DIR" 2>/dev/null
NEXT_STAMP="$STAMP.$$"
touch "$NEXT_STAMP" 2>/dev/null

python3 - "$VAULT/wiki" <<'PY' || { rm -f "$NEXT_STAMP"; exit 0; }
import os, re, sys, tempfile
from urllib.parse import unquote

wiki = sys.argv[1]
index_path = os.path.join(wiki, "index.md")
SECTIONS = [("concepts", "Concepts"), ("sources", "Sources"), ("synthesis", "Syntheses")]
LINK = re.compile(r"\]\((<[^>\n]+>|[^)\s]+)\)")
WIKILINK = re.compile(r"\[\[([^\]|#\n]+)")


def frontmatter(text):
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---", 4)
    if end < 0:
        return {}, text
    fields = {}
    for line in text[4:end].splitlines():
        key, sep, value = line.partition(":")
        if sep:
            fields[key.strip()] = value.strip().strip('"')
    return fields, text[end + 4:].lstrip("\n")


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return ""


if os.path.exists(index_path) and frontmatter(read(index_path))[0].get("generated") != "true":
    sys.exit(0)


def page_title(path):
    fields, body = frontmatter(read(path))
    if fields.get("title"):
        return fields["title"]
    for line in body.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return os.path.splitext(os.path.basename(path))[0]


def resolve(folder, target):
    if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I) or target.startswith(("#", "/")):
        return target
    path, hash_, anchor = target.partition("#")
    joined = os.path.normpath(os.path.join(folder, path))
    rooted = os.path.normpath(path)
    if not os.path.exists(os.path.join(wiki, unquote(joined))) and os.path.exists(os.path.join(wiki, unquote(rooted))):
        joined = rooted
    return joined + (hash_ + anchor if hash_ else "")


def rewrite_link(folder, match):
    target = match.group(1)
    if target.startswith("<"):
        return "](<" + resolve(folder, target[1:-1]) + ">)"
    return "](" + resolve(folder, target) + ")"


def link_page(target):
    if target.startswith("<"):
        target = target[1:-1]
    return unquote(target.partition("#")[0])


# Obsidian's resolution: an exact path first, else the shortest path ending in the target.
def resolve_wikilink(stems, folder, target):
    target = target.strip().removesuffix(".md")
    exact = os.path.normpath(os.path.join(folder, target))
    if exact in stems:
        return exact
    matches = sorted((s for s in stems if s.endswith("/" + target)), key=lambda s: (s.count("/"), s))
    return matches[0] if matches else None


def markdown_target(page):
    return f"<{page}>" if " " in page else page


def pages_under(folder_abs):
    found = []
    for root, dirs, files in os.walk(folder_abs):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        for name in sorted(files):
            if name.endswith(".md"):
                found.append(os.path.relpath(os.path.join(root, name), wiki))
    return found


def folder_block(rel_folder, heading_slug, level):
    folder_abs = os.path.join(wiki, rel_folder)
    own_index = os.path.join(folder_abs, "index.md")
    fields, body = frontmatter(read(own_index)) if os.path.isfile(own_index) else ({}, "")
    pages = pages_under(folder_abs)
    stems = {page[:-3] for page in pages}
    lines, listed = [], set()

    def rewrite_wikilink(match):
        stem = resolve_wikilink(stems, rel_folder, match.group(1))
        if stem is None:
            return match.group(0)
        listed.add(stem + ".md")
        return "[[" + stem

    for line in body.splitlines():
        if not line.lstrip().startswith("- "):
            continue
        line = LINK.sub(lambda m: rewrite_link(rel_folder, m), line)
        listed.update(link_page(t) for t in LINK.findall(line))
        line = WIKILINK.sub(rewrite_wikilink, line)
        lines.append(line)
    own_rel = os.path.relpath(own_index, wiki)
    for page in pages:
        if page == own_rel or page in listed:
            continue
        lines.append(f"- [{page_title(os.path.join(wiki, page))}]({markdown_target(page)}): unlisted")
    if level == 3:
        title = fields.get("title", "")
        heading = f"### {heading_slug}: {title}" if title else f"### {heading_slug}"
        return [heading] + lines + [""]
    return lines + [""] if lines else []


out = [
    "---",
    "type: index",
    "generated: true",
    "---",
    "",
    "# Wiki Index",
    "",
    "Generated by the harness from each folder's index.md. Edit those files, not this one.",
    "",
    "## Projects",
    "",
]
projects_dir = os.path.join(wiki, "projects")
if os.path.isdir(projects_dir):
    for slug in sorted(os.listdir(projects_dir)):
        if os.path.isdir(os.path.join(projects_dir, slug)) and not slug.startswith("."):
            out += folder_block(os.path.join("projects", slug), slug, 3)
for folder, heading in SECTIONS:
    if os.path.isdir(os.path.join(wiki, folder)):
        out += [f"## {heading}", ""] + folder_block(folder, folder, 2)

indexed = {"projects"} | {folder for folder, _ in SECTIONS}
other = []
if os.path.isdir(projects_dir):
    other += [f"projects/{n}" for n in sorted(os.listdir(projects_dir)) if n.endswith(".md") and not n.startswith(".")]
for name in sorted(os.listdir(wiki)):
    full = os.path.join(wiki, name)
    if name.startswith(".") or name in indexed:
        continue
    if os.path.isdir(full):
        other += pages_under(full)
    elif name.endswith(".md") and name != "index.md":
        other.append(name)
if other:
    out += ["## Other", ""]
    out += [f"- [{page_title(os.path.join(wiki, p))}]({markdown_target(p)})" for p in other]
    out.append("")

text = "\n".join(out).rstrip("\n") + "\n"
if read(index_path) == text:
    sys.exit(0)
fd, tmp = tempfile.mkstemp(dir=wiki, prefix=".index.", suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(text)
os.chmod(tmp, 0o644)
os.replace(tmp, index_path)
PY

mv -f "$NEXT_STAMP" "$STAMP" 2>/dev/null
exit 0
