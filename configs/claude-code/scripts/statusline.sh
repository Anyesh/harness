#!/usr/bin/env bash
input=$(cat)

paint() {
    if [ -n "$NO_COLOR" ]; then
        printf '%s' "$2"
    else
        printf '\033[%sm%s\033[0m' "$1" "$2"
    fi
}

level() {
    if [ "$1" -ge 80 ]; then echo 31; elif [ "$1" -ge 50 ]; then echo 33; else echo 32; fi
}

SEP="  $(paint 2 "│")  "

join_parts() {
    local sep=$1 out="" part
    shift
    for part in "$@"; do
        [ -n "$part" ] && out="${out:+$out$sep}$part"
    done
    printf '%s' "$out"
}

span() {
    local mins=$(( $1 / 60000 ))
    if [ "$mins" -ge 60 ]; then
        printf '%dh%dm' $(( mins / 60 )) $(( mins % 60 ))
    else
        printf '%dm' "$mins"
    fi
}

MODEL=$(echo "$input" | jq -r '.model.display_name // "?"')

# claude-profile launchers export CLAUDE_PROFILE; a plain claude session runs on the default ~/.claude
if [ -n "$CLAUDE_PROFILE" ]; then
    LOCATION=$(paint '1;35' "[${CLAUDE_PROFILE}]")
else
    LOCATION=$(paint 2 "[default]")
