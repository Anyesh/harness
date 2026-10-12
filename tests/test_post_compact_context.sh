#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS="$REPO_ROOT/configs/shared/hooks"
NOTE="$HOOKS/compact-note.sh"
HOOK="$HOOKS/post-compact-context.sh"
PLUGIN="$REPO_ROOT/configs/opencode/plugins/harness-compact-scope.js"

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

PROJECT="$TMP_DIR/project"
BARE="$TMP_DIR/bare"
STATE_DIR="$TMP_DIR/state"
mkdir -p "$PROJECT" "$BARE"
git -C "$PROJECT" init -q
git -C "$BARE" init -q
printf '# Scope: ship the widget\n\n## 2. Definition of done\n- widget renders\n' > "$PROJECT/.scope.md"

echo ""

OUT=$(bash "$NOTE" "$BARE")
assert "note is empty when the repo has no .scope.md" '[ -z "$OUT" ]'

: > "$BARE/.scope.md"
OUT=$(bash "$NOTE" "$BARE")
assert "note is empty when .scope.md is empty" '[ -z "$OUT" ]'
rm "$BARE/.scope.md"

OUT=$(bash "$NOTE" "$PROJECT")
assert "note carries the scope contents" 'grep -q "widget renders" <<<"$OUT"'
assert "note names the file it came from" 'grep -q "$PROJECT/.scope.md" <<<"$OUT"'

BIG="$TMP_DIR/big"
mkdir -p "$BIG"
python3 -c "print('scope line with words\n' * 2000)" > "$BIG/.scope.md"
OUT=$(bash "$NOTE" "$BIG")
CHARS=$(printf '%s' "$OUT" | wc -m)
assert "oversized scope stays under the injection cap" '[ "$CHARS" -lt 6500 ]'
assert "oversized scope says it was truncated" 'grep -q "truncated" <<<"$OUT"'

claude_session_start() {
  local source="$1" dir="$2"
  CLAUDE_PROJECT_DIR="$dir" bash "$HOOK" \
    <<<"{\"hook_event_name\":\"SessionStart\",\"source\":\"$source\"}"
}

OUT=$(claude_session_start compact "$PROJECT")
CTX=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$OUT")
assert "SessionStart after compaction injects the scope" 'grep -q "widget renders" <<<"$CTX"'
assert "SessionStart output names its event" \
  '[ "$(jq -r ".hookSpecificOutput.hookEventName" <<<"$OUT")" = "SessionStart" ]'

for source in startup resume clear; do
  OUT=$(claude_session_start "$source" "$PROJECT")
  assert "SessionStart source=$source injects nothing" '[ -z "$OUT" ]'
done

OUT=$(claude_session_start compact "$BARE")
assert "SessionStart after compaction without a scope injects nothing" '[ -z "$OUT" ]'

OUT=$(cd "$PROJECT" && env -u CLAUDE_PROJECT_DIR bash "$HOOK" \
  <<<'{"hook_event_name":"SessionStart","source":"compact","cwd":"'"$PROJECT"'"}')
assert "Codex-style payload resolves the repo from the session cwd" \
  'grep -q "widget renders" <<<"$(jq -r ".hookSpecificOutput.additionalContext" <<<"$OUT")"'

cursor() {
  local event="$1" conv="$2" root="$3"
  COMPACT_SCOPE_STATE_DIR="$STATE_DIR" bash "$HOOK" <<<"$(jq -n \
    --arg event "$event" --arg conv "$conv" --arg root "$root" \
    '{hook_event_name: $event, conversation_id: $conv, cursor_version: "1.0.0", workspace_roots: [$root]}')"
}

OUT=$(cursor postToolUse conv-a "$PROJECT")
assert "Cursor postToolUse without a compaction injects nothing" \
  '[ "$(jq -r ".additional_context // empty" <<<"$OUT")" = "" ]'

OUT=$(cursor preCompact conv-a "$PROJECT")
assert "Cursor preCompact emits no user_message" '[ "$(jq -r ".user_message // empty" <<<"$OUT")" = "" ]'

OUT=$(cursor postToolUse conv-b "$PROJECT")
assert "Cursor compaction mark does not leak to another conversation" \
  '[ "$(jq -r ".additional_context // empty" <<<"$OUT")" = "" ]'

OUT=$(cursor postToolUse conv-a "$PROJECT")
assert "first Cursor postToolUse after compaction injects the scope" \
  'grep -q "widget renders" <<<"$(jq -r ".additional_context // empty" <<<"$OUT")"'

OUT=$(cursor postToolUse conv-a "$PROJECT")
assert "Cursor injects the scope only once per compaction" \
  '[ "$(jq -r ".additional_context // empty" <<<"$OUT")" = "" ]'

cursor preCompact conv-c "$PROJECT" >/dev/null
touch -d '2 days ago' "$STATE_DIR/conv-c"
OUT=$(cursor postToolUse conv-c "$PROJECT")
assert "stale Cursor compaction mark is ignored" \
  '[ "$(jq -r ".additional_context // empty" <<<"$OUT")" = "" ]'
assert "stale Cursor compaction mark is removed" '[ ! -e "$STATE_DIR/conv-c" ]'

cursor preCompact "../escape" "$PROJECT" >/dev/null
assert "conversation ids cannot write outside the state dir" '[ ! -e "$TMP_DIR/escape" ]'

OC="$TMP_DIR/opencode"
mkdir -p "$OC/plugins" "$OC/hooks"
cp "$PLUGIN" "$OC/plugins/"
cp "$NOTE" "$OC/hooks/"
run_plugin() {
  node --input-type=module -e '
    const [plugin, worktree] = process.argv.slice(1)
    const mod = await import(plugin)
    const hooks = await Object.values(mod)[0]({ directory: worktree, worktree })
    const output = { context: [] }
    await hooks["experimental.session.compacting"]({ sessionID: "s1" }, output)
    process.stdout.write(output.context.join("\n"))
  ' "$OC/plugins/harness-compact-scope.js" "$1"
}
OUT=$(run_plugin "$PROJECT")
assert "opencode compaction context carries the scope" 'grep -q "widget renders" <<<"$OUT"'
OUT=$(run_plugin "$BARE")
assert "opencode adds no compaction context without a scope" '[ -z "$OUT" ]'

echo ""
echo "post-compact-context: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
