#!/bin/bash
set -euo pipefail

input=$(cat)
# Cursor beforeShellExecution: command at top level
# Claude Code PreToolUse: command nested under tool_input
command=$(echo "$input" | jq -r '.command // .tool_input.command // empty')
hook_event=$(echo "$input" | jq -r '.hook_event_name // empty')

if [ -z "$command" ]; then
  exit 0
fi

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=log-block.sh
source "$HOOK_DIR/log-block.sh"
harness_log_block_on_exit pre-bash-guard "$input"

# shellcheck source=shell-code.sh
source "$HOOK_DIR/shell-code.sh"
# Match the code that runs, not quoted text or heredocs fed to other programs,
# so commit messages and grep patterns that mention these commands pass.
code=$(printf '%s\n' "$command" | shell_code keep)

# A command word only counts at a command position (so `wsl.exe --shutdown`
# passes), and $seg keeps a match inside one simple command so `;` or `&&`
# cannot join a feature-branch push to a later `git checkout master`.
at="$SHELL_CMD_START"
seg='[^;&|]*'
force='(\s-f\b|\s--force)'

dangerous=(
  "${at}mkfs(\.|\s)"
  "${at}dd\s${seg}if=/dev"
  '>\s*/dev/sd'
  "${at}chmod\s+-R\s+777\s+/"
  "${at}chown\s+-R\s${seg}\s/"
  "${at}git\s+push\b(${seg}${force}${seg}\b(main|master)\b|${seg}\b(main|master)\b${seg}${force})"
  "${at}shutdown\b"
  "${at}reboot\b"
  "${at}init\s+[06]\b"
  ':\(\)\s*\{'
  "${at}systemctl\s+(stop|disable|mask)\s+(docker|sshd|network)"
  "${at}iptables\s+-F\b"
)

for pattern in "${dangerous[@]}"; do
  if printf '%s\n' "$code" | grep -qEi "$pattern"; then
    msg="BLOCKED by pre-bash-guard: matches dangerous pattern /$pattern/. If this is intentional, run the command manually."
    if [[ "$hook_event" == "beforeShellExecution" ]]; then
      # Cursor beforeShellExecution uses permission/user_message output
      harness_log_block pre-bash-guard "$input"
      jq -cn --arg m "$msg" '{permission: "deny", user_message: $m}'
      exit 0
    else
      # Claude Code PreToolUse uses decision/reason output
      jq -cn --arg m "$msg" '{decision: "deny", reason: $m}' >&2
      exit 2
    fi
  fi
done

exit 0
