#!/usr/bin/env bash
# SessionStart hook: points a session at the crew memory of its repo, and a
# harness session at the rules waiting for promotion. Reads local files only.
input=$(cat 2>/dev/null || true)

lib=$(command -v crew-lib.sh) || exit 0
# shellcheck source=/dev/null
. "$lib"

cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)
main=$(crew_main "${cwd:-.}") || exit 0
store=$(crew_memory_dir)
lines=()

key=$(crew_mem_key "$main") || exit 0
entry="$store/repos/$key"
if [[ -d $entry ]]; then
  runs=0
  for d in "$entry"/runs/*/; do
    [[ -d $d ]] && runs=$((runs + 1))
  done
  lines+=("CREW-MEMORY: $entry, $runs runs")
fi

if [[ -f $main/install.sh && -f $main/configs/shared/skills/crew/SKILL.md && -f $store/rules/proposed.md ]]; then
  pending=$(grep -c '^- ' "$store/rules/proposed.md")
  ((pending > 0)) && lines+=("CREW-PROPOSALS: $pending pending")
fi

((${#lines[@]})) || exit 0
printf '%s\n' "${lines[@]}" | jq -Rsc '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: (. | rtrimstr("\n"))}}'
