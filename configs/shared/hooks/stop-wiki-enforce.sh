#!/bin/bash
# Cross-agent stop hook: when the agent tries to end a turn after substantial
# code work without having written any wiki pages, push back. Claude uses a
# block decision; Cursor uses a followup_message that auto-submits as the
# next user prompt.
set -uo pipefail

[ "${HARNESS_UNATTENDED:-}" = "1" ] && exit 0

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
WRITE_TOOL='^(Write|Edit|MultiEdit|NotebookEdit|mcp__verdant__(write|edit))$'

written_paths() {
    jq -r --arg re "$WRITE_TOOL" '
        .. | objects
        | select(.type? == "tool_use")
        | select((.name? // "") | test($re))
        | .input.file_path? // .input.notebook_path? // empty
    ' "$TRANSCRIPT" 2>/dev/null
}

wiki_page_written() {
    local page="$1"
    grep -qF "\"${page}\"" "$TRANSCRIPT" 2>/dev/null && written_paths | grep -qxF "$page" && return 0
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

[ -z "${WIKI_VAULT:-}" ] && exit 0

REPO_ROOT="$(harness_repo_root "$INPUT")"
harness_is_tooling_dir "$REPO_ROOT" && exit 0
PROJECT_SLUG="$(harness_wiki_slug "$REPO_ROOT")"
[[ -z "$PROJECT_SLUG" ]] && exit 0
WIKI_VAULT="$(harness_wiki_vault_for "$PROJECT_SLUG")"

bash "$HOOK_DIR/wiki-index-build.sh" "$WIKI_VAULT" --if-changed

# The state file holds the parts already blocked on ("devlog", "index"), so
# each blocks once per session; a bare number is a pre-upgrade counter.
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE_FILE="$STATE_DIR/${SESSION_ID}.count"
FIRED=$(cat "$STATE_FILE" 2>/dev/null || true)
[[ "$FIRED" =~ ^[0-9]+$ ]] && [ "$FIRED" -ge 1 ] && exit 0
[[ "$FIRED" =~ ^[0-9]*$ ]] && FIRED=""

WIKI_PATH="${WIKI_VAULT}/wiki/projects/${PROJECT_SLUG}"
PROJECT_INDEX="${WIKI_PATH}/index.md"
DEVLOG_PATH="${WIKI_PATH}/devlog.md"
MISSING_PARTS=()
MISSING_KEYS=()

part_due() {
    [[ " $FIRED " != *" $1 "* ]]
}

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
    CODE_EDITS=$(jq -r '.. | objects | select(.type? == "tool_use") | .name // empty' "$TRANSCRIPT" 2>/dev/null | grep -cE "$WRITE_TOOL" 2>/dev/null || true)
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

    # Each line states the file's actual state, because a bare "missing" for a
    # file that exists sends the agent guessing at what the hook meant.
    if part_due devlog && ! wiki_page_written "$DEVLOG_PATH"; then
        MISSING_KEYS+=(devlog)
        if [ -f "$DEVLOG_PATH" ]; then
            MISSING_PARTS+=("${DEVLOG_PATH} exists but was not updated this session. Add an entry for this session's work.")
        else
            MISSING_PARTS+=("${DEVLOG_PATH} does not exist. Create it with an entry for this session's work.")
        fi
    fi

    if part_due index && ! wiki_page_written "$PROJECT_INDEX"; then
        CHANGED=$( {
            written_paths
            [ -n "$SESSION_START" ] && [ -d "$WIKI_PATH" ] \
                && find "$WIKI_PATH" -name '*.md' -newermt "@${SESSION_START}" 2>/dev/null
        } | grep -F "${WIKI_PATH}/" | grep -E '\.md$' \
            | grep -vE '/(devlog|index)\.md$' | sed "s|^${WIKI_PATH}/||" | sort -u | head -5 | paste -sd, - || true)
        if [ -n "$CHANGED" ]; then
            MISSING_KEYS+=(index)
            MISSING_PARTS+=("${PROJECT_INDEX} does not list the pages written this session (${CHANGED//,/, }). Add one line per page, with a link relative to that folder and a short description.")
        fi
    fi

    [ "${#MISSING_PARTS[@]}" -eq 0 ] && exit 0
else
    # Cursor never passes transcript_path, so wiki mtime is its only signal.
    # Claude subagents also arrive without one, and with no work signal an idle
    # one-turn stop looks the same as a real session, so they are skipped.
    [ "$AGENT" != "cursor" ] && exit 0
    part_due devlog || exit 0
    if [ -d "$WIKI_PATH" ]; then
        RECENT=$(find "$WIKI_PATH" -name "*.md" -mmin -120 2>/dev/null | head -1)
        [ -n "$RECENT" ] && exit 0
    fi
    MISSING_KEYS+=(devlog)
    MISSING_PARTS+=("No page under ${WIKI_PATH}/ was modified in the last 2 hours. Add an entry to ${DEVLOG_PATH}, and list any new page in ${PROJECT_INDEX}.")
fi

# The fired parts are the only thing that stops this hook from re-firing on
# every stop; if they cannot be persisted the block loop would be unbreakable
# from inside the session, so a lost nudge is the safer failure.
if ! echo "${FIRED:+$FIRED }${MISSING_KEYS[*]}" > "$STATE_FILE" 2>/dev/null; then
    exit 0
fi

if [ -d "$WIKI_PATH" ]; then
    WIKI_DIR_EXISTS="The project wiki directory exists at ${WIKI_PATH}/."
else
    WIKI_DIR_EXISTS="Create the project wiki directory at ${WIKI_PATH}/ (with devlog.md and subdirectories: decisions/, plans/, spikes/, concepts/)."
fi

MISSING_LIST=$(printf '  - %s\n' "${MISSING_PARTS[@]}")

if [ "${MISSING_KEYS[*]}" == "index" ]; then
    WORK_SUMMARY="this session wrote project wiki pages that its index.md does not list yet."
elif [ -n "${CODE_EDITS:-}" ]; then
    WORK_SUMMARY="this session made ${CODE_EDITS} file edits (Write/Edit calls) and did not update the project wiki."
else
    WORK_SUMMARY="the project wiki was not updated in the last 2 hours."
fi

MSG=$(cat <<EOF
WIKI MAINTENANCE: ${WORK_SUMMARY}

${WIKI_DIR_EXISTS}

${MISSING_LIST}

If any plans, decisions, or explorations happened, also create the matching page under ${WIKI_PATH}/ and list it in ${PROJECT_INDEX}.
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
