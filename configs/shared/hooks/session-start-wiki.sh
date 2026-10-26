#!/usr/bin/env bash
# sessionStart hook: inject wiki context for current project.
# Loads the 3 most recent devlog entries, the project's own index.md and the
# names of the other projects in the same vault.

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=load-harness-env.sh
source "$HOOK_DIR/load-harness-env.sh"
# shellcheck source=harness-project.sh
source "$HOOK_DIR/harness-project.sh"
load_wiki_vault

INPUT=$(cat 2>/dev/null || true)
AGENT=$("$HOOK_DIR/detect-agent.sh" <<< "$INPUT")

emit_empty() {
    echo '{}'
}

if [[ -z "$WIKI_VAULT" ]]; then
    emit_empty; exit 0
fi

PROJECT_ROOT="$(harness_repo_root "$INPUT")"
if harness_is_tooling_dir "$PROJECT_ROOT"; then
    emit_empty; exit 0
fi
PROJECT_SLUG="$(harness_wiki_slug "$PROJECT_ROOT")"
if [[ -z "$PROJECT_SLUG" ]]; then
    emit_empty; exit 0
fi
WIKI_VAULT="$(harness_wiki_vault_for "$PROJECT_SLUG")"

if [[ ! -d "$WIKI_VAULT/wiki" ]]; then
    emit_empty; exit 0
fi
bash "$HOOK_DIR/wiki-index-build.sh" "$WIKI_VAULT" --if-changed

python3 - "$AGENT" "$PROJECT_SLUG" "$WIKI_VAULT" <<'PY'
import json, sys, os

agent, slug, wiki_vault = sys.argv[1:4]
projects_dir = os.path.join(wiki_vault, "wiki", "projects")
project_index = os.path.join(projects_dir, slug, "index.md")
devlog_file = os.path.join(projects_dir, slug, "devlog.md")

# Claude Code spills additionalContext over 10,000 chars to a file and injects only a 2 KB
# preview, so each part gets its own budget and the total stays below that cap.
OVERVIEW_BUDGET = 1200
DETAIL_BUDGET = 2500
DEVLOG_BUDGET = 4500
LINE_BUDGET = 300


def clip_line(line, limit=LINE_BUDGET):
    return line if len(line) <= limit else line[:limit].rstrip() + "..."


def fit_lines(text, budget, pointer):
    kept, used = [], 0
    lines = [clip_line(l) for l in text.splitlines()]
    for i, line in enumerate(lines):
        if used + len(line) + 1 > budget and kept:
            kept.append(f"... truncated, {len(lines) - i} more lines ({pointer})")
            break
        kept.append(line)
        used += len(line) + 1
    return "\n".join(kept)


def strip_frontmatter(text):
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end >= 0:
            return text[end + 4:].lstrip("\n")
    return text


try:
    names = sorted(
        n for n in os.listdir(projects_dir)
        if not n.startswith(".") and os.path.isdir(os.path.join(projects_dir, n))
    )
except OSError:
    names = []
overview, used = [], 0
for i, name in enumerate(names):
    if used + len(name) + 2 > OVERVIEW_BUDGET:
        overview.append(f"... +{len(names) - i} more (see {projects_dir})")
        break
    overview.append(name)
    used += len(name) + 2
overview = ', '.join(overview)

try:
    with open(project_index, encoding="utf-8", errors="replace") as f:
        detail = fit_lines(strip_frontmatter(f.read()).strip(), DETAIL_BUDGET, f"see {project_index}")
    index_ctx = (
        f"Wiki index:\n"
        f"## All projects:\n{overview}\n\n"
        f"## {slug} detail:\n{detail}"
    )
except OSError:
    index_ctx = (
        f"Wiki index:\n"
        f"## All projects:\n{overview}\n\n"
        f"(no project index yet for {slug}: create {project_index} when you write wiki pages)"
    )

devlog_ctx = ""
if os.path.isfile(devlog_file):
    try:
        with open(devlog_file, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()

        heading_indices = [i for i, l in enumerate(lines) if l.startswith('## ')]
        if heading_indices:
            # Devlog is newest-first; entries 1-3 live before the 4th heading.
            starts = heading_indices[:4]
            bounds = starts + [len(lines)] if len(starts) < 4 else starts
            entries = [
                ''.join(lines[bounds[i]:bounds[i + 1]]).rstrip('\n')
                for i in range(len(bounds) - 1)
            ]
            kept, used = [], 0
            for entry in entries:
                if kept and used + len(entry) + 2 > DEVLOG_BUDGET:
                    break
                kept.append(entry)
                used += len(entry) + 2
            excerpt = '\n\n'.join(kept)
            if len(kept) == 1 and len(excerpt) > DEVLOG_BUDGET:
                excerpt = fit_lines(excerpt, DEVLOG_BUDGET, f"see {devlog_file}")
            elif len(kept) < len(entries) or len(heading_indices) > len(kept):
                excerpt += f"\n... older entries in {devlog_file}"
            devlog_ctx = (
                f"Recent devlog for {slug} (newest entries first, up to 3; "
                f"use Read tool for older entries if needed):\n{excerpt}\n\n"
            )
    except OSError:
        pass

header = (
    f"WIKI: project={slug} vault={wiki_vault}\n"
    "Proactively maintain the wiki per the wiki-maintenance rule, writing every page "
    "under the vault named on this WIKI line. "
    "Write plans, decisions, spikes, and devlog entries as you work, and list new pages in "
    f"{project_index} (never edit wiki/index.md, which is generated). "
    "Use /wiki for full operations (ingest, query, lint).\n\n"
)

msg = header + devlog_ctx + index_ctx

if agent == "cursor":
    print(json.dumps({"additional_context": msg}))
else:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": msg
        }
    }))
PY
