#!/bin/bash
# Cross-agent stop hook: when the agent tries to end a turn after substantial
# code work without having written any wiki pages, push back. Claude uses a
# block decision; Cursor uses a followup_message that auto-submits as the
# next user prompt.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=load-harness-env.sh
source "$HOOK_DIR/load-harness-env.sh"
# shellcheck source=harness-project.sh
source "$HOOK_DIR/harness-project.sh"
load_wiki_vault

INPUT=$(cat)
AGENT=$("$HOOK_DIR/detect-agent.sh" <<< "$INPUT")
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.conversation_id // .session_id // empty' 2>/dev/null || true)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
[ -z "$SESSION_ID" ] && exit 0

if [ "$AGENT" = "cursor" ]; then
    STATE_DIR="$HOME/.cursor/state/wiki-enforce"
else
    STATE_DIR="$HOME/.claude/state/wiki-enforce"
fi

WIKI_VAULT="${WIKI_VAULT:-}"
[ -z "$WIKI_VAULT" ] && exit 0

REPO_ROOT="$(harness_repo_root "$INPUT")"
harness_is_tooling_dir "$REPO_ROOT" && exit 0
PROJECT_SLUG="$(harness_project_slug "$REPO_ROOT")"
[[ -z "$PROJECT_SLUG" ]] && exit 0

mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE_FILE="$STATE_DIR/${SESSION_ID}.count"
FIRED=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
if ! [[ "$FIRED" =~ ^[0-9]+$ ]]; then FIRED=0; fi

if [ "$FIRED" -ge 1 ]; then
    exit 0
fi

WIKI_PATH="${WIKI_VAULT}/wiki/projects/${PROJECT_SLUG}"
MISSING_PARTS=()

if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    # Transcript available — use it to count actual file mutations precisely.
    # Gating on transcript presence (not agent name) avoids misdetection when
    # hook_event_name casing causes detect-agent.sh to return the wrong value.
    CODE_EDITS=$(grep -o '"name": *"[^"]*"' "$TRANSCRIPT" 2>/dev/null | grep -cE '"(Write|Edit|NotebookEdit)"' || echo 0)
    if [ "$CODE_EDITS" -lt 3 ]; then
        exit 0
    fi

    INDEX_WRITTEN=$(grep -c "\"${WIKI_VAULT}/wiki/index\.md\"" "$TRANSCRIPT" 2>/dev/null || echo 0)
    DEVLOG_PATH="${WIKI_VAULT}/wiki/projects/${PROJECT_SLUG}/devlog.md"
    DEVLOG_WRITTEN=$(grep -c "\"${DEVLOG_PATH}\"" "$TRANSCRIPT" 2>/dev/null || echo 0)

    if [ "$INDEX_WRITTEN" -gt 0 ] && [ "$DEVLOG_WRITTEN" -gt 0 ]; then
        exit 0
    fi

    [ "$INDEX_WRITTEN" -eq 0 ] && MISSING_PARTS+=("wiki/index.md (mandatory — no exceptions, every session that touches a project must update it)")
    [ "$DEVLOG_WRITTEN" -eq 0 ] && MISSING_PARTS+=("${DEVLOG_PATH} (devlog entry for this session's work)")
else
    # No transcript. Only Cursor can be reliably evaluated here via wiki mtime,
    # because Cursor never passes transcript_path. Claude subagents also arrive
    # without a transcript_path, but without a work signal there is no way to
    # distinguish a real session from an idle one-turn stop — skip to avoid
    # false positives.
    [ "$AGENT" != "cursor" ] && exit 0
    if [ -d "$WIKI_PATH" ]; then
        RECENT=$(find "$WIKI_PATH" -name "*.md" -mmin -120 2>/dev/null | head -1)
        [ -n "$RECENT" ] && exit 0
    fi
    MISSING_PARTS+=("wiki/index.md and project devlog (write both before finishing)")
fi

echo $((FIRED + 1)) > "$STATE_FILE"

if [ -d "$WIKI_PATH" ]; then
    WIKI_DIR_EXISTS="The project wiki directory exists at ${WIKI_PATH}/."
else
    WIKI_DIR_EXISTS="Create the project wiki directory at ${WIKI_PATH}/ (with devlog.md and subdirectories: decisions/, plans/, spikes/, concepts/)."
fi

MISSING_LIST="${MISSING_PARTS[*]:-wiki/index.md and devlog}"
if [ "${#MISSING_PARTS[@]}" -gt 0 ]; then
    MISSING_LIST=$(printf '  - %s\n' "${MISSING_PARTS[@]}")
fi

MSG=$(cat <<EOF
WIKI MAINTENANCE — substantial work this session but required wiki files were not written.

${WIKI_DIR_EXISTS}

Missing:
${MISSING_LIST}

Write a devlog entry at ${WIKI_PATH}/devlog.md summarizing what was accomplished. If any plans, decisions, or explorations happened, create the appropriate page. Then update ${WIKI_VAULT}/wiki/index.md.

Both are mandatory. Do not stop without completing them.
EOF
)

if [ "$AGENT" = "cursor" ]; then
    jq -n --arg msg "$MSG" '{followup_message: $msg}'
else
    jq -n --arg msg "$MSG" '{decision: "block", reason: $msg}'
fi
exit 0
