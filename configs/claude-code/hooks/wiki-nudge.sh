#!/bin/bash
# UserPromptSubmit hook: nudge LLM to write wiki pages when it hasn't — because
# behavioral CLAUDE.md instructions get deprioritized when the LLM is deep in a task.
set -euo pipefail

WIKI_VAULT="${WIKI_VAULT:-}"
[ -z "$WIKI_VAULT" ] && exit 0

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
PROJECT_SLUG="$(basename "$REPO_ROOT" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g')"
MARKER="/tmp/.wiki-nudge-${PROJECT_SLUG}"
WIKI_DIR="${WIKI_VAULT}/wiki/projects/${PROJECT_SLUG}"

if [ ! -f "$MARKER" ]; then
    echo "1" > "$MARKER"
    exit 0
fi

TURNS=$(cat "$MARKER" 2>/dev/null || echo "1")
TURNS=$((TURNS + 1))

if [ "$TURNS" -lt 5 ]; then
    echo "$TURNS" > "$MARKER"
    exit 0
fi

echo "1" > "$MARKER"

if [ -d "$WIKI_DIR" ]; then
    RECENT=$(find "$WIKI_DIR" -name "*.md" -mmin -10 2>/dev/null | head -1)
    if [ -n "$RECENT" ]; then
        exit 0
    fi
fi

cat <<EOF
{
  "message": "WIKI: You are ${TURNS} turns in and have not written any wiki pages. Write a devlog entry at ${WIKI_VAULT}/wiki/projects/${PROJECT_SLUG}/devlog.md summarizing work so far. If you made plans, decisions, or ran spikes, create pages in the corresponding subdirectory. Do this now, before your next task response."
}
EOF

exit 0
