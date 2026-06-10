#!/usr/bin/env bash
# sessionStart hook: inject wiki context for current project.
# Agent-aware: emits Claude's hookSpecificOutput.additionalContext shape
# under SessionStart, or Cursor's additional_context shape.

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=load-harness-env.sh
source "$HOOK_DIR/load-harness-env.sh"
# shellcheck source=harness-project.sh
source "$HOOK_DIR/harness-project.sh"
load_wiki_vault

INPUT=$(cat 2>/dev/null || true)
AGENT=$("$HOOK_DIR/detect-agent.sh" <<< "$INPUT")

emit_empty() {
    if [ "$AGENT" = "cursor" ]; then
        echo '{}'
    else
        echo '{}'
    fi
}

if [[ -z "$WIKI_VAULT" ]]; then
    emit_empty
    exit 0
fi

INDEX_FILE="${WIKI_VAULT}/wiki/index.md"
if [[ ! -f "$INDEX_FILE" ]]; then
    emit_empty
    exit 0
fi

PROJECT_ROOT="$(harness_repo_root "$INPUT")"
if harness_is_tooling_dir "$PROJECT_ROOT"; then
    emit_empty
    exit 0
fi
PROJECT_SLUG="$(harness_project_slug "$PROJECT_ROOT")"
if [[ -z "$PROJECT_SLUG" ]]; then
    emit_empty
    exit 0
fi

CONTEXT=""
PROJECT_DIR="${WIKI_VAULT}/wiki/projects/${PROJECT_SLUG}"
if [[ -d "$PROJECT_DIR" ]]; then
    DEVLOG="${PROJECT_DIR}/devlog.md"
    if [[ -f "$DEVLOG" ]]; then
        RECENT=$(grep -n "^## " "$DEVLOG" | tail -5 | head -1 | cut -d: -f1)
        if [[ -n "$RECENT" ]]; then
            CONTEXT="Recent devlog for ${PROJECT_SLUG}:\n$(tail -n +"$RECENT" "$DEVLOG" | head -60)\n\n"
        fi
    fi
fi

INDEX_CONTENT=$(head -c 3000 "$INDEX_FILE")
CONTEXT="${CONTEXT}Wiki index:\n${INDEX_CONTENT}"

MSG_HEADER="WIKI: project=${PROJECT_SLUG} vault=${WIKI_VAULT}
Proactively maintain the wiki per the wiki-maintenance rule. Write plans, decisions, spikes, and devlog entries as you work. Use /wiki for full operations (ingest, query, lint).

"

python3 - "$AGENT" <<PY
import json, sys
agent = sys.argv[1]
msg = """${MSG_HEADER}""" + """${CONTEXT}"""
if agent == "cursor":
    print(json.dumps({"additional_context": msg}))
else:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": msg}}))
PY
