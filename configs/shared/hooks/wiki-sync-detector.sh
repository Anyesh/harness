#!/bin/bash
# sessionStart hook: detect .wiki-sync-pending and inject context telling
# the agent to run wiki sync on new graph nodes.

INPUT=$(cat 2>/dev/null || true)
CONVERSATION_ID=$(printf '%s' "$INPUT" | jq -r '.conversation_id // empty' 2>/dev/null || true)
if [ -n "$CONVERSATION_ID" ]; then
    AGENT="cursor"
else
    AGENT="claude"
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
PENDING_FILE="$REPO_ROOT/.wiki-sync-pending"

if [ ! -f "$PENDING_FILE" ]; then
    echo '{}'
    exit 0
fi

TIMESTAMP=$(grep "^timestamp:" "$PENDING_FILE" | cut -d' ' -f2-)
COMMIT=$(grep "^commit:" "$PENDING_FILE" | cut -d' ' -f2-)
MESSAGE=$(grep "^message:" "$PENDING_FILE" | cut -d' ' -f2-)
VAULT=$(grep "^vault:" "$PENDING_FILE" | cut -d' ' -f2-)
CHANGED_FILES=$(sed '1,/^---$/d' "$PENDING_FILE" | sed '/^---$/d')
FILE_COUNT=$(echo "$CHANGED_FILES" | grep -c . || echo 0)

MSG="WIKI SYNC PENDING: Commit ${COMMIT} (${MESSAGE}) changed ${FILE_COUNT} files at ${TIMESTAMP}. Graph was rebuilt via post-commit hook. Wiki vault at ${VAULT} needs pages updated to reflect new/changed graph nodes. Run: /wiki sync — this will diff graph.json against wiki index and create/update entity+concept pages for new nodes. After sync completes, delete ${PENDING_FILE}."

if [ "$AGENT" = "cursor" ]; then
    jq -n --arg msg "$MSG" '{additional_context: $msg}'
else
    jq -n --arg msg "$MSG" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $msg}}'
fi

exit 0
