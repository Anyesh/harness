#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/configs/shared/hooks/wiki-nudge.sh"

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
PROJECT="$TMP_DIR/myproj"
VAULT="$TMP_DIR/vault"
WIKI_DIR="$VAULT/wiki/projects/myproj"
mkdir -p "$STATE_DIR" "$PROJECT" "$WIKI_DIR"
git -C "$PROJECT" init -q

claude_payload() {
  jq -n --arg id "$1" '{session_id: $id, hook_event_name: "UserPromptSubmit", prompt: "keep working"}'
}

cursor_payload() {
  jq -n --arg id "$1" --arg root "$PROJECT" \
    '{conversation_id: $id, hook_event_name: "beforeSubmitPrompt", cursor_version: "1.0.0", workspace_roots: [$root], prompt: "keep working"}'
}

run_hook() {
  WIKI_NUDGE_STATE_DIR="$STATE_DIR" WIKI_VAULT="$VAULT" CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" <<<"$1"
}

SESSION="wiki-session-001"
COUNT_FILE="$STATE_DIR/${SESSION}.count"
START_FILE="$STATE_DIR/${SESSION}.start"

echo ""

OUT=""
for _ in $(seq 1 4); do
  OUT=$(run_hook "$(claude_payload "$SESSION")")
done
assert "turns 1-4 stay silent" '[ -z "$OUT" ]'
assert "session start timestamp recorded" '[ -f "$START_FILE" ]'

OUT=$(run_hook "$(claude_payload "$SESSION")")
assert "turn 5 with no wiki writes fires" 'printf "%s" "$OUT" | grep -q "WIKI"'
assert "turn count in message is honest" 'printf "%s" "$OUT" | grep -q "5 turns"'

for _ in $(seq 1 4); do
  OUT=$(run_hook "$(claude_payload "$SESSION")")
done
assert "turns 6-9 stay silent" '[ -z "$OUT" ]'

OUT=$(run_hook "$(claude_payload "$SESSION")")
assert "turn 10 still unwritten fires with cumulative count" 'printf "%s" "$OUT" | grep -q "10 turns"'

# Wiki write 30 minutes ago, session started 60 minutes ago: counts as written
# this session even though it is older than any rolling recency window.
echo "9" > "$COUNT_FILE"
echo "$(( $(date +%s) - 3600 ))" > "$START_FILE"
touch -d "30 minutes ago" "$WIKI_DIR/devlog.md"
OUT=$(run_hook "$(claude_payload "$SESSION")")
assert "wiki written after session start silences nudge" '[ -z "$OUT" ]'

# Wiki write BEFORE session start must not count.
echo "9" > "$COUNT_FILE"
echo "$(( $(date +%s) - 60 ))" > "$START_FILE"
touch -d "2 hours ago" "$WIKI_DIR/devlog.md"
OUT=$(run_hook "$(claude_payload "$SESSION")")
assert "pre-session wiki write still fires" 'printf "%s" "$OUT" | grep -q "WIKI"'

OUT=$(WIKI_NUDGE_STATE_DIR="$STATE_DIR" WIKI_VAULT="$VAULT" CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" <<<'{"hook_event_name": "UserPromptSubmit", "prompt": "x"}')
assert "missing session id exits silently" '[ -z "$OUT" ]'

CSESSION="wiki-cursor-001"
echo "4" > "$STATE_DIR/${CSESSION}.count"
echo "$(date +%s)" > "$STATE_DIR/${CSESSION}.start"
rm -f "$WIKI_DIR/devlog.md"
OUT=$(run_hook "$(cursor_payload "$CSESSION")")
assert "cursor payload emits additional_context" 'printf "%s" "$OUT" | jq -e ".additional_context" >/dev/null'

echo ""
echo "wiki-nudge: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
