#!/bin/bash
input=$(cat)
plan=$(printf '%s' "$input" | jq -r '.tool_input.plan // empty' 2>/dev/null) || exit 0
[ -n "$plan" ] || exit 0

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=log-block.sh
source "$HOOK_DIR/log-block.sh"
harness_log_block_on_exit pre-plan-summary-guard "$input"

MAX_BULLETS=5
MAX_CHARS=200

first_h2=$(printf '%s\n' "$plan" | grep -m1 -E '^##[[:space:]]' || true)
summary=$(printf '%s\n' "$plan" | awk '
  /^#/ { if (in_s) exit; if (tolower($0) ~ /^##[[:space:]]+in short[[:space:]]*$/) { in_s = 1; next } }
  in_s && /^[[:space:]]*[-*][[:space:]]/ { print }
')
bullets=$(printf '%s' "$summary" | grep -c . || true)
longest=$(printf '%s\n' "$summary" | awk '{ n = length($0); if (n > m) m = n } END { print m + 0 }')

block() {
  echo "BLOCKED by pre-plan-summary-guard: $1 The user approves plans by reading the top, so the first section under the title must be \`## In short\`: 2 to $MAX_BULLETS one-line bullets in everyday words saying what we are changing, why, what the user will notice afterwards, and anything that needs their call. No file paths, function names or jargon there. Edit the plan file and call ExitPlanMode again." >&2
  exit 2
}

if ! printf '%s' "$first_h2" | grep -qiE '^##[[:space:]]+in short[[:space:]]*$'; then
  block "The plan's first section is \`${first_h2:-none}\`, not \`## In short\`."
fi
[ "$bullets" -ge 2 ] && [ "$bullets" -le "$MAX_BULLETS" ] || block "\`## In short\` has $bullets bullets."
[ "$longest" -le "$MAX_CHARS" ] || block "A bullet in \`## In short\` runs $longest characters; keep each under $MAX_CHARS."
exit 0
