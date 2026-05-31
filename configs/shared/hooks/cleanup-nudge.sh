#!/bin/bash
# Cross-agent prompt-submit hook: whisper a reminder to clean up scratch
# artifacts (temp docs like PLAN.md/HANDOVER.md, screenshots, *.tmp, debug
# dumps) the agent left untracked in the working tree. Relevant knowledge
# belongs in the wiki/devlog, not as loose files polluting the repo.
#
# Soft only: never blocks. Wired in Claude as UserPromptSubmit, in Cursor as
# beforeSubmitPrompt (additional_context: true). Fires at most every 5 turns
# and only when junk is actually present, so it stays quiet on clean trees.
set -euo pipefail

INPUT=$(cat)

CONVERSATION_ID=$(printf '%s' "$INPUT" | jq -r '.conversation_id // empty' 2>/dev/null || true)
SESSION_ID_CLAUDE=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)

if [ -n "$CONVERSATION_ID" ]; then
    AGENT="cursor"
    SESSION_ID="$CONVERSATION_ID"
    STATE_DIR="$HOME/.cursor/state/cleanup-nudge"
elif [ -n "$SESSION_ID_CLAUDE" ]; then
    AGENT="claude"
    SESSION_ID="$SESSION_ID_CLAUDE"
    STATE_DIR="$HOME/.claude/state/cleanup-nudge"
else
    exit 0
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# WHY: counter is per-session so concurrent sessions on one repo don't corrupt
# each other's turn count.
mkdir -p "$STATE_DIR" 2>/dev/null || true
MARKER="$STATE_DIR/${SESSION_ID}.count"

TURNS=$(cat "$MARKER" 2>/dev/null || echo 0)
[[ "$TURNS" =~ ^[0-9]+$ ]] || TURNS=0
TURNS=$((TURNS + 1))

if [ "$TURNS" -lt 5 ]; then
    echo "$TURNS" > "$MARKER"
    exit 0
fi
echo "0" > "$MARKER"

# Real project docs that must never be flagged even when untracked.
is_protected_doc() {
    case "$1" in
        readme.md|readme.txt|changelog.md|contributing.md|license|license.md|license.txt|\
        security.md|code_of_conduct.md|authors.md|maintainers.md|notice.md|\
        claude.md|agents.md|.scope.md) return 0 ;;
    esac
    return 1
}

is_junk() {
    local path="$1"
    local base lower
    base="${path##*/}"
    lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')

    is_protected_doc "$lower" && return 1

    # WHY: scratch docs and named dumps are only junk at the repo root, where
    # agents drop working artifacts. The same basename nested under a content,
    # docs, or vendored-plugin reference dir (e.g. configs/x/reference/product.md)
    # is legitimate, so name-based matching must not reach into subdirectories.
    local at_root=false
    case "$path" in */*) ;; *) at_root=true ;; esac

    if [ "$at_root" = true ]; then
        case "$lower" in
            plan.md|plans.md|handover.md|handoff.md|product.md|prd.md|notes.md|note.md|\
            scratch.md|summary.md|implementation.md|implementation_plan.md|implementation-plan.md|\
            changes.md|review.md|analysis.md|walkthrough.md|brainstorm.md|ideas.md|draft.md|\
            worklog.md|progress.md|status.md|report.md|findings.md|investigation.md|\
            todo.md|tasks.md|*.plan.md|*.notes.md|*.scratch.md|\
            out.txt|output.txt|debug.txt|dump.txt|scratch.*|tmp.*|debug.*)
                return 0 ;;
        esac
    fi

    # Temp files, editor leftovers, and logs are junk wherever they sit.
    case "$lower" in
        *.tmp|*.temp|*.bak|*.orig|*.rej|*.swp|*.swo|*~|*.log|nohup.out|core)
            return 0 ;;
    esac

    # Test screenshots and scratch dirs.
    case "$path" in
        screenshots/*|*/screenshots/*|screenshot/*|*/screenshot/*|\
        scratch/*|*/scratch/*|tmp/*|*/tmp/*|.scratch/*|__scratch__/*)
            return 0 ;;
    esac

    # Loose images at the repo root are almost always test captures; images
    # under src/assets/public/static/img/docs are legitimate and excluded.
    case "$path" in
        */*) ;;
        *.png|*.jpg|*.jpeg|*.gif|*.webp|*.bmp) return 0 ;;
    esac

    return 1
}

JUNK=()
while IFS= read -r f; do
    [ -z "$f" ] && continue
    if is_junk "$f"; then
        JUNK+=("$f")
    fi
done < <(git ls-files --others --exclude-standard 2>/dev/null || true)

[ "${#JUNK[@]}" -eq 0 ] && exit 0

SHOWN=()
for f in "${JUNK[@]}"; do
    [ "${#SHOWN[@]}" -ge 10 ] && break
    SHOWN+=("$f")
done
LIST=$(printf '%s, ' "${SHOWN[@]}")
LIST="${LIST%, }"
EXTRA=""
if [ "${#JUNK[@]}" -gt "${#SHOWN[@]}" ]; then
    EXTRA=" (and $(( ${#JUNK[@]} - ${#SHOWN[@]} )) more)"
fi

MSG="HYGIENE: untracked scratch artifacts are sitting in this repo: ${LIST}${EXTRA}. If any are leftover working files (temp docs, screenshots from testing, debug dumps, junk), delete them so they do not pollute the tree. Anything worth keeping belongs in the wiki or devlog, not as loose files in the project. Leave anything still in use."

if [ "$AGENT" = "cursor" ]; then
    jq -n --arg msg "$MSG" '{additional_context: $msg}'
else
    jq -n --arg msg "$MSG" \
      '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $msg}}'
fi

exit 0
