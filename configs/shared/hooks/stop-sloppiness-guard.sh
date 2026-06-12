#!/bin/bash
# Stop hook: detect sloppy shortcut-seeking language in the last assistant turn.
# On detection, block Stop and feed a strong correction back into Claude's context.
# Loop-cap per session so we never get stuck in an infinite re-enter.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
AGENT=$("$HOOK_DIR/detect-agent.sh" <<< "$INPUT")
HOOK_EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.conversation_id // .session_id // empty' 2>/dev/null || true)

if [ -z "$SESSION_ID" ]; then
    exit 0
fi

if [ "$AGENT" = "cursor" ]; then
    STATE_DIR="$HOME/.cursor/state/sloppiness"
else
    STATE_DIR="$HOME/.claude/state/sloppiness"
fi

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
    exit 0
fi
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
KIND=""
[ -n "$FOUND" ] && KIND="shortcut"

if [ -z "$FOUND" ]; then
    # Strip fenced code blocks and inline code so file paths (settings.json) are not
    # split on every dot into tiny sentences, then drop markdown block lines.
    TEXT_ONLY=$(printf '%s' "$LAST_TEXT" \
        | awk 'BEGIN{inb=0} /^[[:space:]]*```/{inb=!inb; next} !inb' \
        | sed 's/`[^`]*`//g' \
        | sed '/^[[:space:]]*[-*]/d' \
        | sed '/^[[:space:]]*[0-9]\{1,\}\./d' \
        | sed '/^[[:space:]]*#/d' \
        | sed '/^[[:space:]]*|/d')
    # Split only at a terminator followed by whitespace so a dot inside a token does
    # not end a sentence; flag 5+ consecutive sentences of <=6 words.
    STACCATO=$(printf '%s' "$TEXT_ONLY" \
        | sed -E 's/([.!?])[[:space:]]+/\1\n/g' \
        | awk '{s=$0; gsub(/^[[:space:]]+/,"",s); gsub(/[[:space:]]+$/,"",s); if(s==""){c=0; next} m=split(s,p,/[[:space:]]+/); if(m<=6){c++; if(c>=5){print c" consecutive short sentences"; exit}} else {c=0}}' \
        | head -1 || true)
    if [ -n "$STACCATO" ]; then
        FOUND="$STACCATO"
        KIND="staccato"
    fi
fi

if [ -z "$FOUND" ]; then
    exit 0
fi

echo $((COUNT + 1)) > "$STATE_FILE"

if [ "$KIND" = "staccato" ]; then
REASON=$(cat <<EOF
WRITING STYLE NUDGE (not a shortcut warning).

Your last response had a run of $FOUND. Per the harness writing-style rule, connect related ideas with commas, semicolons, and conjunctions rather than stacking short declarative sentences. This is a style fix only and your approach is not in question; smooth out the choppy run, then continue what you were doing.
EOF
)
else
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
fi

if [[ "$HOOK_EVENT" == "stop" ]]; then
    # Cursor stop hook cannot block — send a followup_message to re-engage the agent
    jq -n --arg msg "$REASON" '{followup_message: $msg}'
else
    # Claude Code Stop hook blocks via decision:block
    jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'
fi
exit 0
