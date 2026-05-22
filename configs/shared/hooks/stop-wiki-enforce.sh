#!/bin/bash
# Cross-agent stop hook: when the agent tries to end a turn after substantial
# code work without having written any wiki pages, push back. Claude uses a
# block decision; Cursor uses a followup_message that auto-submits as the
# next user prompt.
set -uo pipefail

INPUT=$(cat)

CONVERSATION_ID=$(printf '%s' "$INPUT" | jq -r '.conversation_id // empty' 2>/dev/null || true)
SESSION_ID_CLAUDE=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)

if [ -n "$CONVERSATION_ID" ]; then
    AGENT="cursor"
    SESSION_ID="$CONVERSATION_ID"
    STATE_DIR="$HOME/.cursor/state/wiki-enforce"
elif [ -n "$SESSION_ID_CLAUDE" ]; then
    AGENT="claude"
    SESSION_ID="$SESSION_ID_CLAUDE"
    STATE_DIR="$HOME/.claude/state/wiki-enforce"
else
    exit 0
fi

# Claude provides a transcript path the hook can scan for tool calls. Cursor
# does not expose a transcript to stop hooks today, so on Cursor we fall
# back to a simpler heuristic: enforce once per session regardless of
# transcript signal.
if [ "$AGENT" = "claude" ]; then
    if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
        exit 0
    fi
fi

WIKI_VAULT="${WIKI_VAULT:-}"
[ -z "$WIKI_VAULT" ] && exit 0

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
PROJECT_SLUG="$(basename "$REPO_ROOT" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g')"

mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE_FILE="$STATE_DIR/${SESSION_ID}.count"
FIRED=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
if ! [[ "$FIRED" =~ ^[0-9]+$ ]]; then FIRED=0; fi

if [ "$FIRED" -ge 1 ]; then
    exit 0
fi

WIKI_PATH="${WIKI_VAULT}/wiki/projects/${PROJECT_SLUG}"

if [ "$AGENT" = "claude" ]; then
    CODE_EDITS=$(grep -o '"name": *"[^"]*"' "$TRANSCRIPT" 2>/dev/null | grep -cE '"(Write|Edit|Bash|NotebookEdit)"' || echo 0)
    if [ "$CODE_EDITS" -lt 3 ]; then
        exit 0
    fi

    WIKI_WRITES=$(grep -o "\"${WIKI_VAULT}[^\"]*\"" "$TRANSCRIPT" 2>/dev/null | wc -l || echo 0)
    if [ "$WIKI_WRITES" -gt 0 ]; then
        exit 0
    fi
fi

echo $((FIRED + 1)) > "$STATE_FILE"

if [ -d "$WIKI_PATH" ]; then
    WIKI_DIR_EXISTS="The project wiki directory exists at ${WIKI_PATH}/."
else
    WIKI_DIR_EXISTS="Create the project wiki directory at ${WIKI_PATH}/ (with devlog.md and subdirectories: decisions/, plans/, spikes/, concepts/)."
fi

MSG=$(cat <<EOF
WIKI MAINTENANCE — you just completed substantial work but wrote zero wiki pages this session.

${WIKI_DIR_EXISTS}

Write at minimum a devlog entry at ${WIKI_PATH}/devlog.md summarizing what was accomplished. If any plans, architecture decisions, or explorations happened, create the appropriate page (see the wiki-maintenance rule for formats).

After writing wiki pages, update ${WIKI_VAULT}/wiki/index.md and append to ${WIKI_VAULT}/wiki/log.md.
EOF
)

if [ "$AGENT" = "cursor" ]; then
    jq -n --arg msg "$MSG" '{followup_message: $msg}'
else
    jq -n --arg msg "$MSG" '{decision: "block", reason: $msg}'
fi
exit 0
