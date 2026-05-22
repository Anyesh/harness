#!/usr/bin/env python3
# PreToolUse hook: blocks unnecessary AI-style narrative comments and trivial
# one-liner docstrings across all source languages. Allows comments that explain
# WHY (non-obvious constraints, invariants, workarounds, surprising behavior).

import json
import re
import sys
from pathlib import Path

LANG_MAP = {
    "python": ({".py", ".pyi"}, ("#",), ('"""', "'''")),
    "js": ({".js", ".jsx", ".mjs", ".cjs"}, ("//",), ("/*", "*/")),
    "ts": ({".ts", ".tsx", ".mts", ".cts"}, ("//",), ("/*", "*/")),
    "go": ({".go"}, ("//",), ("/*", "*/")),
    "rust": ({".rs"}, ("///", "//!", "//"), ("/*", "*/")),
    "c": (
        {".c", ".h", ".cpp", ".hpp", ".cc", ".hh", ".cxx", ".hxx", ".ino"},
        ("//",),
        ("/*", "*/"),
    ),
    "java": ({".java", ".kt", ".kts", ".scala", ".groovy"}, ("//",), ("/*", "*/")),
    "swift": ({".swift"}, ("//",), ("/*", "*/")),
    "ruby": ({".rb", ".rake"}, ("#",), None),
    "shell": ({".sh", ".bash", ".zsh", ".ksh"}, ("#",), None),
    "lua": ({".lua"}, ("--",), None),
    "php": ({".php"}, ("//", "#"), ("/*", "*/")),
    "sql": ({".sql"}, ("--",), ("/*", "*/")),
    "dart": ({".dart"}, ("///", "//"), ("/*", "*/")),
    "yaml": (set(), tuple(), None),
}

EXT_TO_LANG = {}
for lang, (exts, prefs, block) in LANG_MAP.items():
    for e in exts:
        EXT_TO_LANG[e] = (lang, prefs, block)


def detect_lang(path: str):
    ext = Path(path).suffix.lower()
    return EXT_TO_LANG.get(ext, (None, None, None))


NARRATIVE_VERBS = (
    r"(?:gets?|sets?|puts?|returns?|creates?|updates?|deletes?|checks?|handles?|"
    r"processes|processe?s|initializes?|configures?|validates?|fetche?s?|loads?|"
    r"saves?|sends?|parses?|converts?|formats?|builds?|renders?|displays?|"
    r"calculates?|computes?|stores?|prints?|logs?|assigns?|adds?|removes?|"
    r"inserts?|pushes?|pops?|starts?|stops?|begins?|ends?|opens?|closes?|"
    r"iterates?|loops?|filters?|maps?|reduces?|increments?|decrements?|clears?|"
    r"resets?|applies|runs?|executes?|calls?|invokes?|dispatches?|emits?|"
    r"triggers?|registers?|unregisters?|mounts?|unmounts?|binds?|unbinds?|"
    r"attaches?|detaches?|sets?[- ]?up|tears?[- ]?down|defines?|declares?|"
    r"imports?|exports?|uses?|finds?|looks?[- ]?up|matches?|compares?|sorts?|"
    r"groups?|merges?|splits?|joins?|wraps?|unwraps?|tracks?|measures?|records?|"
    r"captures?|collects?|yields?|throws?|raises?|generates?|tests?|verifies|"
    r"ensures?|prepares?|cleans?[- ]?up|copies|moves?|schedules?)"
)

