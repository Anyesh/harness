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

python_env=(
  "${at}(\S*/)?pip(3(\.[0-9]+)?)?(\s+-\S+)*\s+install\b"
  "${at}(\S*/)?python(3(\.[0-9]+)?)?\s+-m\s+(pip(\s+-\S+)*\s+install|venv|virtualenv)\b"
  "${at}virtualenv\b"
)

deny() {
  local msg="BLOCKED by pre-bash-guard: $1"
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
}

for pattern in "${dangerous[@]}"; do
  if printf '%s\n' "$code" | grep -qEi "$pattern"; then
    deny "matches dangerous pattern /$pattern/. If this is intentional, run the command manually."
  fi
done

for pattern in "${python_env[@]}"; do
  if printf '%s\n' "$code" | grep -qEi "$pattern"; then
    deny "use uv for Python environments: \`uv add\`, \`uv pip install\`, \`uv venv\`, \`uv run\`."
  fi
done

if printf '%s\n' "$code" | grep -qE "${at}(\S*/)?(sb|second-brain-[a-z]+)(\s|$)|(127\.0\.0\.1|localhost):7200\b"; then
  # shellcheck source=load-harness-env.sh
  source "$HOOK_DIR/load-harness-env.sh"
  load_harness_var HARNESS_WORK
  if [[ "${HARNESS_WORK:-}" == 1 ]]; then
    deny "second-brain holds the user's personal projects and is withheld from work sessions."
  fi
fi

exit 0
