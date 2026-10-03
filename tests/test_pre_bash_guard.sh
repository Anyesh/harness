#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export HARNESS_BLOCK_LOG=/dev/null
HOOK="$REPO_ROOT/configs/shared/hooks/pre-bash-guard.sh"

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
run_hook() {
  local payload
  payload=$(jq -n --arg c "$1" '{hook_event_name: "PreToolUse", tool_input: {command: $c}}')
  RC=0
  printf '%s' "$payload" | bash "$HOOK" >/dev/null 2>&1 || RC=$?
}

echo "=== pre-bash-guard ==="

run_hook 'rm -rf /tmp/claude-1000/scratch/dump'
assert "allows rm -rf on an absolute path" '[ "$RC" -eq 0 ]'

run_hook 'rm -r ~/.cache/old-models'
assert "allows rm -r under home" '[ "$RC" -eq 0 ]'

run_hook 'rm -fr /mnt/data/redraft/build'
assert "allows rm -fr on an absolute path" '[ "$RC" -eq 0 ]'

run_hook 'cd build && rm -rf *'
assert "allows rm -rf with a glob" '[ "$RC" -eq 0 ]'

run_hook 'git push --force origin master'
assert "blocks force push to master" '[ "$RC" -eq 2 ]'

run_hook 'mkfs.ext4 /dev/sdb1'
assert "blocks mkfs" '[ "$RC" -eq 2 ]'

run_hook 'ls -la'
assert "allows a plain command" '[ "$RC" -eq 0 ]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
