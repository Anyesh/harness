import re
import sys

# A language server is only worth running if it covers a meaningful slice of
# the repo that no already-chosen server covers; below this, a stray deploy
# script or two would start a whole extra LSP process.
MIN_MARGINAL_SHARE = 0.05

KEY_RE = re.compile(r"^language_servers:[ \t]*(.*?)[ \t]*$")
ITEM_RE = re.compile(r"^([ \t]*-[ \t]+)(.+?)[ \t]*$")


def select_languages(
    file_matches: list[set[str]],
    priorities: dict[str, int],
    min_share: float = MIN_MARGINAL_SHARE,
) -> list[str]:
    """Pick language servers greedily by the files each adds beyond those already chosen.

    Serena's matchers overlap (vue and svelte also claim every .ts file), so ranking
    languages by raw share would enable redundant servers. The top language is always
    kept, matching Serena's own non-interactive inference.
    """
    recognised = [m for m in file_matches if m]
    if not recognised:
        return []

    files_by_lang: dict[str, set[int]] = {}
    for idx, langs in enumerate(recognised):
        for lang in langs:
            files_by_lang.setdefault(lang, set()).add(idx)

    order = sorted(
        files_by_lang,
        key=lambda lang: (-len(files_by_lang[lang]), -priorities.get(lang, 0), lang),
    )
    selected: list[str] = []
    covered: set[int] = set()
    for lang in order:
        marginal = files_by_lang[lang] - covered
        if not selected or len(marginal) / len(recognised) >= min_share:
            selected.append(lang)
            covered |= files_by_lang[lang]
    return selected


def _unquote(value: str) -> str:
    return value.strip().strip("'\"")


def _find_list(lines: list[str]) -> tuple[int, list[int], str | None]:
    for key_idx, line in enumerate(lines):
        match = KEY_RE.match(line)
        if not match:
            continue
        inline = match.group(1)
        if inline:
            return key_idx, [], inline
        items = []
        for idx in range(key_idx + 1, len(lines)):
            if ITEM_RE.match(lines[idx]):
                items.append(idx)
            else:
                break
        return key_idx, items, None
    return -1, [], None


def configured_languages(text: str) -> list[str]:
    lines = text.splitlines()
    key_idx, items, inline = _find_list(lines)
    if key_idx < 0:
        return []
    if inline is not None:
        body = inline.strip().removeprefix("[").removesuffix("]")
        return [_unquote(v) for v in body.split(",") if _unquote(v)]
    return [_unquote(ITEM_RE.match(lines[idx]).group(2)) for idx in items]


def add_languages(text: str, languages: list[str]) -> tuple[str, list[str]]:
    present = configured_languages(text)
    missing = [lang for lang in dict.fromkeys(languages) if lang not in present]
    if not missing:
        return text, []

    lines = text.splitlines()
    key_idx, items, inline = _find_list(lines)
    if key_idx < 0:
        block = ["language_servers:"] + [f"- {lang}" for lang in missing]
        return "\n".join(lines + block) + "\n", missing

    if inline is not None:
        lines[key_idx : key_idx + 1] = ["language_servers:"] + [
            f"- {lang}" for lang in present + missing
        ]
    else:
        prefix = ITEM_RE.match(lines[items[-1]]).group(1) if items else "- "
        insert_at = items[-1] + 1 if items else key_idx + 1
        lines[insert_at:insert_at] = [f"{prefix}{lang}" for lang in missing]
    return "\n".join(lines) + "\n", missing


def main(argv: list[str]) -> int:
    if len(argv) < 3 or argv[1] not in ("missing", "add"):
        sys.stderr.write(
            "usage: serena_languages.py missing|add <project.yml> <language>...\n"
        )
        return 2
    command, path, languages = argv[1], argv[2], argv[3:]
    with open(path) as f:
        text = f.read()
    new_text, missing = add_languages(text, languages)
    if command == "add" and missing:
        with open(path, "w") as f:
            f.write(new_text)
    if command == "missing":
        print("\n".join(missing))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
