#!/bin/bash

# The single definition of "memory" (second-brain and the wiki/vault). Every
# installer path reads these lists, so a lite install skips the same set
# everywhere and adding a memory piece means editing this file only.
MEMORY_MODULES=(second-brain wiki)
MEMORY_HOOKS=(session-start-wiki.sh wiki-nudge.sh stop-wiki-enforce.sh session-end-ingest.sh)
MEMORY_RULES=(second-brain.mdc wiki-maintenance.mdc)
MEMORY_SKILLS=(wiki)
MEMORY_COMMANDS=(devlog plan decision)

NO_MEMORY="${HARNESS_NO_MEMORY:-}"
[[ "$NO_MEMORY" == "1" ]] || NO_MEMORY=""

profile_no_memory() {
  [[ -n "$NO_MEMORY" ]]
}

profile_is_memory_item() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

profile_is_memory_module() {
  profile_is_memory_item "$1" "${MEMORY_MODULES[@]}"
}

profile_skips_hook() {
  profile_no_memory && profile_is_memory_item "$1" "${MEMORY_HOOKS[@]}"
}

profile_skips_rule() {
  profile_no_memory && profile_is_memory_item "$1" "${MEMORY_RULES[@]}"
}

profile_skips_skill() {
  profile_no_memory && profile_is_memory_item "$1" "${MEMORY_SKILLS[@]}"
}

profile_skips_command() {
  profile_no_memory && profile_is_memory_item "${1%.md}" "${MEMORY_COMMANDS[@]}"
}

# Removes every memory reference from a JSON config in place: hook entries whose
# command names a MEMORY_HOOKS script, WIKI_VAULT, and the second-brain MCP
# entry. contains() rather than a regex because the script names hold dots.
# Emptied-array pruning is confined to .hooks so permissions.allow and
# permissions.deny, which are legitimately empty, are never touched.
strip_memory_json() {
  local file="$1" tmp
  tmp=$(mktemp)
  if ! jq --argjson names "$(printf '%s\n' "${MEMORY_HOOKS[@]}" | jq -R . | jq -s .)" '
    def memory_cmd: (.command // "") as $c | any($names[]; . as $n | $c | contains($n));
    (if has("hooks") then
       .hooks |= (
         with_entries(
           .value |= (
             map(if has("hooks") then .hooks |= map(select(memory_cmd | not)) else . end)
             | map(select(if has("hooks") then (.hooks | length) > 0 else (memory_cmd | not) end))
           )
         )
         | with_entries(select((.value | length) > 0))
       )
     else . end)
    | if (.env // null) != null then del(.env.WIKI_VAULT) else . end
    | if (.mcpServers // null) != null then del(.mcpServers["second-brain"]) else . end
    | if (.enabledMcpjsonServers // null) != null then .enabledMcpjsonServers -= ["second-brain"] else . end
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  \mv -f "$tmp" "$file"
}
