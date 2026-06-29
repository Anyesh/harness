#!/usr/bin/env bash
# sessionStart hook: inject wiki context for current project.
# Loads 3 most recent devlog entries and a two-level index view:
# all-project headers (one line each) + full section for the current project.

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

INDEX_FILE="${WIKI_VAULT}/wiki/index.md"
if [[ ! -f "$INDEX_FILE" ]]; then
    emit_empty; exit 0
fi

PROJECT_ROOT="$(harness_repo_root "$INPUT")"
if harness_is_tooling_dir "$PROJECT_ROOT"; then
    emit_empty; exit 0
fi
PROJECT_SLUG="$(harness_project_slug "$PROJECT_ROOT")"
if [[ -z "$PROJECT_SLUG" ]]; then
    emit_empty; exit 0
fi

DEVLOG="${WIKI_VAULT}/wiki/projects/${PROJECT_SLUG}/devlog.md"

python3 - "$AGENT" "$PROJECT_SLUG" "$INDEX_FILE" "$DEVLOG" "$WIKI_VAULT" <<'PY'
import json, sys, os, re

agent, slug, index_file, devlog_file, wiki_vault = sys.argv[1:6]

index_ctx = ""
try:
    with open(index_file) as f:
        index_content = f.read()

    all_headers = re.findall(r'^### .+', index_content, re.MULTILINE)
    overview = '\n'.join(all_headers)

    sections = re.split(r'^(?=### )', index_content, flags=re.MULTILINE)
    project_section = next(
        (s.strip() for s in sections if re.match(rf'### {re.escape(slug)}[ \n]', s)),
        ''
    )

    if project_section:
        index_ctx = (
            f"Wiki index:\n"
            f"## All projects:\n{overview}\n\n"
            f"## {slug} detail:\n{project_section}"
        )
    else:
        index_ctx = (
            f"Wiki index:\n"
            f"## All projects:\n{overview}\n\n"
            f"(no index entry yet for {slug} — create one when you write wiki pages)"
        )
except Exception:
    index_ctx = ""

devlog_ctx = ""
if os.path.isfile(devlog_file):
    try:
        with open(devlog_file) as f:
            lines = f.readlines()

        heading_indices = [i for i, l in enumerate(lines) if l.startswith('## ')]
        if heading_indices:
            # Devlog is newest-first; entries 1-3 live before the 4th heading.
            end = heading_indices[3] if len(heading_indices) > 3 else len(lines)
            excerpt = ''.join(lines[:end])[:6000]
            devlog_ctx = (
                f"Recent devlog for {slug} (3 most recent entries — "
                f"use Read tool for older entries if needed):\n{excerpt}\n\n"
            )
    except Exception:
        pass

header = (
    f"WIKI: project={slug} vault={wiki_vault}\n"
    "Proactively maintain the wiki per the wiki-maintenance rule. "
    "Write plans, decisions, spikes, and devlog entries as you work. "
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
