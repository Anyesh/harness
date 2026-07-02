#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS="$REPO_ROOT/configs/shared/hooks"

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

CONFIG_DIR="$TMP_DIR/claude"
STATE_DIR="$TMP_DIR/state"
mkdir -p "$CONFIG_DIR" "$STATE_DIR"

run_activate() {
  CLAUDE_CONFIG_DIR="$CONFIG_DIR" HUMANIZE_DEFAULT_MODE=on node "$HOOKS/humanize-activate.js"
}

run_tracker() {
  CLAUDE_CONFIG_DIR="$CONFIG_DIR" HUMANIZE_STATE_DIR="$STATE_DIR" \
    node "$HOOKS/humanize-mode-tracker.js" <<<"$1"
}

payload() {
  jq -n --arg id "$1" '{session_id: $id, prompt: "continue the work"}'
}

echo ""

OUT=$(run_activate)
assert "activate injects the digest, not full skill" 'printf "%s" "$OUT" | grep -q "Humanize Digest"'
assert "activate payload stays under 2000 bytes" '[ "$(printf "%s" "$OUT" | wc -c)" -lt 2000 ]'
assert "activate sets the flag file" '[ -f "$CONFIG_DIR/.humanize-active" ]'

SESSION="hum-session-001"
OUT=$(run_tracker "$(payload "$SESSION")")
assert "1st prompt reminds" 'printf "%s" "$OUT" | grep -q "HUMANIZE MODE ACTIVE"'

OUT=$(run_tracker "$(payload "$SESSION")")
OUT2=$(run_tracker "$(payload "$SESSION")")
assert "2nd and 3rd prompts stay silent" '[ -z "$OUT" ] && [ -z "$OUT2" ]'

OUT=$(run_tracker "$(payload "$SESSION")")
assert "4th prompt reminds again" 'printf "%s" "$OUT" | grep -q "HUMANIZE MODE ACTIVE"'

OUT=$(run_tracker '{"prompt": "no session id here"}')
assert "missing session id falls back to reminding" 'printf "%s" "$OUT" | grep -q "HUMANIZE MODE ACTIVE"'

OUT=$(run_tracker "$(jq -n --arg id "$SESSION" '{session_id: $id, prompt: "/humanize off"}')")
assert "/humanize off silences tracker" '[ -z "$OUT" ] && [ ! -f "$CONFIG_DIR/.humanize-active" ]'

echo ""
echo "humanize-hooks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
