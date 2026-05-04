#!/bin/bash
input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name // "?"')

COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
COST_FMT=$(printf '%.2f' "$COST")

CTX_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
CTX_USED_PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

INPUT_TOKENS=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
OUTPUT_TOKENS=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')

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

IN_K=$(( INPUT_TOKENS / 1000 ))
OUT_K=$(( OUTPUT_TOKENS / 1000 ))
CTX_K=$(( CTX_SIZE / 1000 ))

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

echo "${MODEL}  │  \$${COST_FMT}  │  ctx: ${CTX_BAR} ${CTX_USED_PCT}%  ${IN_K}k/${OUT_K}k of ${CTX_K}k  │  ${DURATION_MIN}m${QUOTA}"
