#!/bin/bash
input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name // "?"')

LOCATION=""
DIR=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
if [ -n "$DIR" ]; then
    LOCATION="${DIR##*/}"
    # --no-optional-locks so a refresh never holds index.lock while another git command runs in the repo
    BRANCH=$(git --no-optional-locks -C "$DIR" branch --show-current 2>/dev/null)
    [ -n "$BRANCH" ] || BRANCH=$(git --no-optional-locks -C "$DIR" rev-parse --short HEAD 2>/dev/null)
    [ -n "$BRANCH" ] && LOCATION="${LOCATION} (${BRANCH})"
    # claude-profile launchers export CLAUDE_PROFILE; the default ~/.claude session has none
    [ -n "$CLAUDE_PROFILE" ] && LOCATION="[${CLAUDE_PROFILE}] ${LOCATION}"
    LOCATION="${LOCATION}  │  "
fi

COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
COST_FMT=$(printf '%.2f' "$COST")

CTX_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
CTX_USED_PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

CTX_USED=$(echo "$input" | jq -r '(.context_window.current_usage // {}) | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)')

DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
DURATION_MIN=$(( DURATION_MS / 60000 ))

mini_bar() {
    local pct=$1
    local width=${2:-8}
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    echo "$bar"
}

CTX_BAR=$(mini_bar "$CTX_USED_PCT" 8)

if [ "$CTX_USED" -eq 0 ]; then
    CTX_USED=$(( CTX_SIZE * CTX_USED_PCT / 100 ))
fi
USED_K=$(( CTX_USED / 1000 ))

FIVE_H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
SEVEN_D=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
FIVE_H_RESET=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
SEVEN_D_RESET=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

QUOTA=""
if [ -n "$FIVE_H" ] && [ "$FIVE_H" != "null" ]; then
    FIVE_H_INT=$(printf '%.0f' "$FIVE_H")
    FIVE_BAR=$(mini_bar "$FIVE_H_INT" 5)
    RESET_STR=""
    if [ -n "$FIVE_H_RESET" ] && [ "$FIVE_H_RESET" != "null" ]; then
        NOW=$(date +%s)
        RESET_INT=$(printf '%.0f' "$FIVE_H_RESET")
        REMAINING=$(( RESET_INT - NOW ))
        if [ "$REMAINING" -gt 0 ]; then
            HOURS=$(( REMAINING / 3600 ))
            MINS=$(( (REMAINING % 3600) / 60 ))
            if [ "$HOURS" -gt 0 ]; then
                RESET_STR=" ${HOURS}h${MINS}m"
            else
                RESET_STR=" ${MINS}m"
            fi
        fi
    fi
    QUOTA="  │  session: ${FIVE_BAR} ${FIVE_H_INT}%${RESET_STR}"
fi

if [ -n "$SEVEN_D" ] && [ "$SEVEN_D" != "null" ]; then
    SEVEN_D_INT=$(printf '%.0f' "$SEVEN_D")
    SEVEN_BAR=$(mini_bar "$SEVEN_D_INT" 5)
    QUOTA="${QUOTA}  week: ${SEVEN_BAR} ${SEVEN_D_INT}%"
fi

# Mods write one segment file per session (see configs/claude-code/mods); the
# order here is fixed so segments do not jump around, and a file untouched for
# 10 minutes is skipped because a crashed session never empties its own.
SEGMENTS=""
SESSION_ID=$(echo "$input" | jq -r '.session_id // empty')
if [[ "$SESSION_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
    STATUS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/harness/status/$SESSION_ID"
    NOW_MS=$(( $(date +%s) * 1000 ))
    for mod in cache-guard guard-watch; do
        file="$STATUS_DIR/$mod.json"
        [ -s "$file" ] || continue
        IFS=$'\t' read -r text tone at < <(jq -r '[.text // "", .tone // "normal", (.at // 0 | floor)] | @tsv' "$file" 2>/dev/null) || continue
        [ -n "$text" ] || continue
        (( NOW_MS - at <= 600000 )) || continue
        if [ "$tone" = "warn" ]; then
            text=$'\033[33m'"$text"$'\033[0m'
        fi
        SEGMENTS="${SEGMENTS}  │  ${text}"
    done
fi

echo "${LOCATION}${MODEL}  │  \$${COST_FMT}  │  ctx ${CTX_BAR} ${CTX_USED_PCT}% ${USED_K}k  │  ${DURATION_MIN}m${QUOTA}${SEGMENTS}"
