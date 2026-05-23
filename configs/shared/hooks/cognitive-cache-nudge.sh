#!/bin/bash
# Cross-agent hook that nudges the LLM toward cognitive-cache MCP when it
# has been grep-orienting in unfamiliar code without trying the tool.
# Two modes:
#   count: PreToolUse / beforeShellExecution / beforeMCPExecution. Tracks
#          grep-like shell calls per session; resets when cognitive-cache
#          fires. WHY: behavioral rules in CLAUDE.md decay with context
#          length, so a stateful nudge that fires exactly when the bad
#          pattern is happening outperforms more verbose prose at the top.
#   check: UserPromptSubmit / beforeSubmitPrompt. Reads the counter and
#          injects additionalContext if >= threshold and the repo is big
#          enough that grep-orientation is actually expensive.

set -euo pipefail

MODE="${1:-check}"
INPUT=$(cat 2>/dev/null || true)

CONVERSATION_ID=$(printf '%s' "$INPUT" | jq -r '.conversation_id // empty' 2>/dev/null || true)
SESSION_ID_CLAUDE=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)

if [ -n "$CONVERSATION_ID" ]; then
    AGENT="cursor"
    SESSION_ID="$CONVERSATION_ID"
    STATE_DIR="$HOME/.cursor/state/cognitive-cache"
elif [ -n "$SESSION_ID_CLAUDE" ]; then
    AGENT="claude"
    SESSION_ID="$SESSION_ID_CLAUDE"
    STATE_DIR="$HOME/.claude/state/cognitive-cache"
else
    exit 0
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true
COUNTER_FILE="$STATE_DIR/${SESSION_ID}.count"
THRESHOLD=3
SMALL_REPO_CUTOFF=50

read_counter() {
    local v
    v=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
    printf '%s' "$v"
}

write_counter() {
    printf '%s' "$1" > "$COUNTER_FILE"
}

repo_source_count() {
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
    find "$root" \
        \( -name node_modules -o -name .git -o -name dist -o -name build -o -name target -o -name .venv -o -name venv -o -name __pycache__ \) -prune -o \
        \( -name '*.py' -o -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \
           -o -name '*.go' -o -name '*.rs' -o -name '*.java' -o -name '*.rb' \
           -o -name '*.c' -o -name '*.cpp' -o -name '*.h' -o -name '*.hpp' \) \
        -type f -print 2>/dev/null | head -100 | wc -l | tr -d ' '
}

case "$MODE" in
    count)
        # tool_name field differs across agents: claude PreToolUse uses
        # tool_name; cursor uses tool. Try both, fall back to empty.
        TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // .tool // empty' 2>/dev/null || true)

        # Reset whenever cognitive-cache fires, regardless of which event
        # the harness wired this to. PreToolUse matcher already filters,
        # so this is the natural reset point.
        if [[ "$TOOL_NAME" == mcp__cognitive-cache__* ]]; then
            write_counter 0
            exit 0
        fi

        # Cursor's beforeMCPExecution carries server_name / tool_name in
        # a different shape. Cover both.
        MCP_SERVER=$(printf '%s' "$INPUT" | jq -r '.server_name // .mcp_server // empty' 2>/dev/null || true)
        if [[ "$MCP_SERVER" == "cognitive-cache" ]]; then
            write_counter 0
            exit 0
        fi

        # Only Bash / Shell tool calls count toward the grep threshold;
        # everything else is irrelevant signal.
        if [[ "$TOOL_NAME" != "Bash" && "$TOOL_NAME" != "Shell" ]]; then
            exit 0
        fi

        CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .command // empty' 2>/dev/null || true)
        # Match exploratory shell prefixes: standalone grep/rg/ack/find,
        # ls -R / ls -l, fd, tree. Allow leading pipe/and operators so
        # composed commands still count.
        if printf '%s' "$CMD" | grep -qE '(^|[;&|]|&&|\|\|)[[:space:]]*(grep|rg|ack|ag|fd|find|tree|ls[[:space:]]+-[RlA])'; then
            CURRENT=$(read_counter)
            write_counter "$((CURRENT + 1))"
        fi
        ;;

    check)
        COUNT=$(read_counter)

        if [ "$COUNT" -lt "$THRESHOLD" ]; then
            exit 0
        fi

        # Cheap repos do not benefit from the tool: grep is faster than
        # an MCP roundtrip on a tiny tree. Reset and bail rather than
        # spamming the nudge in trivial repos.
        FILES=$(repo_source_count)
        if [ "$FILES" -lt "$SMALL_REPO_CUTOFF" ]; then
            write_counter 0
            exit 0
        fi

        MSG="COGNITIVE-CACHE NUDGE: ${COUNT} exploratory shell calls (grep/find/rg) since the last select_context_tool call. If you are orienting in unfamiliar code, one MCP call usually replaces this loop. If you already know which files to read, ignore this and proceed."
        write_counter 0

        if [ "$AGENT" = "cursor" ]; then
            jq -n --arg msg "$MSG" '{additional_context: $msg}'
        else
            jq -n --arg msg "$MSG" \
              '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $msg}}'
        fi
        ;;
esac

exit 0
