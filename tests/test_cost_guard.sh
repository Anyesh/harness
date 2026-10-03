#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/configs/shared/hooks/cost-guard.sh"

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

RC=0
ERR=""
run_hook() {
  local payload
  payload=$(jq -n --arg c "$1" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}')
  RC=0
  ERR=$(printf '%s' "$payload" | bash "$HOOK" 2>&1 >/dev/null) || RC=$?
}

echo "=== cost-guard ==="

run_hook 'docker logs --tail 50 web'
assert "allows docker logs with --tail" '[ "$RC" -eq 0 ]'
assert "emits no grep option errors" '! grep -qi "invalid option\|unrecognized option" <<<"$ERR"'

run_hook 'kubectl logs --tail=20 pod/api'
assert "allows kubectl logs with --tail=" '[ "$RC" -eq 0 ]'

run_hook 'docker logs web'
assert "blocks docker logs without --tail" '[ "$RC" -eq 2 ]'

run_hook 'journalctl -u foo --limit 30'
assert "allows a command bounded by --limit" '[ "$RC" -eq 0 ]'

run_hook 'journalctl -u foo'
assert "blocks journalctl without -n" '[ "$RC" -eq 2 ]'

run_hook 'cat build/server.log'
assert "blocks cat on a log file" '[ "$RC" -eq 2 ]'

run_hook 'tail -n 500 build/server.log'
assert "blocks a large tail" '[ "$RC" -eq 2 ]'

run_hook 'tail build/server.log'
assert "allows a bare tail on a log file" '[ "$RC" -eq 0 ]'

run_hook 'tail -n 20 build/server.log'
assert "allows a small tail on a log file" '[ "$RC" -eq 0 ]'

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
