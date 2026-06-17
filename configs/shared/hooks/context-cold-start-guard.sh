#!/bin/bash
set -euo pipefail

# Cursor-only: block beforeSubmitPrompt when a large context is about to go cold
# (model change, post-compaction, or cache-idle) and would re-bill at full input price.
# Also records context_tokens on preCompact for size estimates when transcript_path is missing.
#
# Override: prefix prompt with /force
# Disable: CONTEXT_COLD_GUARD=0

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=harness-project.sh
source "$HOOK_DIR/harness-project.sh"

INPUT=$(cat 2>/dev/null || true)
AGENT=$("$HOOK_DIR/detect-agent.sh" <<< "$INPUT")
[[ "$AGENT" == "cursor" ]] || exit 0
CURSOR_VERSION=$(printf '%s' "$INPUT" | jq -r '.cursor_version // empty' 2>/dev/null || true)
[[ -n "$CURSOR_VERSION" ]] || exit 0
[[ "${CONTEXT_COLD_GUARD:-1}" != "0" ]] || exit 0

HOOK_EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
CONVERSATION_ID=$(printf '%s' "$INPUT" | jq -r '.conversation_id // empty' 2>/dev/null || true)
[[ -n "$CONVERSATION_ID" ]] || exit 0

STATE_ROOT="${CONTEXT_COLD_STATE_DIR:-$HOME/.cursor/state/context-cold-start}"
STATE_FILE="$STATE_ROOT/${CONVERSATION_ID}.json"
mkdir -p "$STATE_ROOT" 2>/dev/null || true

MIN_TRANSCRIPT_BYTES="${CONTEXT_COLD_GUARD_MIN_BYTES:-1200000}"
MIN_CONTEXT_TOKENS="${CONTEXT_COLD_GUARD_MIN_TOKENS:-400000}"
IDLE_SECS="${CONTEXT_COLD_GUARD_IDLE_SECS:-300}"
MIN_TURNS="${CONTEXT_COLD_GUARD_MIN_TURNS:-2}"
ABSOLUTE_MAX_BYTES="${CONTEXT_COLD_GUARD_ABSOLUTE_BYTES:-3000000}"
COMPACT_WINDOW_SECS="${CONTEXT_COLD_GUARD_COMPACT_WINDOW:-600}"
BYTES_PER_TOKEN_EST="${CONTEXT_COLD_GUARD_BYTES_PER_TOKEN:-4}"

log_guard() {
  [[ "${CONTEXT_COLD_GUARD_LOG:-0}" == "1" ]] || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$STATE_ROOT/guard.log" 2>/dev/null || true
}

sanitize_uint() {
  local v="${1:-}"
  local default="${2:-0}"
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    printf '%s' "$v"
  else
    printf '%s' "$default"
  fi
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    local raw
    raw=$(cat "$STATE_FILE" 2>/dev/null || printf '{}')
    if printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
      printf '%s' "$raw"
    else
      printf '%s' '{}'
    fi
  else
    printf '%s' '{}'
  fi
}

save_state() {
  local payload="$1"
  printf '%s' "$payload" > "$STATE_FILE"
}

transcript_bytes() {
  local path="$1"
  if [[ -z "$path" || ! -f "$path" ]]; then
    printf '0'
    return 0
  fi
  local size
  size=$(stat -c%s "$path" 2>/dev/null || stat -f%z "$path" 2>/dev/null || printf '0')
  sanitize_uint "$size" 0
}

estimate_context_mass() {
  local transcript_b="$1"
  local context_tokens="$2"
  local token_bytes=0
  if [[ "$context_tokens" =~ ^[0-9]+$ ]] && [[ "$context_tokens" -gt 0 ]]; then
    token_bytes=$((context_tokens * BYTES_PER_TOKEN_EST))
  fi
  if [[ "$transcript_b" -gt "$token_bytes" ]]; then
    printf '%s' "$transcript_b"
  else
    printf '%s' "$token_bytes"
  fi
}

if [[ "$HOOK_EVENT" == "preCompact" ]]; then
  CONTEXT_TOKENS=$(printf '%s' "$INPUT" | jq '(.context_tokens // 0) | floor' 2>/dev/null || echo 0)
  CONTEXT_TOKENS=$(sanitize_uint "$CONTEXT_TOKENS" 0)
  NOW=$(date +%s)
  STATE=$(load_state)
  STATE=$(printf '%s' "$STATE" | jq \
    --argjson tokens "$CONTEXT_TOKENS" \
    --argjson now "$NOW" \
    '.last_context_tokens = $tokens
     | .compact_pending = true
     | .compact_at = $now' 2>/dev/null) || exit 0
  save_state "$STATE"
  log_guard "preCompact conversation=$CONVERSATION_ID tokens=$CONTEXT_TOKENS"
  exit 0
fi

[[ "$HOOK_EVENT" == "beforeSubmitPrompt" ]] || exit 0

REPO_ROOT="$(harness_repo_root "$INPUT")"
harness_is_tooling_dir "$REPO_ROOT" && exit 0

PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)
if [[ "$PROMPT" =~ ^[[:space:]]*/force([[:space:]]|$) ]]; then
  log_guard "force override conversation=$CONVERSATION_ID"
  exit 0
fi

MODEL=$(printf '%s' "$INPUT" | jq -r '.model // empty' 2>/dev/null || true)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
NOW=$(date +%s)

