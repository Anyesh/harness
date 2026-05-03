#!/bin/bash
set -euo pipefail

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // empty')

if [ -z "$command" ]; then
  exit 0
fi

# Dangerous patterns — block and tell Claude to ask the user to run manually
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
    echo "{\"decision\": \"deny\", \"reason\": \"BLOCKED by pre-bash-guard: matches dangerous pattern. If this is intentional, the user should run the command manually with ! prefix.\"}" >&2
    exit 2
  fi
done

exit 0
