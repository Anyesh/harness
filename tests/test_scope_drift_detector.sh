#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/configs/shared/hooks/scope-drift-detector.sh"

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
PROJECT="$TMP_DIR/project"
mkdir -p "$STATE_DIR" "$PROJECT"
git -C "$PROJECT" init -q

claude_payload() {
  jq -n --arg id "$1" '{session_id: $id, hook_event_name: "UserPromptSubmit", prompt: "work on the feature"}'
}

cursor_payload() {
  jq -n --arg id "$1" --arg root "$PROJECT" \
    '{conversation_id: $id, hook_event_name: "beforeSubmitPrompt", cursor_version: "1.0.0", workspace_roots: [$root], prompt: "work on the feature"}'
}

run_hook() {
  SCOPE_DRIFT_STATE_DIR="$STATE_DIR" CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" <<<"$1"
}

SESSION="test-session-001"
COUNT_FILE="$STATE_DIR/${SESSION}.count"

echo ""

OUT=""
for _ in $(seq 1 9); do
  OUT=$(run_hook "$(claude_payload "$SESSION")")
done
assert "turns 1-9 stay silent" '[ -z "$OUT" ]'
assert "counter reaches 9 after 9 prompts" '[ "$(cat "$COUNT_FILE")" = "9" ]'

OUT=$(run_hook "$(claude_payload "$SESSION")")
assert "turn 10 without .scope.md fires" 'printf "%s" "$OUT" | grep -q "SCOPE CHECK (turn 10)"'
assert "claude payload emits hookSpecificOutput" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext" >/dev/null'

OUT=$(run_hook "$(claude_payload "$SESSION")")
assert "turn 11 stays silent" '[ -z "$OUT" ]'

echo "19" > "$COUNT_FILE"
touch "$PROJECT/.scope.md"
OUT=$(run_hook "$(claude_payload "$SESSION")")
assert "turn 20 with fresh .scope.md stays silent" '[ -z "$OUT" ]'

echo "29" > "$COUNT_FILE"
touch -d "3 hours ago" "$PROJECT/.scope.md"
OUT=$(run_hook "$(claude_payload "$SESSION")")
assert "turn 30 with stale .scope.md fires" 'printf "%s" "$OUT" | grep -q "SCOPE CHECK (turn 30)"'

echo "215" > "$PROJECT/.scope-turn-count"
run_hook "$(claude_payload "$SESSION")" >/dev/null
assert "legacy repo-root marker is removed" '[ ! -f "$PROJECT/.scope-turn-count" ]'

OTHER="test-session-002"
rm -f "$PROJECT/.scope.md"
OUT=$(run_hook "$(claude_payload "$OTHER")")
assert "second session starts its own count silently" '[ -z "$OUT" ]'
assert "second session counter is independent" '[ "$(cat "$STATE_DIR/${OTHER}.count")" = "1" ]'

OUT=$(SCOPE_DRIFT_STATE_DIR="$STATE_DIR" CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" <<<'{"hook_event_name": "UserPromptSubmit", "prompt": "x"}')
assert "missing session id exits silently" '[ -z "$OUT" ]'

CSESSION="cursor-conv-001"
echo "9" > "$STATE_DIR/${CSESSION}.count"
OUT=$(run_hook "$(cursor_payload "$CSESSION")")
assert "cursor payload emits additional_context" 'printf "%s" "$OUT" | jq -e ".additional_context" >/dev/null'

echo ""
echo "scope-drift-detector: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
