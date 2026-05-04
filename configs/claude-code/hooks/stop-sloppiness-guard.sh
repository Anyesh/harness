#!/bin/bash
# Stop hook: detect sloppy shortcut-seeking language in the last assistant turn.
# On detection, block Stop and feed a strong correction back into Claude's context.
# Loop-cap per session so we never get stuck in an infinite re-enter.

set -uo pipefail

INPUT=$(cat)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
# Claude Code uses session_id; Cursor uses conversation_id in common fields
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // .conversation_id // "unknown"' 2>/dev/null)
HOOK_EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
    exit 0
fi

STATE_DIR="$HOME/.claude/state/sloppiness"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE_FILE="$STATE_DIR/${SESSION_ID}.count"
COUNT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)

if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
    COUNT=0
fi

if [ "$COUNT" -ge 3 ]; then
    exit 0
fi

LAST_ASSISTANT_LINE=$(tail -n 2000 "$TRANSCRIPT" 2>/dev/null \
    | grep '"type":"assistant"' \
    | tail -n 1)

if [ -z "$LAST_ASSISTANT_LINE" ]; then
    exit 0
fi

LAST_TEXT=$(printf '%s' "$LAST_ASSISTANT_LINE" \
    | jq -rc '.message.content[]? | select(.type == "text") | .text' 2>/dev/null \
    | tail -c 12000)

if [ -z "$LAST_TEXT" ]; then
    exit 0
fi

PATTERNS='simpler approach|simpler way|simpler solution|simpler version|quicker approach|quick fix|quick[- ]and[- ]dirty|good enough for now|let me just|let'\''s just|hack together|band[- ]?aid|for now,? (i|we|let)|low.?hanging fruit|low.?hanging|easy way out|take a shortcut|as a shortcut|shortcut here|cheap way|minimal change|dumb(ed)?[- ]?down|stub[- ]?out for now|lazy approach|lazier approach|skip the hard|avoid the hard|dodge the (hard|real)|kludge|duct[- ]tape|mvp (approach|version)|throw.?away (version|impl)|i[- ]?will (just|simply)|i[- ]?am going to just|naive (approach|version|impl)|poor.?man'\''s|for simplicity|keep (it|this) simple for now|punt on|skip (the|this) for now|defer (the|this) (hard|real)|workaround for now'

FOUND=$(printf '%s' "$LAST_TEXT" | grep -iEo "$PATTERNS" | sort -u | head -5 || true)

if [ -z "$FOUND" ]; then
    CAVEMAN_FLAG="$HOME/.claude/.caveman-active"
    if [ -f "$CAVEMAN_FLAG" ]; then
        TEXT_ONLY=$(printf '%s' "$LAST_TEXT" | sed 's/```[^`]*```//g')
        WORD_COUNT=$(printf '%s' "$TEXT_ONLY" | wc -w | tr -d ' ')
        SENTENCE_COUNT=$(printf '%s' "$TEXT_ONLY" | grep -oE '[.!?](\s|$)' | wc -l | tr -d ' ')
        if [ "$WORD_COUNT" -gt 150 ] && [ "$SENTENCE_COUNT" -gt 6 ]; then
            FOUND="VERBOSE CAVEMAN VIOLATION: ${WORD_COUNT} words, ${SENTENCE_COUNT} sentences (budget: 3 sentences, ~50 words)"
        fi
    fi
fi

if [ -z "$FOUND" ]; then
    TEXT_ONLY=$(printf '%s' "$LAST_TEXT" \
        | sed 's/```[^`]*```//g' \
        | sed '/^[[:space:]]*[-*]/d' \
        | sed '/^[[:space:]]*[0-9]\{1,\}\./d' \
        | sed '/^[[:space:]]*#/d' \
        | sed '/^[[:space:]]*|/d')
    STACCATO=$(printf '%s' "$TEXT_ONLY" | grep -oE '[^.!?]*[.!?]' | awk '{gsub(/^[[:space:]]+/,"")} NF<=8{c++} NF>8{if(c>=4) print c" consecutive short sentences"; c=0} END{if(c>=4) print c" consecutive short sentences"}' | head -1 || true)
    if [ -n "$STACCATO" ]; then
        FOUND="STACCATO STYLE VIOLATION: $STACCATO detected. Connect ideas with commas, semicolons, conjunctions. No robot-talk."
    fi
fi

if [ -z "$FOUND" ]; then
    exit 0
fi

echo $((COUNT + 1)) > "$STATE_FILE"

REASON=$(cat <<EOF
SLOPPINESS SIGNAL DETECTED in your last response.

You used shortcut-seeking language that is a strong indicator you are about to cut corners instead of doing the real work.

Flagged phrases:
$FOUND

HARD RULE from CLAUDE.md — NO SHORTCUTS:
- Think big. Do not reach for low-hanging fruit.
- If the honest answer is a significant piece of work, a rewrite, or tackling the hard problem head-on, SAY SO and do it.
- Do not propose workarounds that dodge the hard problem and dress them up as architectural choices.
- Shortcuts become debt that blocks the real target.
- "Simpler" is not a virtue when it means "skipping the hard part".
- Do not minimize hard work to make it sound easy.
- Do not use tiers, phases, or rankings as a way to defer hard problems.

What to do NOW:
1. Name the hard problem you were about to dodge. State it plainly.
2. Choose the real approach (the one that actually solves the hard problem), not the lazy one.
3. If you are genuinely uncertain between two paths, say you are uncertain and explain why, then pick one as your current best guess. Do NOT hand the choice back to the user as an escape hatch.
4. If the real answer is a significant piece of work, say so directly and commit to it.

Re-engage. State the real problem honestly. Commit to the real work.
EOF
)

if [[ "$HOOK_EVENT" == "stop" ]]; then
    # Cursor stop hook cannot block — send a followup_message to re-engage the agent
    jq -n --arg msg "$REASON" '{followup_message: $msg}'
else
    # Claude Code Stop hook blocks via decision:block
    jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'
fi
exit 0
