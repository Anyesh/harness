#!/bin/bash
# Prompt-submit hook: soft reminder when .scope.md is missing/stale during
# long conversations that look like feature work. Fires after 10+ turns.
# Wired in Claude as UserPromptSubmit, in Cursor as beforeSubmitPrompt
# (with additional_context: true).

set -euo pipefail

INPUT=$(cat 2>/dev/null || true)
CONVERSATION_ID=$(printf '%s' "$INPUT" | jq -r '.conversation_id // empty' 2>/dev/null || true)
if [ -n "$CONVERSATION_ID" ]; then
    AGENT="cursor"
else
    AGENT="claude"
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
SCOPE_FILE="$REPO_ROOT/.scope.md"
TURN_MARKER="$REPO_ROOT/.scope-turn-count"

if [ ! -f "$TURN_MARKER" ]; then
    echo "1" > "$TURN_MARKER"
    exit 0
fi

TURNS=$(cat "$TURN_MARKER")
TURNS=$((TURNS + 1))
echo "$TURNS" > "$TURN_MARKER"

if [ "$TURNS" -lt 10 ]; then
    exit 0
fi

if [ -f "$SCOPE_FILE" ]; then
    SCOPE_AGE_SECONDS=$(( $(date +%s) - $(stat -c %Y "$SCOPE_FILE" 2>/dev/null || stat -f %m "$SCOPE_FILE" 2>/dev/null || echo 0) ))
    if [ "$SCOPE_AGE_SECONDS" -lt 7200 ]; then
        exit 0
    fi
fi

MSG="SCOPE CHECK (turn ${TURNS}): No current .scope.md found. If you are doing feature work or multi-file changes, answer the Three Questions before continuing: (1) Context — where are specs/plans/wiki? (2) Definition of done — what declares this complete? (3) Feedback loop — how are you validating? Write answers to .scope.md. If this is a quick fix or config change, ignore this reminder."

if [ "$AGENT" = "cursor" ]; then
    jq -n --arg msg "$MSG" '{additional_context: $msg}'
else
    jq -n --arg msg "$MSG" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $msg}}'
fi

exit 0
