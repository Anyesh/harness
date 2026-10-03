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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
