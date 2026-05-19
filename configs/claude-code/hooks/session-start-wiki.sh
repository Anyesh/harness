#!/usr/bin/env bash
# SessionStart hook: inject wiki context for current project

WIKI_VAULT="${WIKI_VAULT:-}"

if [[ -z "$WIKI_VAULT" ]]; then
    echo '{}'
    exit 0
fi

INDEX_FILE="${WIKI_VAULT}/wiki/index.md"
if [[ ! -f "$INDEX_FILE" ]]; then
    echo '{}'
    exit 0
fi

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
PROJECT_SLUG="$(basename "$PROJECT_ROOT" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g')"

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

python3 -c "
import json, sys
content = sys.stdin.read()
msg = 'WIKI: project=${PROJECT_SLUG} vault=${WIKI_VAULT}\nProactively maintain the wiki per CLAUDE.md instructions. Write plans, decisions, spikes, and devlog entries as you work. Use /wiki for full operations (ingest, query, lint).\n\n' + content
print(json.dumps({'hookSpecificOutput': {'hookEventName': 'SessionStart', 'additionalContext': msg}}))
" <<< "$CONTEXT"
