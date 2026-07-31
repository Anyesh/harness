#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/configs/shared/hooks/stop-wiki-enforce.sh"

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
mkdir -p "$STATE_DIR" "$PROJECT" "$VAULT/wiki/projects/myproj"

payload() {
  jq -n --arg id "$1" --arg t "${2:-}" \
    '{session_id: $id, hook_event_name: "Stop", transcript_path: $t}'
}

run_hook() {
  WIKI_ENFORCE_STATE_DIR="$STATE_DIR" WIKI_VAULT="$VAULT" \
    CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" <<<"$1"
}

tool_use() {
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":{"file_path":"%s"}}]}}\n' "$1" "$2"
}

echo ""

# A conversation-only session: tool names appear in transcript text but no
# file mutations happened. Must stay silent.
T_IDLE="$TMP_DIR/idle.jsonl"
{
  printf '{"type":"user","message":{"content":"hi"}}\n'
  tool_use "ToolSearch" "/tmp/x"
} > "$T_IDLE"
OUT=$(run_hook "$(payload "s-idle" "$T_IDLE")")
assert "zero-edit session stays silent" '[ -z "$OUT" ]'

T_EDITS="$TMP_DIR/edits.jsonl"
{
  tool_use "Write" "/tmp/a"
  tool_use "Edit" "/tmp/b"
  tool_use "Write" "/tmp/c"
} > "$T_EDITS"
OUT=$(run_hook "$(payload "s-edits" "$T_EDITS")")
assert "3 native edits without wiki writes fires" \
  'printf "%s" "$OUT" | jq -e ".decision == \"block\"" >/dev/null'

OUT=$(run_hook "$(payload "s-edits" "$T_EDITS")")
assert "already-fired session stays silent" '[ -z "$OUT" ]'

T_VERDANT="$TMP_DIR/verdant.jsonl"
{
  tool_use "mcp__verdant__write" "/tmp/a"
  tool_use "mcp__verdant__edit" "/tmp/b"
  tool_use "mcp__verdant__write" "/tmp/c"
} > "$T_VERDANT"
OUT=$(run_hook "$(payload "s-verdant" "$T_VERDANT")")
assert "3 verdant edits without wiki writes fires" \
  'printf "%s" "$OUT" | jq -e ".decision == \"block\"" >/dev/null'

T_DONE="$TMP_DIR/done.jsonl"
{
  tool_use "Write" "/tmp/a"
  tool_use "Edit" "/tmp/b"
  tool_use "Write" "/tmp/c"
  tool_use "Write" "$VAULT/wiki/index.md"
  tool_use "Write" "$VAULT/wiki/projects/myproj/devlog.md"
} > "$T_DONE"
OUT=$(run_hook "$(payload "s-done" "$T_DONE")")
assert "edits with wiki index and devlog written stays silent" '[ -z "$OUT" ]'

T_PARTIAL="$TMP_DIR/partial.jsonl"
{
  tool_use "Write" "/tmp/a"
  tool_use "Edit" "/tmp/b"
  tool_use "Write" "/tmp/c"
  tool_use "Write" "$VAULT/wiki/projects/myproj/devlog.md"
} > "$T_PARTIAL"
OUT=$(run_hook "$(payload "s-partial" "$T_PARTIAL")")
assert "devlog written but index missing fires" \
  'printf "%s" "$OUT" | jq -e ".decision == \"block\"" >/dev/null'
assert "message names the missing index" \
  'printf "%s" "$OUT" | jq -r ".reason" | grep -q "wiki/index.md"'

OUT=$(run_hook "$(payload "s-notranscript" "")")
assert "claude session without transcript stays silent" '[ -z "$OUT" ]'

echo ""
echo "stop-wiki-enforce: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
