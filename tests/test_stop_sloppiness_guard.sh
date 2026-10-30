#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export HARNESS_BLOCK_LOG=/dev/null
HOOK="$REPO_ROOT/configs/shared/hooks/stop-sloppiness-guard.sh"
TEMPLATE="$REPO_ROOT/configs/claude-code/settings.json.tmpl"

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
export HOME="$TMP_DIR/home"
mkdir -p "$HOME"

transcript() {
  jq -cn --arg t "$2" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}' >"$1"
}

SLOPPY="$TMP_DIR/sloppy.jsonl"
CLEAN="$TMP_DIR/clean.jsonl"
transcript "$SLOPPY" "Let me just patch the parser with a quick fix."
transcript "$CLEAN" "I traced the failure to the parser, which drops the final token when the input lacks a trailing newline, and fixed the loop bound."

payload() {
  jq -cn --arg id "$1" --arg t "$2" --arg ev "${3:-Stop}" \
    '{session_id: $id, hook_event_name: $ev, transcript_path: $t}'
}

echo ""

OUT=$(bash "$HOOK" claude <<<"$(payload s-claude "$SLOPPY")")
assert "claude argument returns Stop additionalContext" \
  'printf "%s" "$OUT" | jq -e "(.hookSpecificOutput.hookEventName == \"Stop\") and (has(\"decision\") | not)" >/dev/null'
assert "the additionalContext names the flagged phrase" \
  'printf "%s" "$OUT" | jq -r ".hookSpecificOutput.additionalContext" | grep -qi "quick fix"'

OUT=$(bash "$HOOK" <<<"$(payload s-codex "$SLOPPY")")
assert "no argument (Codex) still blocks with a reason" \
  'printf "%s" "$OUT" | jq -e "(.decision == \"block\") and (.reason | test(\"quick fix\"; \"i\"))" >/dev/null'

OUT=$(bash "$HOOK" claude <<<"$(payload s-cursor "$SLOPPY" stop)")
assert "Cursor stop payload gets a followup_message even with the claude argument" \
  'printf "%s" "$OUT" | jq -e "(.followup_message | length > 0) and (has(\"hookSpecificOutput\") | not)" >/dev/null'

OUT=$(bash "$HOOK" claude <<<"$(payload s-clean "$CLEAN")")
assert "clean transcript stays silent" '[ -z "$OUT" ]'

assert "Claude settings template passes the claude argument" \
  'jq -e "[.hooks.Stop[].hooks[].command | select(test(\"stop-sloppiness-guard\\\\.sh claude$\"))] | length == 1" "$TEMPLATE" >/dev/null'

echo ""
echo "stop-sloppiness-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
