#!/bin/bash
input=$(cat)
command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$command" ] || exit 0

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=log-block.sh
source "$HOOK_DIR/log-block.sh"
harness_log_block_on_exit pre-bash-interactive-alias "$input"

# Only rm is watched. The Bash tool's stdin is /dev/null, so an -i prompt reads
# EOF as "no": cp, mv and ln then exit 1 on an existing target (and just work
# on a new one), which the agent sees, but rm keeps the file and still exits 0.
# Verified on GNU coreutils 9.4.
printf '%s' "$command" | grep -qE '(^|[^[:alnum:]_./-])rm([^[:alnum:]_-]|$)' || exit 0

# The Bash tool sources its shell snapshot, so it is the only place that shows the
# aliases the agent's shell really has, unlike this hook's own non-interactive shell.
snapshot_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/shell-snapshots"
snapshot=$(ls -t "$snapshot_dir"/snapshot-* 2>/dev/null | head -1)
[ -n "$snapshot" ] || exit 0
definition=$(grep -E "^alias (-- )?rm='" "$snapshot" | head -1 | sed -E "s/^alias (-- )?rm='(.*)'\$/\2/")
[ -n "$definition" ] || exit 0
printf '%s' "$definition" | grep -qE '(^| )-[a-zA-Z]*[iI][a-zA-Z]*( |$)|--interactive' || exit 0

# shellcheck source=shell-code.sh
source "$HOOK_DIR/shell-code.sh"
code=$(printf '%s\n' "$command" | shell_code)

# GNU rm honours whichever of -f and -i/-I comes last, and the alias puts -i
# first, so an explicit -f anywhere in the invocation means no prompt.
rm_prompts() {
  local invocation word last
  local -a words
  while IFS= read -r invocation; do
    last=i
    read -ra words <<<"${invocation#*rm}"
    for word in "${words[@]}"; do
      case "$word" in
        --) break ;;
        --force) last=f ;;
        --interactive*) last=i ;;
        --*) ;;
        -*)
          word=${word#-}
          word=${word//[!fiI]/}
          [ -n "$word" ] && last=${word: -1}
          ;;
      esac
    done
    [ "$last" = f ] || return 0
  done < <(printf '%s\n' "$code" | grep -oE "(^|[;&|(]|\\$\\()[[:space:]]*rm([[:space:]][^;&|)]*|[;&|)]|\$)")
  return 1
}
rm_prompts || exit 0

echo "BLOCKED by pre-bash-interactive-alias: \`rm\` is aliased to \`$definition\` in this shell. With no terminal the prompt reads EOF as \"no\", so rm keeps the file and still exits 0. Re-run with \`command rm\` (for example \`command rm -f path\`)." >&2
exit 2
