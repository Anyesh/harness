#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HARNESS_ENV=$(mktemp)
RENDERED=$(mktemp)
export HARNESS_ENV
trap 'rm -f "$HARNESS_ENV" "$RENDERED"' EXIT

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/template.sh"

export HOME=/tmp/herdr-hooks-home

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

render_template "$REPO_ROOT/configs/codex/hooks.json" "$RENDERED"
assert "codex SessionStart runs herdr's agent-state hook" \
  "jq -e '[.hooks.SessionStart[].hooks[].command] | index(\"bash '\\''$HOME/.codex/herdr-agent-state.sh'\\'' session\")' '$RENDERED' >/dev/null"

render_template "$REPO_ROOT/configs/cursor/hooks.json" "$RENDERED"
assert "cursor sessionStart runs herdr's agent-state hook" \
  "jq -e '[.hooks.sessionStart[].command] | index(\"bash '\\''$HOME/.cursor/herdr-agent-state.sh'\\'' session\")' '$RENDERED' >/dev/null"

for pair in claude-code/hooks:claude codex:codex cursor:cursor; do
  dir="${pair%%:*}" id="${pair##*:}"
  script="$REPO_ROOT/configs/$dir/herdr-agent-state.sh"
  assert "vendored $id integration script is herdr's" \
    "grep -qx '# HERDR_INTEGRATION_ID=$id' '$script'"
done

assert "codex module deploys the script where herdr checks it" \
  "grep -q 'CODEX_CONFIG_DIR/herdr-agent-state.sh' '$REPO_ROOT/modules/codex.sh'"
assert "cursor module deploys the script where herdr checks it" \
  "grep -q 'CURSOR_CONFIG_DIR/herdr-agent-state.sh' '$REPO_ROOT/modules/cursor.sh'"

echo ""
echo "herdr agent hooks: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