STATE=$(load_state)
LAST_MODEL=$(printf '%s' "$STATE" | jq -r '.last_model // empty' 2>/dev/null || true)
LAST_SUBMIT=$(sanitize_uint "$(printf '%s' "$STATE" | jq -r '.last_submit_epoch // 0' 2>/dev/null || echo 0)" 0)
TURN_COUNT=$(sanitize_uint "$(printf '%s' "$STATE" | jq -r '.turn_count // 0' 2>/dev/null || echo 0)" 0)
LAST_CONTEXT_TOKENS=$(sanitize_uint "$(printf '%s' "$STATE" | jq -r '.last_context_tokens // 0' 2>/dev/null || echo 0)" 0)
COMPACT_PENDING=$(printf '%s' "$STATE" | jq -r '.compact_pending // false' 2>/dev/null || echo false)
COMPACT_AT=$(sanitize_uint "$(printf '%s' "$STATE" | jq -r '.compact_at // 0' 2>/dev/null || echo 0)" 0)

TRANSCRIPT_B=$(transcript_bytes "$TRANSCRIPT")
TRANSCRIPT_B=$(sanitize_uint "$TRANSCRIPT_B" 0)
CONTEXT_MASS=$(estimate_context_mass "$TRANSCRIPT_B" "$LAST_CONTEXT_TOKENS")

FAT=false
if [[ "$TRANSCRIPT_B" -ge "$ABSOLUTE_MAX_BYTES" ]]; then
  FAT=true
elif [[ "$TRANSCRIPT_B" -ge "$MIN_TRANSCRIPT_BYTES" ]]; then
  FAT=true
elif [[ "$LAST_CONTEXT_TOKENS" =~ ^[0-9]+$ ]] && [[ "$LAST_CONTEXT_TOKENS" -ge "$MIN_CONTEXT_TOKENS" ]]; then
  FAT=true
elif [[ "$CONTEXT_MASS" -ge "$MIN_TRANSCRIPT_BYTES" ]]; then
  FAT=true
fi

INVALIDATION=false
REASONS=()

if [[ -n "$LAST_MODEL" && -n "$MODEL" && "$LAST_MODEL" != "$MODEL" ]]; then
  INVALIDATION=true
  REASONS+=("model changed ($LAST_MODEL -> $MODEL)")
fi

if [[ "$COMPACT_PENDING" == "true" ]]; then
  if [[ "$COMPACT_AT" =~ ^[0-9]+$ ]] && [[ "$COMPACT_AT" -gt 0 ]]; then
    AGE=$((NOW - COMPACT_AT))
    if [[ "$AGE" -le "$COMPACT_WINDOW_SECS" ]]; then
      INVALIDATION=true
      REASONS+=("recent compaction")
    fi
  fi
fi

if [[ "$LAST_SUBMIT" =~ ^[0-9]+$ ]] && [[ "$LAST_SUBMIT" -gt 0 ]] && [[ "$TURN_COUNT" -ge "$MIN_TURNS" ]]; then
  IDLE=$((NOW - LAST_SUBMIT))
  if [[ "$IDLE" -ge "$IDLE_SECS" ]]; then
    INVALIDATION=true
    REASONS+=("idle ${IDLE}s (prompt cache likely expired)")
  fi
fi

SHOULD_BLOCK=false
if [[ "$FAT" == true && "$INVALIDATION" == true && "$TURN_COUNT" -ge "$MIN_TURNS" ]]; then
  SHOULD_BLOCK=true
fi
if [[ "$TRANSCRIPT_B" -ge "$ABSOLUTE_MAX_BYTES" && "$TURN_COUNT" -ge "$MIN_TURNS" ]]; then
  SHOULD_BLOCK=true
fi

NEXT_TURN=$((TURN_COUNT + 1))
NEXT_STATE=$(printf '%s' "$STATE" | jq \
  --arg model "$MODEL" \
  --argjson transcript_bytes "$TRANSCRIPT_B" \
  --argjson now "$NOW" \
  --argjson turn "$NEXT_TURN" \
  '.last_model = $model
   | .last_transcript_bytes = $transcript_bytes
   | .last_submit_epoch = $now
   | .turn_count = $turn
   | .compact_pending = false' 2>/dev/null) || exit 0

if [[ "$SHOULD_BLOCK" == true ]]; then
  REASON_TEXT=$(IFS='; '; echo "${REASONS[*]}")
  MSG=$(cat <<EOF
BLOCKED by context-cold-start-guard: large context (~$(numfmt --to=iec "$CONTEXT_MASS" 2>/dev/null || echo "${CONTEXT_MASS}B")) with cold-cache risk (${REASON_TEXT}).

This send would likely re-bill the full thread at input price. To proceed anyway, prefix your prompt with /force.

Safer options:
- Start a new agent and reference only the plan or files you need (@path)
- Keep planning exploration in subagents so the main thread stays smaller
- Wait and continue only if you accept the re-bill
EOF
)
  log_guard "BLOCK conversation=$CONVERSATION_ID mass=$CONTEXT_MASS reasons=$REASON_TEXT"
  jq -n --arg msg "$MSG" '{continue: false, user_message: $msg}' 2>/dev/null || exit 0
  save_state "$NEXT_STATE"
  exit 0
fi

log_guard "allow conversation=$CONVERSATION_ID mass=$CONTEXT_MASS turns=$NEXT_TURN model=$MODEL"
save_state "$NEXT_STATE"
exit 0