NARRATIVE_RE = [
    re.compile(
        rf"^{NARRATIVE_VERBS}\s+(?:the|a|an|this|that|our|its?|their|new|old)?\s*[a-z_][\w ]*$",
        re.IGNORECASE,
    ),
    re.compile(rf"^{NARRATIVE_VERBS}\s+[a-z_][\w]*$", re.IGNORECASE),
    re.compile(
        r"^this\s+(?:function|method|variable|class|script|code|module|file|component|handler|helper|block|section|loop|line|property|field|constant|type|interface|struct|enum|macro|test|route|endpoint)\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"^(?:the|a|an)\s+(?:function|method|class|handler|helper)\s+(?:that|which|to|for)\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"^(?:used|called|referenced|invoked)\s+(?:by|from|in)\b", re.IGNORECASE
    ),
    re.compile(
        r"^(?:added|created|introduced|needed|required|written|implemented)\s+(?:for|by|in|to\s+support)\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"^for\s+(?:the\s+)?\w+\s+(?:flow|feature|case|ticket|issue|endpoint|route|component|module|page|screen|test)\b",
        re.IGNORECASE,
    ),
    re.compile(r"^part\s+of\s+(?:the\s+)?\w+\b", re.IGNORECASE),
    re.compile(r"^removed\s+\w", re.IGNORECASE),
    re.compile(r"^was\s*[:=]", re.IGNORECASE),
    re.compile(r"^previously\s*[:=]", re.IGNORECASE),
    re.compile(
        r"^(?:updated|changed|renamed|refactored)\s+(?:from|to)\s+\w", re.IGNORECASE
    ),
    re.compile(
        r"^fix(?:ed|es)?\s+(?:for\s+)?(?:bug|issue|#\d|the\s+bug)", re.IGNORECASE
    ),
    re.compile(r"^deprecated\s+in\s+favor\s+of\b", re.IGNORECASE),
    re.compile(r"^replaces?\s+(?:the\s+)?old\b", re.IGNORECASE),
    re.compile(
        r"^(?:new|old)\s+(?:code|behavior|logic|impl|implementation)\s*[:=]",
        re.IGNORECASE,
    ),
    re.compile(r"^see\s+(?:ticket|issue|pr|mr|#)\b", re.IGNORECASE),
    re.compile(r"^tracks?\s+#\d", re.IGNORECASE),
    re.compile(
        r"^(?:helper|utility|wrapper|convenience)\s+(?:function|method|class|to|for)\b",
        re.IGNORECASE,
    ),
    re.compile(r"^main\s+(?:entry\s+point|function|loop|handler)\s*$", re.IGNORECASE),
    re.compile(r"^entry\s+point\s*$", re.IGNORECASE),
    re.compile(r"^[-=*#~─═━┄┅┉─]{2,}.*[-=*#~─═━┄┅┉─]{2,}\s*$"),
    re.compile(r"^[-=*#~─═━┄┅┉─]{2,}\s*$"),
]

WHY_MARKERS = (
    "because ",
    "so that ",
    "to avoid ",
    "due to ",
    " since ",
    "otherwise",
    "in order to",
    " so it ",
    " so we ",
    "to ensure ",
    "to prevent ",
    "workaround for ",
    "bug in ",
    "race with ",
    "avoids ",
    "prevents ",
    "required for ",
    "needed because",
    " constraint",
    "invariant",
    "must ",
    "can't ",
    "cannot ",
    "won't ",
    "only ",
    "not safe",
    "thread-safe",
    "lock ordering",
    "atomic",
    "guaranteed",
    "safety:",
)

ALLOW_PREFIXES = (
    "todo",
    "fixme",
    "xxx",
    "note",
    "warning",
    "safety",
    "invariant",
    "why",
    "because",
    "spec",
    "hack",
    "n.b",
    "nb:",
    "perf",
    "security",
    "regex",
    "shellcheck",
    "eslint",
    "@ts-",
    "type:",
    "noqa",
    "pylint",
    "pyright",
    "mypy",
    "prettier",
    "flake8",
    "ruff",
    "allow(",
    "deny(",
    "#[",
    "//go:",
    "//nolint",
    "#![",
    "clang-format",
    "pragma",
    "biome",
    "vale",
    "codeql",
    "doxygen",
    "cppcheck",
    "@eslint-",
)


def is_directive_or_allowed(body: str) -> bool:
    s = body.lstrip()
    low = s.lower()
    for p in ALLOW_PREFIXES:
        if low.startswith(p):
            return True
    if s.startswith(("!", "/")):
        return True
    return False


def has_why_marker(body: str) -> bool:
    low = " " + body.lower() + " "
    return any(m in low for m in WHY_MARKERS)


