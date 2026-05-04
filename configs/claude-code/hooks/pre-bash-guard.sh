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

# Dangerous patterns — block and tell the agent to ask the user to run manually
dangerous=(
  'rm\s+-r[f]?\s+/'
  'rm\s+-r[f]?\s+~'
  'rm\s+-[f]?r\s+/'
  'rm\s+-[f]?r\s+~'
  'rm\s+-rf\s+\*$'
  'rm\s+-rf\s+\.$'
  'mkfs\.'
  'dd\s+if=/dev'
  '>\s*/dev/sd'
  'chmod\s+-R\s+777\s+/'
  'chown\s+-R\s+.*\s+/'
  'git\s+push\s+.*--force.*\b(main|master)\b'
  'git\s+push\s+-f.*\b(main|master)\b'
  'git\s+push\s+--force-with-lease.*\b(main|master)\b'
  '\bshutdown\b'
  '\breboot\b'
  '\binit\s+[06]\b'
  ':\(\)\s*\{'
  '\bsystemctl\s+(stop|disable|mask)\s+(docker|sshd|network)'
  '\biptables\s+-F\b'
)

for pattern in "${dangerous[@]}"; do
  if echo "$command" | grep -qEi "$pattern"; then
    msg="BLOCKED by pre-bash-guard: matches dangerous pattern. If this is intentional, run the command manually."
    if [[ "$hook_event" == "beforeShellExecution" ]]; then
      # Cursor beforeShellExecution uses permission/user_message output
      echo "{\"permission\": \"deny\", \"user_message\": \"$msg\"}"
      exit 0
    else
      # Claude Code PreToolUse uses decision/reason output
      echo "{\"decision\": \"deny\", \"reason\": \"$msg\"}" >&2
      exit 2
    fi
  fi
done

exit 0
