#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../configs/shared/hooks/shell-code.sh
source "$REPO_ROOT/configs/shared/hooks/shell-code.sh"

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

code() { printf '%s\n' "$1" | shell_code; }
keep() { printf '%s\n' "$1" | shell_code keep; }
has() { grep -qF -- "$2" <<<"$1"; }

echo "=== shell-code: strip mode ==="
assert "double-quoted text is dropped" '! has "$(code "git commit -m \"a; rm b\"")" "rm b"'
assert "single-quoted text is dropped" '! has "$(code "echo '"'"'x; rm y'"'"'")" "rm y"'
assert "escaped quote does not end the string" '! has "$(code "echo \"a \\\" ; rm b\"")" "rm b"'
assert "code after a closed string stays" 'has "$(code "echo \"hi\"; rm x")" "rm x"'
assert "backslash outside quotes keeps the next char" 'has "$(code "echo a\\;b; rm x")" "rm x"'
assert "heredoc body is dropped" '! has "$(code $'"'"'cat <<EOF\nrm y\nEOF'"'"')" "rm y"'
assert "quoted heredoc delimiter is recognised" '! has "$(code $'"'"'cat <<"END"\nrm y\nEND'"'"')" "rm y"'
assert "code after the heredoc stays" 'has "$(code $'"'"'cat <<EOF\nhi\nEOF\nrm x'"'"')" "rm x"'
assert "<<- terminator may be tab-indented" 'has "$(code $'"'"'cat <<-EOF\nrm y\n\tEOF\nrm x'"'"')" "rm x" && ! has "$(code $'"'"'cat <<-EOF\nrm y\n\tEOF\nrm x'"'"')" "rm y"'
assert "here-string is not a heredoc" 'has "$(code $'"'"'grep x <<<"$v"\nrm x'"'"')" "rm x"'
assert "shell -c strings are dropped in strip mode" '! has "$(code "bash -c \"rm x\"")" "rm x"'
assert "command substitution inside quotes is code" 'has "$(code "echo \"now: \$(rm x) done\"")" "rm x"'
assert "text after a quoted command substitution is dropped" '! has "$(code "echo \"\$(date) ; rm y\"")" "rm y"'

echo ""
echo "=== shell-code: keep mode ==="
assert "bash -c string is code" 'has "$(keep "bash -c \"reboot now\"")" "; reboot now"'
assert "sudo sh -c string is code" 'has "$(keep "sudo sh -c '"'"'shutdown -h now'"'"'")" "; shutdown -h now"'
assert "ssh remote command is code" 'has "$(keep "ssh host \"reboot\"")" "; reboot"'
assert "ssh with options is code" 'has "$(keep "timeout 9 ssh -o BatchMode=yes u@h '"'"'wsl.exe --shutdown'"'"'")" "; wsl.exe --shutdown"'
assert "eval string is code" 'has "$(keep "eval \"reboot\"")" "; reboot"'
assert "heredoc into bash is code" 'has "$(keep $'"'"'bash <<EOF\nreboot\nEOF'"'"')" "reboot"'
SSH_HEREDOC=$'ssh host <<\'EOF\'\nreboot\nEOF'
assert "heredoc into ssh is code" 'has "$(keep "$SSH_HEREDOC")" "reboot"'
assert "heredoc into python is still data" '! has "$(keep $'"'"'python3 - <<EOF\nreboot\nEOF'"'"')" "reboot"'
assert "grep pattern is still data" '! has "$(keep "grep -n \"async shutdown\" f")" "shutdown"'
assert "echo text is still data" '! has "$(keep "echo \"reboot later\"")" "reboot"'

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
