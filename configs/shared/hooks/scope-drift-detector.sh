#!/bin/bash
# Prompt-submit hook: soft reminder when .scope.md is missing/stale during
# long conversations that look like feature work. Fires every 10th turn of a
# session, starting at turn 10.
# Wired in Claude as UserPromptSubmit, in Cursor as beforeSubmitPrompt.
# Emits additional_context JSON on Cursor, hookSpecificOutput on Claude.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=harness-project.sh
source "$HOOK_DIR/harness-project.sh"
INPUT=$(cat 2>/dev/null || true)
AGENT=$("$HOOK_DIR/detect-agent.sh" <<< "$INPUT")

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.conversation_id // .session_id // empty' 2>/dev/null || true)
[ -z "$SESSION_ID" ] && exit 0

REPO_ROOT="$(harness_repo_root "$INPUT")"
harness_is_tooling_dir "$REPO_ROOT" && exit 0
SCOPE_FILE="$REPO_ROOT/.scope.md"

# Earlier versions kept a lifetime counter in the repo root; it never reset
# across sessions, so remove it wherever it still lingers.
rm -f "$REPO_ROOT/.scope-turn-count" 2>/dev/null || true

if [ -n "${SCOPE_DRIFT_STATE_DIR:-}" ]; then
    STATE_DIR="$SCOPE_DRIFT_STATE_DIR"
elif [ "$AGENT" = "cursor" ]; then
    STATE_DIR="$HOME/.cursor/state/scope-drift"
else
    STATE_DIR="$HOME/.claude/state/scope-drift"
fi

# WHY: counter is per-session so it resets between conversations and
# concurrent sessions on one repo don't corrupt each other's turn count.
mkdir -p "$STATE_DIR" 2>/dev/null || true
MARKER="$STATE_DIR/${SESSION_ID}.count"

TURNS=$(cat "$MARKER" 2>/dev/null || echo 0)
[[ "$TURNS" =~ ^[0-9]+$ ]] || TURNS=0
TURNS=$((TURNS + 1))
echo "$TURNS" > "$MARKER"

if [ "$TURNS" -lt 10 ] || [ $((TURNS % 10)) -ne 0 ]; then
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
