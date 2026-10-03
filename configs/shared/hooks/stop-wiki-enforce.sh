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

# A wiki page is recorded in the transcript differently depending on which
# channel wrote it, so all three signals are checked. A verdant-routed project
# denies native Write and confines mcp__verdant__write to the project root,
# which leaves bash heredocs as the only way to reach a vault outside it, and a
# page written that way carries no file_path field at all.
#
# The path must never be matched as bare text: wiki-nudge.sh and this hook's
# own block message both name it in prose, so a loose match would let the
# reminder satisfy the requirement it exists to enforce.
wiki_page_written() {
    local page="$1"
    grep -qF "\"${page}\"" "$TRANSCRIPT" 2>/dev/null && return 0
    grep -F "$page" "$TRANSCRIPT" 2>/dev/null | jq -e --arg p "$page" '
        .. | objects
        | select(.type? == "tool_use")
        | select((.name? // "") | ascii_downcase | contains("bash"))
        | (.input.command? // "")
        | select(contains($p))
    ' >/dev/null 2>&1 && return 0
    # A command that assembles the path from a variable never contains it
    # literally, so mtime against session start is the channel-independent
    # signal of last resort.
    [ -n "$SESSION_START" ] && [ -f "$page" ] \
        && [ -n "$(find "$page" -newermt "@${SESSION_START}" 2>/dev/null)" ] && return 0
    return 1
}

INPUT=$(cat)
AGENT=$("$HOOK_DIR/detect-agent.sh" <<< "$INPUT")
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.conversation_id // .session_id // empty' 2>/dev/null || true)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
[ -z "$SESSION_ID" ] && exit 0

if [ -n "${WIKI_ENFORCE_STATE_DIR:-}" ]; then
    STATE_DIR="$WIKI_ENFORCE_STATE_DIR"
elif [ "$AGENT" = "cursor" ]; then
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
    # `|| true`, not `|| echo 0`: grep -c already prints 0 on no match while
    # exiting 1, so under pipefail `|| echo 0` appended a second line and the
    # integer tests below silently failed, firing the hook on idle sessions.
    # The verdant tool names count too, because verdant-cached projects deny
    # native Write/Edit and route all mutations through the MCP equivalents.
    # Must filter on type=="tool_use", not just grep "name":"X" over the raw
    # file: a prompt_snapshot attachment embeds the full tool schema list, so
    # a bare text match counts every tool definition's name as an invocation
    # even when it was never called.
    CODE_EDITS=$(jq -c '.. | objects | select(.type? == "tool_use") | .name' "$TRANSCRIPT" 2>/dev/null | grep -cE '"(Write|Edit|NotebookEdit|mcp__verdant__(write|edit))"' 2>/dev/null || true)
    [[ "$CODE_EDITS" =~ ^[0-9]+$ ]] || CODE_EDITS=0
    if [ "$CODE_EDITS" -lt 3 ]; then
        exit 0
    fi

    # Anchors the mtime signal in wiki_page_written. `grep -m1` stops at the
    # first hit, so the whole transcript is never parsed just to find it.
    SESSION_START=""
    FIRST_TS=$(grep -m1 -o '"timestamp":"[^"]*"' "$TRANSCRIPT" 2>/dev/null | cut -d'"' -f4 || true)
    if [ -n "$FIRST_TS" ]; then
        SESSION_START=$(date -d "$FIRST_TS" +%s 2>/dev/null || true)
    fi
    [[ "$SESSION_START" =~ ^[0-9]+$ ]] || SESSION_START=""

    INDEX_PATH="${WIKI_VAULT}/wiki/index.md"
    DEVLOG_PATH="${WIKI_VAULT}/wiki/projects/${PROJECT_SLUG}/devlog.md"
    INDEX_WRITTEN=0
    DEVLOG_WRITTEN=0
    wiki_page_written "$INDEX_PATH" && INDEX_WRITTEN=1
    wiki_page_written "$DEVLOG_PATH" && DEVLOG_WRITTEN=1

    if [ "$INDEX_WRITTEN" -gt 0 ] && [ "$DEVLOG_WRITTEN" -gt 0 ]; then
        exit 0
    fi

    # Each line states the file's actual state, because a bare "missing" for a
    # file that exists sends the agent guessing at what the hook meant.
    if [ "$INDEX_WRITTEN" -eq 0 ]; then
        if [ ! -f "$INDEX_PATH" ]; then
            MISSING_PARTS+=("${INDEX_PATH} does not exist. Create it with a \"### ${PROJECT_SLUG}:\" entry.")
        elif ! grep -q "^### ${PROJECT_SLUG}:" "$INDEX_PATH" 2>/dev/null; then
            MISSING_PARTS+=("${INDEX_PATH} has no \"### ${PROJECT_SLUG}:\" entry. Add one.")
        else
            MISSING_PARTS+=("${INDEX_PATH} has a \"### ${PROJECT_SLUG}:\" entry but was not updated this session. Add lines for any pages written this session.")
        fi
    fi
    if [ "$DEVLOG_WRITTEN" -eq 0 ]; then
        if [ -f "$DEVLOG_PATH" ]; then
            MISSING_PARTS+=("${DEVLOG_PATH} exists but was not updated this session. Add an entry for this session's work.")
        else
            MISSING_PARTS+=("${DEVLOG_PATH} does not exist. Create it with an entry for this session's work.")
        fi
    fi
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
    MISSING_PARTS+=("No page under ${WIKI_PATH}/ was modified in the last 2 hours. Update ${WIKI_PATH}/devlog.md and ${WIKI_VAULT}/wiki/index.md.")
fi

# The FIRED guard is the only thing that stops this hook from re-firing on
# every stop; if the count cannot be persisted the block loop would be
# unbreakable from inside the session, so a lost nudge is the safer failure.
if ! echo $((FIRED + 1)) > "$STATE_FILE" 2>/dev/null; then
    exit 0
fi

if [ -d "$WIKI_PATH" ]; then
    WIKI_DIR_EXISTS="The project wiki directory exists at ${WIKI_PATH}/."
else
    WIKI_DIR_EXISTS="Create the project wiki directory at ${WIKI_PATH}/ (with devlog.md and subdirectories: decisions/, plans/, spikes/, concepts/)."
fi

MISSING_LIST="${MISSING_PARTS[*]:-wiki/index.md and devlog}"
if [ "${#MISSING_PARTS[@]}" -gt 0 ]; then
    MISSING_LIST=$(printf '  - %s\n' "${MISSING_PARTS[@]}")
fi

if [ -n "${CODE_EDITS:-}" ]; then
    WORK_SUMMARY="this session made ${CODE_EDITS} file edits (Write/Edit calls) and did not update the project wiki."
else
    WORK_SUMMARY="the project wiki was not updated in the last 2 hours."
fi

MSG=$(cat <<EOF
WIKI MAINTENANCE: ${WORK_SUMMARY}

${WIKI_DIR_EXISTS}

${MISSING_LIST}

If any plans, decisions, or explorations happened, also create the matching page and list it in the index.
EOF
)

# shellcheck source=log-block.sh
source "$HOOK_DIR/log-block.sh"
harness_log_block stop-wiki-enforce "$INPUT" "wiki not updated: $WORK_SUMMARY"

if [ "$AGENT" = "cursor" ]; then
    jq -n --arg msg "$MSG" '{followup_message: $msg}'
else
    jq -n --arg msg "$MSG" '{decision: "block", reason: $msg}'
fi
exit 0
