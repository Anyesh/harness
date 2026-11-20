#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export HARNESS_BLOCK_LOG=/dev/null
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

run_hook 'cd /srv && docker logs web'
assert "blocks docker logs after cd" '[ "$RC" -eq 2 ]'

run_hook 'K=$(cat ~/.config/app/token); curl -s -o /tmp/b.out http://x'
assert "allows cat of a token when a later word ends in .out" '[ "$RC" -eq 0 ]'

run_hook $'cat > poll.sh <<\'E\'\ncurl -o r.out http://x\nE'
assert "allows writing a file with cat" '[ "$RC" -eq 0 ]'

run_hook 'git commit -m "explain why tail -n 500 build.log is blocked"'
assert "allows a commit message that quotes a big tail" '[ "$RC" -eq 0 ]'

run_hook 'cat notes.txt > run.log'
assert "allows cat redirected into a log" '[ "$RC" -eq 0 ]'

echo "=== cost-guard: crew worker rules ==="

WTMP=$(mktemp -d)
trap 'command rm -rf "$WTMP"' EXIT
seq 1 900 >"$WTMP/long.txt"
seq 1 100 >"$WTMP/short.txt"
head -c 70000 /dev/zero | tr '\0' 'a' >"$WTMP/wide.txt"
head -c 70000 /dev/zero >"$WTMP/shot.png"

run_read() {
  local payload
  payload=$(jq -n --arg p "$1" --argjson l "${2:-null}" \
    '{hook_event_name: "PreToolUse", tool_name: "Read", tool_input: ({file_path: $p} + (if $l == null then {} else {limit: $l} end))}')
  RC=0
  ERR=$(printf '%s' "$payload" | bash "$HOOK" 2>&1 >/dev/null) || RC=$?
}
worker_hook() {
  HARNESS_UNATTENDED=1 run_hook "$1"
}

run_read "$WTMP/long.txt"
assert "a non-worker may read a long file whole" '[ "$RC" -eq 0 ]'
HARNESS_UNATTENDED=1 run_read "$WTMP/long.txt"
assert "a worker is blocked reading a long file with no limit" '[ "$RC" -eq 2 ]'
HARNESS_UNATTENDED=1 run_read "$WTMP/long.txt" 200
assert "a worker may read a long file with a limit" '[ "$RC" -eq 0 ]'
HARNESS_UNATTENDED=1 run_read "$WTMP/wide.txt"
assert "a worker is blocked reading a file over 60 KB with no limit" '[ "$RC" -eq 2 ]'
HARNESS_UNATTENDED=1 run_read "$WTMP/short.txt"
assert "a worker may read a short file whole" '[ "$RC" -eq 0 ]'
HARNESS_UNATTENDED=1 run_read "$WTMP/shot.png"
assert "a worker may read an image of any size" '[ "$RC" -eq 0 ]'
HARNESS_UNATTENDED=1 run_read "$WTMP/missing.txt"
assert "a worker may read a missing path" '[ "$RC" -eq 0 ]'

run_hook 'pytest tests/'
assert "a non-worker may run pytest unfiltered" '[ "$RC" -eq 0 ]'

for runner in 'pytest tests/' 'uv run pytest -x' 'python3 -m pytest' 'npx jest' 'npx vitest run' 'go test ./...' 'cargo test' 'npm test' 'npm run test' 'pnpm test' 'yarn test' 'make test' 'crew-light pytest -q' 'cd app && uv run pytest'; do
  worker_hook "$runner"
  assert "a worker is blocked running: $runner" '[ "$RC" -eq 2 ]'
  worker_hook "$runner 2>&1 | tail -n 40"
  assert "a worker may run piped to tail: $runner" '[ "$RC" -eq 0 ]'
  worker_hook "$runner | grep -E 'FAILED|passed'"
  assert "a worker may run piped to grep: $runner" '[ "$RC" -eq 0 ]'
  worker_hook "$runner > /tmp/t.log 2>&1"
  assert "a worker may run redirected to a file: $runner" '[ "$RC" -eq 0 ]'
done

worker_hook 'pytest tests/ 2>&1 | head -50'
assert "a worker may pipe a test run to head" '[ "$RC" -eq 0 ]'
worker_hook 'pytest tests/ 2>&1'
assert "2>&1 alone does not bound a test run" '[ "$RC" -eq 2 ]'
worker_hook 'pytest tests/ 2>/dev/null'
assert "silencing stderr alone does not bound a test run" '[ "$RC" -eq 2 ]'
worker_hook 'crew-red A pytest tests/test_x.py'
assert "crew-red keeps only an output tail and is exempt" '[ "$RC" -eq 0 ]'
worker_hook 'git commit -m "run pytest and npm test before pushing"'
assert "a worker may commit a message that names a test runner" '[ "$RC" -eq 0 ]'
worker_hook $'cat > notes.md <<\'E\'\nrun pytest tests/\nE'
assert "a worker may write a heredoc that names a test runner" '[ "$RC" -eq 0 ]'
worker_hook 'grep -rn "pytest" docs | head'
assert "a worker may grep for a test runner name" '[ "$RC" -eq 0 ]'
worker_hook 'pip install pytest'
assert "installing a test runner is not running it" '[ "$RC" -eq 0 ]'
worker_hook 'make test-data'
assert "a make target that merely starts with test is not a test run" '[ "$RC" -eq 0 ]'

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
