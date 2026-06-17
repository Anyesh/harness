#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD="$REPO_ROOT/configs/shared/hooks/context-cold-start-guard.sh"

PASS=0
FAIL=0

assert() {
  local name="$1"
  local cmd="$2"
  if eval "$cmd"; then
    printf '  PASS  %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$name"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

STATE_DIR="$TMP_DIR/state"
mkdir -p "$STATE_DIR"
TRANSCRIPT="$TMP_DIR/transcript.jsonl"
PROJECT="$TMP_DIR/project"
mkdir -p "$STATE_DIR" "$PROJECT"
git -C "$PROJECT" init -q

# ~1.3MB transcript stand-in
python3 -c "print('x' * 1300000)" > "$TRANSCRIPT"

run_guard() {
  local payload="$1"
  CONTEXT_COLD_STATE_DIR="$STATE_DIR" \
  CONTEXT_COLD_GUARD_MIN_BYTES=1200000 \
  CONTEXT_COLD_GUARD_MIN_TURNS=2 \
  bash "$GUARD" <<<"$payload"
}

CONV_ID="test-conv-001"
BASE=$(jq -n \
  --arg id "$CONV_ID" \
  --arg tp "$TRANSCRIPT" \
  --arg root "$PROJECT" \
  --arg model "claude-4.6-sonnet-medium-thinking" \
  '{
    conversation_id: $id,
    hook_event_name: "beforeSubmitPrompt",
    cursor_version: "1.0.0",
    model: $model,
    transcript_path: $tp,
    workspace_roots: [$root],
    prompt: "implement the feature"
  }')

echo ""
echo "=== context-cold-start-guard ==="
echo ""

# Seed state: prior turn was Opus
STATE_FILE="$STATE_DIR/${CONV_ID}.json"
jq -n \
  --arg model "claude-4.6-opus-medium-thinking" \
  '{last_model: $model, turn_count: 3, last_submit_epoch: (now | floor), last_context_tokens: 0, compact_pending: false}' \
  > "$STATE_FILE"

OUT=$(run_guard "$BASE")
assert "blocks on fat context + model change" 'echo "$OUT" | jq -e ".continue == false" >/dev/null'
assert "block message mentions /force" 'echo "$OUT" | jq -r ".user_message" | grep -q "/force"'

OUT=$(run_guard "$(echo "$BASE" | jq '.prompt = "/force ship it"')")
assert "/force bypasses block" '[[ -z "$OUT" || "$(echo "$OUT" | jq -r ".continue // true")" == "true" ]]'

# Same model, no invalidation: should allow
jq -n \
  --arg model "claude-4.6-sonnet-medium-thinking" \
  '{last_model: $model, turn_count: 3, last_submit_epoch: (now | floor), last_context_tokens: 0, compact_pending: false}' \
  > "$STATE_FILE"
OUT=$(run_guard "$BASE")
assert "allows fat context without invalidation signal" '[[ -z "$OUT" || "$(echo "$OUT" | jq -r ".continue // true")" == "true" ]]'

# preCompact records tokens
SMALL=$(jq -n \
  --arg id "$CONV_ID" \
  --arg root "$PROJECT" \
  '{
    conversation_id: $id,
    hook_event_name: "preCompact",
    cursor_version: "1.0.0",
    workspace_roots: [$root],
    context_tokens: 500000
  }')
CONTEXT_COLD_STATE_DIR="$STATE_DIR" bash "$GUARD" <<<"$SMALL" >/dev/null
assert "preCompact stores context_tokens" 'jq -e ".last_context_tokens == 500000 and .compact_pending == true" "$STATE_FILE" >/dev/null'

# Claude agent should no-op
CLAUDE_PAYLOAD=$(jq -n \
  --arg id "$CONV_ID" \
  '{conversation_id: $id, hook_event_name: "UserPromptSubmit", session_id: "abc", model: "opus"}')
OUT=$(CONTEXT_COLD_STATE_DIR="$STATE_DIR" bash "$GUARD" <<<"$CLAUDE_PAYLOAD" 2>/dev/null || true)
assert "ignores non-cursor payloads" '[[ -z "$OUT" ]]'

echo ""
printf "  Pass: %d  Fail: %d\n" "$PASS" "$FAIL"
echo ""
[[ $FAIL -eq 0 ]]