fi
DIR=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
if [ -n "$DIR" ]; then
    LOCATION="${LOCATION} $(paint '1;34' "${DIR##*/}")"
    # --no-optional-locks so a refresh never holds index.lock while another git command runs in the repo
    BRANCH=$(git --no-optional-locks -C "$DIR" branch --show-current 2>/dev/null)
    [ -n "$BRANCH" ] || BRANCH=$(git --no-optional-locks -C "$DIR" rev-parse --short HEAD 2>/dev/null)
    [ -n "$BRANCH" ] && LOCATION="${LOCATION} $(paint 32 "(${BRANCH})")"
fi

COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
COST_FMT=$(printf '%.2f' "$COST")

CTX_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
CTX_USED_PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

read -r CACHE_READ CTX_USED < <(echo "$input" | jq -r '(.context_window.current_usage // {}) |
    [(.cache_read_input_tokens // 0), ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))] |
    map(floor) | @tsv')

CACHE_LOW_PCT=80
CACHE_HIT=""
[ "${CTX_USED:-0}" -gt 0 ] && CACHE_HIT=$(( CACHE_READ * 100 / CTX_USED ))

DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0 | floor')

mini_bar() {
    local pct=$1
    local width=${2:-8}
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local full="" rest=""
    for ((i=0; i<filled; i++)); do full+="█"; done
    for ((i=0; i<empty; i++)); do rest+="░"; done
    echo "$(paint "$(level "$pct")" "$full")$(paint 2 "$rest")"
}

CTX_BAR=$(mini_bar "$CTX_USED_PCT" 8)

if [ "${CTX_USED:-0}" -eq 0 ]; then
    CTX_USED=$(( CTX_SIZE * CTX_USED_PCT / 100 ))
fi
USED_K=$(( CTX_USED / 1000 ))

FIVE_H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
SEVEN_D=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
FIVE_H_RESET=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
SEVEN_D_RESET=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

FIVE_H_PART=""
if [ -n "$FIVE_H" ] && [ "$FIVE_H" != "null" ]; then
    FIVE_H_INT=$(printf '%.0f' "$FIVE_H")
    FIVE_H_PART="5h $(mini_bar "$FIVE_H_INT" 5) ${FIVE_H_INT}%"
    if [ -n "$FIVE_H_RESET" ] && [ "$FIVE_H_RESET" != "null" ]; then
        REMAINING=$(( $(printf '%.0f' "$FIVE_H_RESET") - $(date +%s) ))
        [ "$REMAINING" -gt 0 ] && FIVE_H_PART+=" ↻$(span $(( REMAINING * 1000 )))"
    fi
fi

SEVEN_D_PART=""
if [ -n "$SEVEN_D" ] && [ "$SEVEN_D" != "null" ]; then
    SEVEN_D_INT=$(printf '%.0f' "$SEVEN_D")
    SEVEN_D_PART="7d $(mini_bar "$SEVEN_D_INT" 5) ${SEVEN_D_INT}%"
fi

SESSION_ID=$(echo "$input" | jq -r '.session_id // empty')
[[ "$SESSION_ID" =~ ^[A-Za-z0-9_-]+$ ]] || SESSION_ID=""

# A crew lead reads these files, and treats each file's mtime as when its figures last changed.
record_usage() {
    local dir="${XDG_STATE_HOME:-$HOME/.local/state}/harness/usage/sessions"
    local file="$dir/$SESSION_ID.json" tmp
    mkdir -p "$dir" || return
    tmp=$(mktemp "$dir/.$SESSION_ID.XXXXXX") || return
    if ! echo "$input" | jq --arg profile "${CLAUDE_PROFILE:-default}" --argjson tokens "$CTX_USED" '
        def num: if type == "number" then floor else null end;
        def window: {pct: (.used_percentage | num), resets: (.resets_at | num)};
        {
            profile: $profile,
            context_tokens: $tokens,
            context_window: (.context_window.context_window_size | num),
            session: (.rate_limits.five_hour // {} | window),
            week: (.rate_limits.seven_day // {} | window)
        }' >"$tmp" || cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        return
    fi
    if [ -e "$file" ]; then
        mv -f "$tmp" "$file"
    else
        mv -f "$tmp" "$file" && find "$dir" -maxdepth 1 -name '*.json' -type f -mtime +7 -delete
    fi
}

# The status line is the product, so a failed usage write stays silent rather than corrupting it.
[ -n "$SESSION_ID" ] && record_usage 2>/dev/null

sidebar_herdr() {
    if [ -x "$HERDR_BIN_PATH" ]; then
        printf '%s\n' "$HERDR_BIN_PATH"
    else
        command -v herdr
    fi
}

# Fills the $claude_* tokens of this pane's sidebar entry (rows_by_agent.claude in configs/herdr/config.toml).
report_sidebar() {
    local herdr=$1
    local set=(--token "claude_profile=${CLAUDE_PROFILE:-default}" --token "claude_ctx=⛁ ${USED_K}k") clear=()
    if [ -n "$CACHE_HIT" ]; then
        if [ "$CACHE_HIT" -lt "$CACHE_LOW_PCT" ]; then
            set+=(--token "claude_cache_low=◉ ${CACHE_HIT}%")
            clear+=(--clear-token claude_cache)
        else
            set+=(--token "claude_cache=◉ ${CACHE_HIT}%")
            clear+=(--clear-token claude_cache_low)
        fi
    else
        clear+=(--clear-token claude_cache --clear-token claude_cache_low)
    fi
    # Separate calls so herdr refusing to clear a never-set token cannot drop the tokens being set.
    "$herdr" pane report-metadata "$HERDR_PANE_ID" --source harness-statusline --ttl-ms 60000 "${set[@]}"
    "$herdr" pane report-metadata "$HERDR_PANE_ID" --source harness-statusline "${clear[@]}"
}

if [ -n "$HERDR_PANE_ID" ]; then
    HERDR=$(sidebar_herdr)
    # Detached so a hung herdr socket never delays the status line.
    [ -n "$HERDR" ] && { report_sidebar "$HERDR" </dev/null >/dev/null 2>&1 & disown; }
fi

STATUS_DIR=""
[ -n "$SESSION_ID" ] && STATUS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/harness/status/$SESSION_ID"
NOW_MS=$(( $(date +%s) * 1000 ))

# A segment file untouched for 10 minutes is skipped because a crashed session never empties its own.
mod_segment() {
    local file="$STATUS_DIR/$1.json" text tone at
    [ -n "$STATUS_DIR" ] && [ -s "$file" ] || return
    IFS=$'\t' read -r text tone at < <(jq -r '[.text // "", .tone // "normal", (.at // 0 | floor)] | @tsv' "$file" 2>/dev/null) || return
    [ -n "$text" ] || return
    (( NOW_MS - at <= 600000 )) || return
    if [ "$tone" = "warn" ]; then paint 33 "$text"; else printf '%s' "$text"; fi
}

HIT=""
if [ -n "$CACHE_HIT" ]; then
    HIT="◉ ${CACHE_HIT}%"
    [ "$CACHE_HIT" -lt "$CACHE_LOW_PCT" ] && HIT=$(paint 31 "$HIT")
fi
CACHE_SLOT=$(join_parts " " "$(mod_segment cache-guard)" "$HIT")

SESSION_ROW=$(join_parts "$SEP" "$(paint 36 "$MODEL")" "\$${COST_FMT}" "⛁ ${CTX_BAR} ${CTX_USED_PCT}% ${USED_K}k" "$CACHE_SLOT" "$(paint 2 "up $(span "$DURATION_MS")")")
ACCOUNT_ROW=$(join_parts "$SEP" "$FIVE_H_PART" "$SEVEN_D_PART" "$(mod_segment cache-guard-agents)" "$(mod_segment guard-watch)")

draw() {
    if [ -n "$2" ]; then printf '%s  %s\n' "$1" "$2"; else printf '%s\n' "$1"; fi
}

# Every Clawd row is padded to 9 cells so the text beside him starts in the same column on all three rows
CLAWD='38;5;173'
draw "$(paint "$CLAWD" " ▐▛███▜▌ ")" "$LOCATION"
draw "$(paint "$CLAWD" "▝▜█████▛▘")" "$SESSION_ROW"
draw "$(paint "$CLAWD" "  ▘▘ ▝▝  ")" "$ACCOUNT_ROW"
