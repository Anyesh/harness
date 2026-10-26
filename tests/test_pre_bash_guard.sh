#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export HARNESS_BLOCK_LOG=/dev/null
unset HARNESS_WORK WIKI_VAULT WIKI_WORK_PROJECTS
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

run_hook 'rm -fr /srv/data/redraft/build'
assert "allows rm -fr on an absolute path" '[ "$RC" -eq 0 ]'

run_hook 'cd build && rm -rf *'
assert "allows rm -rf with a glob" '[ "$RC" -eq 0 ]'

run_hook 'git push --force origin master'
assert "blocks force push to master" '[ "$RC" -eq 2 ]'

run_hook 'mkfs.ext4 /dev/sdb1'
assert "blocks mkfs" '[ "$RC" -eq 2 ]'

run_hook 'ls -la'
assert "allows a plain command" '[ "$RC" -eq 0 ]'

echo "--- commands that must still be blocked"
deny() { run_hook "$1"; assert "blocks: $2" '[ "$RC" -eq 2 ]'; }
allow() { run_hook "$1"; assert "allows: $2" '[ "$RC" -eq 0 ]'; }

deny 'sudo shutdown -h now' "sudo shutdown"
deny 'echo bye; reboot' "reboot after ;"
deny 'ssh host "reboot"' "reboot over ssh"
deny 'bash -c "shutdown now"' "shutdown in bash -c"
deny $'bash <<EOF\nreboot\nEOF' "reboot in a heredoc fed to bash"
deny 'sudo systemctl stop docker' "stopping docker"
deny 'git push --force-with-lease=main:abc123 origin rewritten:main' "force-with-lease onto main"
deny 'sudo dd if=/dev/zero of=/dev/sda bs=1M' "dd from /dev"
deny 'init 0' "init 0"
deny 'git push origin main --force' "force flag after the branch"
deny 'git push origin master -f' "short force flag after the branch"

echo "--- text that only mentions dangerous words"
allow 'grep -n "async shutdown\|stopAll" pool.ts' "shutdown inside a grep pattern"
allow $'python3 - <<\'EOF\'\ns = s.replace("shutdown", "reboot")\nEOF' "heredoc fed to python"
allow $'cat > clean.sh <<\'EOF\'\nsystemctl stop docker\nEOF' "writing a script that stops docker"
allow 'ssh -o BatchMode=yes u@h "wsl.exe --shutdown"' "wsl --shutdown flag"
allow 'git push origin feat --force-with-lease; git checkout -q master' "force push of a feature branch before checking out master"
allow 'git commit -m "docs: explain git push --force origin main"' "commit message quoting a force push"
allow 'curl -d '"'"'{"note":"reboot the box"}'"'"' http://x' "request body mentioning reboot"

echo "--- python environments go through uv"
deny 'pip install requests' "pip install"
deny 'pip3 install x' "pip3 install"
deny 'python3 -m pip install x' "python3 -m pip install"
deny 'python -m venv .venv' "python -m venv"
deny '.venv/bin/pip install x' "venv pip by path"
deny 'cd app && sudo pip install x' "sudo pip install after cd"
deny 'python3.12 -m venv env' "versioned python -m venv"
deny 'virtualenv env' "virtualenv"
deny 'pip3.12 install x' "versioned pip install"
deny 'python3 -m virtualenv env' "python -m virtualenv"
deny 'pip -q install x' "pip install with a flag before install"
allow 'uv pip install x' "uv pip install"
allow 'uv add requests' "uv add"
allow 'uv venv' "uv venv"
allow 'pip list' "pip list"
allow 'pip show x' "pip show"
allow 'git commit -m "drop pip install"' "commit message mentioning pip install"
allow 'grep "pip install" README.md' "grep for pip install"
allow 'uv run python -m pytest' "uv run python -m"

OUT=$(jq -n --arg c 'pip install requests' '{hook_event_name: "PreToolUse", tool_input: {command: $c}}' | bash "$HOOK" 2>&1 >/dev/null || true)
assert "pip block names uv" 'grep -q "uv add" <<<"$OUT"'
CURSOR_OUT=$(jq -n --arg c 'pip install requests' '{hook_event_name: "beforeShellExecution", command: $c}' | bash "$HOOK" 2>/dev/null || true)
assert "pip block uses Cursor deny output" '[ "$(jq -r .permission <<<"$CURSOR_OUT")" = deny ]'

SB_ENV=$(mktemp)
printf 'HARNESS_WORK=1\n' >"$SB_ENV"
HARNESS_ENV="$SB_ENV" run_hook 'sb recall "deploy notes"'
assert "a work machine blocks sb recall" '[ "$RC" -eq 2 ]'
HARNESS_ENV="$SB_ENV" run_hook 'cd /tmp && sb context harness'
assert "a work machine blocks sb context" '[ "$RC" -eq 2 ]'
HARNESS_ENV="$SB_ENV" HARNESS_WORK=0 run_hook 'sb recall x'
assert "a personal profile on a work machine may recall" '[ "$RC" -eq 0 ]'
: >"$SB_ENV"
HARNESS_ENV="$SB_ENV" run_hook 'sb recall x'
assert "a personal machine may recall" '[ "$RC" -eq 0 ]'
HARNESS_ENV="$SB_ENV" HARNESS_WORK=1 run_hook 'sb recall x'
assert "a work profile on a personal machine blocks sb recall" '[ "$RC" -eq 2 ]'
HARNESS_ENV="$SB_ENV" HARNESS_WORK=1 run_hook 'git commit -m "sb recall is blocked for work"'
assert "a commit message mentioning sb recall passes" '[ "$RC" -eq 0 ]'
HARNESS_ENV="$SB_ENV" HARNESS_WORK=1 run_hook 'sb sync-export > /tmp/all.jsonl'
assert "a work session cannot export the store" '[ "$RC" -eq 2 ]'
HARNESS_ENV="$SB_ENV" HARNESS_WORK=1 run_hook 'curl -s http://127.0.0.1:7200/recall?q=x'
assert "a work session cannot query the daemon over HTTP" '[ "$RC" -eq 2 ]'
HARNESS_ENV="$SB_ENV" HARNESS_WORK=1 run_hook 'second-brain-api --help'
assert "a work session cannot run the daemon binary" '[ "$RC" -eq 2 ]'
for cmd in 'env sb recall x' 'FOO=1 sb recall x' 'env -i FOO=1 sb recall x' 'time sb recall x' 'echo x | xargs sb recall' 'xargs -n1 sb recall < q'; do
  HARNESS_ENV="$SB_ENV" HARNESS_WORK=1 run_hook "$cmd"
  assert "a work session cannot reach sb through a prefix: $cmd" '[ "$RC" -eq 2 ]'
done
run_hook 'env UV_CACHE=1 pip install requests'
assert "an env prefix does not hide pip" '[ "$RC" -eq 2 ]'
HARNESS_ENV="$SB_ENV" HARNESS_WORK=1 run_hook 'sbt compile && ls sb'
assert "a work session may run commands that only start with sb" '[ "$RC" -eq 0 ]'
HARNESS_ENV="$SB_ENV" run_hook 'sb sync-export > /tmp/all.jsonl'
assert "a personal session may export the store" '[ "$RC" -eq 0 ]'
rm -f "$SB_ENV"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
