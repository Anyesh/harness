#!/bin/bash
# UserPromptSubmit hook: nudge LLM to write wiki pages when it hasn't — because
# behavioral CLAUDE.md instructions get deprioritized when the LLM is deep in a task.
set -euo pipefail

WIKI_VAULT="${WIKI_VAULT:-}"
[ -z "$WIKI_VAULT" ] && exit 0

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // .conversation_id // "unknown"' 2>/dev/null || echo unknown)

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
PROJECT_SLUG="$(basename "$REPO_ROOT" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g')"

# WHY: counter must be per-session, not per-project in /tmp — concurrent
# sessions on the same repo would otherwise corrupt each other's turn count.
STATE_DIR="$HOME/.claude/state/wiki-nudge"
mkdir -p "$STATE_DIR" 2>/dev/null || true
MARKER="$STATE_DIR/${SESSION_ID}.count"
WIKI_DIR="${WIKI_VAULT}/wiki/projects/${PROJECT_SLUG}"

TURNS=$(cat "$MARKER" 2>/dev/null || echo 0)
[[ "$TURNS" =~ ^[0-9]+$ ]] || TURNS=0
TURNS=$((TURNS + 1))

if [ "$TURNS" -lt 5 ]; then
    echo "$TURNS" > "$MARKER"
    exit 0
fi

echo "0" > "$MARKER"

if [ -d "$WIKI_DIR" ]; then
    RECENT=$(find "$WIKI_DIR" -name "*.md" -mmin -10 2>/dev/null | head -1)
    if [ -n "$RECENT" ]; then
        exit 0
    fi
fi

MSG="WIKI: You are ${TURNS} turns into this session and have not written any wiki pages. Write a devlog entry at ${WIKI_VAULT}/wiki/projects/${PROJECT_SLUG}/devlog.md summarizing work so far. If you made plans, decisions, or ran spikes, create pages in the corresponding subdirectory. Do this now, before your next task response."

jq -n --arg msg "$MSG" \
  '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $msg}}'

exit 0
