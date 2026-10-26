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
export HARNESS_ENV="$TMP_DIR/harness.env"
: >"$HARNESS_ENV"

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
assert "turn 5 with no wiki writes fires" 'grep -q "WIKI" <<<"$OUT"'
assert "turn count in message is honest" 'grep -q "5 turns" <<<"$OUT"'

for _ in $(seq 1 4); do
  OUT=$(run_hook "$(claude_payload "$SESSION")")
done
assert "turns 6-9 stay silent" '[ -z "$OUT" ]'

OUT=$(run_hook "$(claude_payload "$SESSION")")
assert "turn 10 still unwritten fires with cumulative count" 'grep -q "10 turns" <<<"$OUT"'
assert "the nudge never points at the generated top index" '! grep -q "wiki/index.md" <<<"$OUT"'

echo "9" > "$COUNT_FILE"
echo "$(( $(date +%s) - 3600 ))" > "$START_FILE"
mkdir -p "$WIKI_DIR/decisions"
touch "$WIKI_DIR/devlog.md" "$WIKI_DIR/decisions/pick.md"
OUT=$(run_hook "$(claude_payload "$SESSION")")
assert "a new page without a project index update fires" 'grep -qF "$WIKI_DIR/index.md" <<<"$OUT"'
assert "the index nudge does not ask for the written devlog" '! grep -q "devlog" <<<"$OUT"'
echo "9" > "$COUNT_FILE"
touch "$WIKI_DIR/index.md"
OUT=$(run_hook "$(claude_payload "$SESSION")")
assert "devlog and project index written after a new page silence the nudge" '[ -z "$OUT" ]'
rm -rf "$WIKI_DIR/decisions" "$WIKI_DIR/index.md"

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
assert "pre-session wiki write still fires" 'grep -q "WIKI" <<<"$OUT"'

OUT=$(WIKI_NUDGE_STATE_DIR="$STATE_DIR" WIKI_VAULT="$VAULT" CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" <<<'{"hook_event_name": "UserPromptSubmit", "prompt": "x"}')
assert "missing session id exits silently" '[ -z "$OUT" ]'

CSESSION="wiki-cursor-001"
echo "4" > "$STATE_DIR/${CSESSION}.count"
echo "$(date +%s)" > "$STATE_DIR/${CSESSION}.start"
rm -f "$WIKI_DIR/devlog.md"
OUT=$(run_hook "$(cursor_payload "$CSESSION")")
assert "cursor payload emits additional_context" 'printf "%s" "$OUT" | jq -e ".additional_context" >/dev/null'

git -C "$PROJECT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$PROJECT" worktree add -q "$TMP_DIR/w-t8-seed" -b wt
WSESSION="wiki-worktree-001"
echo "4" > "$STATE_DIR/${WSESSION}.count"
echo "$(date +%s)" > "$STATE_DIR/${WSESSION}.start"
OUT=$(WIKI_NUDGE_STATE_DIR="$STATE_DIR" WIKI_VAULT="$VAULT" CLAUDE_PROJECT_DIR="$TMP_DIR/w-t8-seed" bash "$HOOK" <<<"$(claude_payload "$WSESSION")")
assert "a worktree session is nudged toward its main checkout's devlog" 'grep -qF "projects/myproj/devlog.md" <<<"$OUT"'

echo ""
echo "wiki-nudge: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