def is_narrative_body(body: str) -> bool:
    s = body.strip()
    if not s:
        return False
    if is_directive_or_allowed(s):
        return False
    if has_why_marker(s):
        return False
    if len(s) > 80:
        return False
    for pat in NARRATIVE_RE:
        if pat.match(s):
            return True
    return False


TRIVIAL_DOCSTRING_RE = [
    re.compile(rf"^{NARRATIVE_VERBS}\b", re.IGNORECASE),
    re.compile(
        r"^(?:the|a|an|this)\s+(?:function|method|class|handler|helper|module)\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"^(?:represents?|holds?|contains?|stores?|describes?)\s+(?:a|an|the)?\s*\w+",
        re.IGNORECASE,
    ),
]


def is_trivial_docstring(body: str) -> bool:
    s = body.strip().strip('"').strip("'").strip()
    if not s:
        return False
    if has_why_marker(s):
        return False
    if len(s) > 120:
        return False
    for p in TRIVIAL_DOCSTRING_RE:
        if p.match(s):
            return True
    return False


DOC_LINE_PREFIXES = {"///", "//!"}

PURE_BANNER_RE = [
    re.compile(r"^[-=*#~─═━┄┅┉─]{2,}\s*$"),
    re.compile(r"^[-=*#~─═━┄┅┉─]{2,}.*[-=*#~─═━┄┅┉─]{2,}\s*$"),
]


def is_pure_banner(body: str) -> bool:
    s = body.strip()
    if not s:
        return False
    return any(p.match(s) for p in PURE_BANNER_RE)


def check_line_comments(lines, line_prefixes, lang):
    violations = []
    sorted_prefs = sorted(line_prefixes, key=len, reverse=True)

    def match_prefix(line):
        s = line.lstrip()
        for pref in sorted_prefs:
            if s.startswith(pref):
                return pref, s[len(pref) :]
        return None, None

    # Pure-banner lines in non-doc comments are always noise (CLAUDE.md
    # explicitly bans decorative separators). /// and //! are exempt because
    # rustdoc legitimately contains ASCII tables and diagrams inside
    # ```text``` code fences.
    for lineno, raw in enumerate(lines, 1):
        pref, body = match_prefix(raw)
        if pref is None or pref in DOC_LINE_PREFIXES:
            continue
        if is_pure_banner(body):
            violations.append((lineno, raw.rstrip(), "decorative banner comment"))

    n = len(lines)
    i = 0
    while i < n:
        raw = lines[i]
        pref, body = match_prefix(raw)
        if pref is None:
            i += 1
            continue

        block_start = i
        block_bodies = [body]
        j = i + 1
        # invariant: a "block" is a run of consecutive lines all sharing the
        # same comment prefix. Grouping prevents flagging the middle line of
        # a multi-line // or /// rustdoc that wraps a narrative verb across
        # lines. The block as a whole is what carries the WHY signal, not
        # any individual line in isolation.
        while j < n:
            njpref, njbody = match_prefix(lines[j])
            if njpref == pref:
                block_bodies.append(njbody)
                j += 1
            else:
                break

        first_body = block_bodies[0]
        if block_start == 0 and first_body.startswith("!"):
            i = j
            continue
        if is_directive_or_allowed(first_body):
            i = j
            continue

        block_text = " ".join(b.strip() for b in block_bodies).strip()

        # WHY marker anywhere in the block whitelists the entire block, so
        # multi-line rustdocs whose first line happens to start with a verb
        # ("Run the closure...") aren't flagged when later lines explain the
        # invariant or the safety reasoning.
        if has_why_marker(block_text):
            i = j
            continue

        if len(block_bodies) == 1:
            if is_narrative_body(first_body):
                violations.append(
                    (
                        block_start + 1,
                        lines[block_start].rstrip(),
                        "narrative line comment",
                    )
                )
        else:
            # Multi-line block with no WHY marker. If the combined prose is
            # short enough to be a trivial restate-the-code paragraph, flag
            # it; otherwise assume it's substantive documentation and allow.
            if len(block_text) <= 160 and is_narrative_body(block_text):
                violations.append(
                    (
                        block_start + 1,
                        lines[block_start].rstrip(),
                        "narrative line comment",
                    )
                )

        i = j
    return violations


