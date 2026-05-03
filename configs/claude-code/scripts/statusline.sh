#!/bin/bash
# Lightweight Claude Code status line — reads JSON from stdin, near-zero overhead
input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name // "?"')
MODEL_ID=$(echo "$input" | jq -r '.model.id // ""' | sed 's/claude-//;s/-[0-9]*$//')

COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
COST_FMT=$(printf '%.3f' "$COST")

CTX_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
CTX_USED_PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
CTX_REMAINING_PCT=$(echo "$input" | jq -r '.context_window.remaining_percentage // 0' | cut -d. -f1)

INPUT_TOKENS=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
OUTPUT_TOKENS=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
CACHE_READ=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')

DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
DURATION_MIN=$(( DURATION_MS / 60000 ))

ctx_bar() {
    local pct=$1
    local width=10
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    echo "$bar"
}

CTX_BAR=$(ctx_bar "$CTX_USED_PCT")

FIVE_H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
SEVEN_D=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
FIVE_H_RESET=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')

LIMITS=""
if [ -n "$FIVE_H" ] && [ "$FIVE_H" != "null" ]; then
    FIVE_H_FMT=$(printf '%.0f' "$FIVE_H")
    LIMITS=" │ 5h:${FIVE_H_FMT}%"
    if [ -n "$FIVE_H_RESET" ] && [ "$FIVE_H_RESET" != "null" ]; then
        NOW=$(date +%s)
        RESET_INT=$(printf '%.0f' "$FIVE_H_RESET")
        REMAINING=$(( RESET_INT - NOW ))
        if [ "$REMAINING" -gt 0 ]; then
            HOURS=$(( REMAINING / 3600 ))
            MINS=$(( (REMAINING % 3600) / 60 ))
            LIMITS="${LIMITS}(${HOURS}h${MINS}m)"
        fi
    fi
fi
if [ -n "$SEVEN_D" ] && [ "$SEVEN_D" != "null" ]; then
    SEVEN_D_FMT=$(printf '%.0f' "$SEVEN_D")
    LIMITS="${LIMITS} 7d:${SEVEN_D_FMT}%"
fi

IN_K=$(( INPUT_TOKENS / 1000 ))
OUT_K=$(( OUTPUT_TOKENS / 1000 ))
CTX_K=$(( CTX_SIZE / 1000 ))

echo "${MODEL} │ \$${COST_FMT} │ ${CTX_BAR} ${CTX_USED_PCT}% (${IN_K}k in/${OUT_K}k out of ${CTX_K}k) │ ${DURATION_MIN}m${LIMITS}"
