#!/bin/bash
# Cross-agent prompt-submit hook: nudge the LLM to write wiki pages when it
# hasn't, because behavioral instructions get deprioritized when the LLM is
# deep in a task.
#
# Wired in Claude as UserPromptSubmit, in Cursor as beforeSubmitPrompt.
# Emits additional_context JSON (Cursor) or hookSpecificOutput (Claude).
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=load-harness-env.sh
source "$HOOK_DIR/load-harness-env.sh"
# shellcheck source=harness-project.sh
source "$HOOK_DIR/harness-project.sh"
load_wiki_vault
[ -z "${WIKI_VAULT:-}" ] && exit 0

INPUT=$(cat)
AGENT=$("$HOOK_DIR/detect-agent.sh" <<< "$INPUT")

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.conversation_id // .session_id // empty' 2>/dev/null || true)
[ -z "$SESSION_ID" ] && exit 0

if [ "$AGENT" = "cursor" ]; then
    STATE_DIR="$HOME/.cursor/state/wiki-nudge"
else
    STATE_DIR="$HOME/.claude/state/wiki-nudge"
fi

REPO_ROOT="$(harness_repo_root "$INPUT")"
harness_is_tooling_dir "$REPO_ROOT" && exit 0
PROJECT_SLUG="$(harness_project_slug "$REPO_ROOT")"
[[ -z "$PROJECT_SLUG" ]] && exit 0

# WHY: counter must be per-session, not per-project in /tmp — concurrent
# sessions on the same repo would otherwise corrupt each other's turn count.
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

MSG="WIKI: You are ${TURNS} turns into this session and have not written any wiki pages. Write a devlog entry at ${WIKI_VAULT}/wiki/projects/${PROJECT_SLUG}/devlog.md summarizing work so far. If you made plans, decisions, or ran spikes, create pages in the corresponding subdirectory. Then update ${WIKI_VAULT}/wiki/index.md — this is mandatory, every session must update it. Do this now, before your next task response."

if [ "$AGENT" = "cursor" ]; then
    jq -n --arg msg "$MSG" '{additional_context: $msg}'
else
    jq -n --arg msg "$MSG" \
      '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $msg}}'
fi

exit 0
