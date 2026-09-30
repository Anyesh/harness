#!/bin/bash
input=$(cat)
command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$command" ] || exit 0

watched=(rm cp mv ln)

mentioned=()
for name in "${watched[@]}"; do
  if printf '%s' "$command" | grep -qE "(^|[^[:alnum:]_./-])$name([^[:alnum:]_-]|$)"; then
    mentioned+=("$name")
  fi
done
[ ${#mentioned[@]} -gt 0 ] || exit 0

# The Bash tool sources its shell snapshot, so it is the only place that shows the
# aliases the agent's shell really has, unlike this hook's own non-interactive shell.
snapshot_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/shell-snapshots"
snapshot=$(ls -t "$snapshot_dir"/snapshot-* 2>/dev/null | head -1)
[ -n "$snapshot" ] || exit 0

blocked=()
for name in "${mentioned[@]}"; do
  definition=$(grep -E "^alias (-- )?$name='" "$snapshot" | head -1 | sed -E "s/^alias (-- )?$name='(.*)'\$/\2/")
  [ -n "$definition" ] || continue
  printf '%s' "$definition" | grep -qE '(^| )-[a-zA-Z]*[iI][a-zA-Z]*( |$)|--interactive' || continue
  printf '%s' "$command" | grep -qE "(^|[;&|(]|\\$\\()[[:space:]]*$name([[:space:]]|\$)" || continue
  blocked+=("$name|$definition")
done
[ ${#blocked[@]} -gt 0 ] || exit 0

for entry in "${blocked[@]}"; do
  name="${entry%%|*}"
  definition="${entry#*|}"
  echo "BLOCKED by pre-bash-interactive-alias: in this shell \`$name\` is aliased to \`$definition\`, so it waits for a y/n answer that never comes. Re-run with \`command $name\` to bypass the alias (for example \`command $name -f path\` when you mean to overwrite or delete without prompts)." >&2
done
exit 2