def check_python_docstrings(content):
    violations = []
    pat = re.compile(r"^([ \t]*)(?:r|b)?(\"\"\"|\'\'\')(.*?)\2[ \t]*$", re.MULTILINE)
    for m in pat.finditer(content):
        body = m.group(3)
        if "\n" in body:
            continue
        if is_trivial_docstring(body):
            lineno = content[: m.start()].count("\n") + 1
            violations.append(
                (lineno, m.group(0).strip(), "trivial one-liner docstring")
            )
    return violations


def check_block_oneliners(content):
    violations = []
    pat = re.compile(r"/\*\*?\s*([^\n*][^\n]{0,200}?)\s*\*/")
    for m in pat.finditer(content):
        body = m.group(1)
        if is_trivial_docstring(body) or is_narrative_body(body):
            lineno = content[: m.start()].count("\n") + 1
            violations.append(
                (lineno, m.group(0).strip(), "trivial one-liner block comment")
            )
    return violations


def check_content(path, content):
    lang, line_prefixes, block = detect_lang(path)
    if not lang or not line_prefixes:
        return []

    lines = content.splitlines()
    violations = []
    violations.extend(check_line_comments(lines, line_prefixes, lang))

    if lang == "python":
        violations.extend(check_python_docstrings(content))

    if block and block[0] == "/*":
        violations.extend(check_block_oneliners(content))

    seen = set()
    unique = []
    for v in violations:
        if v[0] in seen:
            continue
        seen.add(v[0])
        unique.append(v)
    unique.sort(key=lambda x: x[0])
    return unique


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    if not isinstance(data, dict):
        sys.exit(0)
    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        sys.exit(0)
    # Claude Code uses "file_path"; Cursor Write uses "path"; StrReplace uses "path"
    file_path = tool_input.get("file_path") or tool_input.get("path")
    if not isinstance(file_path, str) or not file_path:
        sys.exit(0)

    # Claude Code Write/StrReplace: "new_string" or "content"
    # Cursor Write: "contents"; Cursor StrReplace: "new_string"
    content = (
        tool_input.get("new_string")
        or tool_input.get("contents")
        or tool_input.get("content")
    )
    if not isinstance(content, str) or not content:
        sys.exit(0)

    violations = check_content(file_path, content)
    if not violations:
        sys.exit(0)

    out = sys.stderr
    print(
        f"[hook:comment-guard] BLOCKED: unnecessary AI-style comments/docstrings in {file_path}",
        file=out,
    )
    print("", file=out)
    print(
        "HARD RULE (global): no narrative AI comments, no trivial one-liner docstrings.",
        file=out,
    )
    print(
        "Code should be self-documenting. Comments exist ONLY for non-obvious WHY:",
        file=out,
    )
    print(
        "hidden constraints, subtle invariants, workarounds for named bugs, surprising",
        file=out,
    )
    print(
        "behavior a reader would misunderstand. NEVER restate WHAT the code does.",
        file=out,
    )
    print(
        "NEVER 'used by X', 'added for Y', 'was: old', 'fix for bug', 'renamed from'.",
        file=out,
    )
    print(
        "That belongs in PR descriptions and git history, not the source file.",
        file=out,
    )
    print("", file=out)
    print("Violations:", file=out)
    for lineno, text, kind in violations[:15]:
        short = text if len(text) <= 140 else text[:137] + "..."
        print(f"  line {lineno} [{kind}]: {short}", file=out)
    print("", file=out)
    print(
        "Fix: delete these comments. If the code is genuinely complex, rewrite the",
        file=out,
    )
    print(
        "comment to explain WHY (with a 'because', 'to avoid', 'workaround for', or",
        file=out,
    )
    print("'invariant:' marker). Otherwise remove it and trust the code.", file=out)
    sys.exit(2)


if __name__ == "__main__":
    main()
