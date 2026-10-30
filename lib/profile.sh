#!/bin/bash

# The single definition of "memory" (second-brain and the wiki/vault). Every
# installer path reads these lists, so a lite install skips the same set
# everywhere and adding a memory piece means editing this file only.
MEMORY_MODULES=(second-brain wiki wiki-sync)
MEMORY_HOOKS=(session-start-wiki.sh wiki-nudge.sh stop-wiki-enforce.sh session-end-ingest.sh wiki-index-build.sh)
MEMORY_RULES=(second-brain.mdc wiki-maintenance.mdc)
MEMORY_SKILLS=(wiki)
MEMORY_COMMANDS=(devlog plan decision)
MEMORY_MCP_SERVERS=(second-brain)

NO_MEMORY="${HARNESS_NO_MEMORY:-}"
[[ "$NO_MEMORY" == "1" ]] || NO_MEMORY=""

# What a work install keeps away from the model: personal recall, personal
# infrastructure facts, and the rule that steers toward the user's own endpoints.
WORK_RULES=(second-brain.mdc llm-preference.mdc)
WORK_SKILLS=(me)
WORK_MCP_SERVERS=(second-brain)

# shellcheck source=../configs/shared/hooks/load-harness-env.sh
declare -f harness_work_vault >/dev/null 2>&1 ||
  source "$(dirname "${BASH_SOURCE[0]}")/../configs/shared/hooks/load-harness-env.sh"

# Read from the file only, never the environment: Claude exports a profile's
# settings env into agent shells, so an install started from a profile session
# would otherwise take that profile's state for the whole machine.
WORK=""
[[ "$(harness_env_file_value HARNESS_WORK)" == "1" ]] && WORK=1

profile_no_memory() {
  [[ -n "$NO_MEMORY" ]]
}

profile_work() {
  [[ -n "$WORK" ]]
}

# The vault this install renders into rules and settings; empty when unset.
profile_wiki_vault() {
  local vault
  vault=$(harness_env_file_value WIKI_VAULT)
  [[ -n "$vault" ]] || return 0
  if profile_work; then
    harness_work_vault "$vault"
  else
    printf '%s' "$vault"
  fi
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
  { profile_no_memory && profile_is_memory_item "$1" "${MEMORY_RULES[@]}"; } ||
    { profile_work && profile_is_memory_item "$1" "${WORK_RULES[@]}"; }
}

profile_skips_skill() {
  { profile_no_memory && profile_is_memory_item "$1" "${MEMORY_SKILLS[@]}"; } ||
    { profile_work && profile_is_memory_item "$1" "${WORK_SKILLS[@]}"; }
}

profile_skips_mcp_server() {
  { profile_no_memory && profile_is_memory_item "$1" "${MEMORY_MCP_SERVERS[@]}"; } ||
    { profile_work && profile_is_memory_item "$1" "${WORK_MCP_SERVERS[@]}"; }
}

# Drops the work MCP servers from a JSON config in place. Only runs for work
# installs; memory-off installs already lose them through strip_memory_json.
strip_work_json() {
  local file="$1" tmp
  profile_work || return 0
  tmp=$(mktemp)
  if ! jq --argjson servers "$(printf '%s\n' "${WORK_MCP_SERVERS[@]}" | jq -R . | jq -s .)" '
    (if (.mcpServers // null) != null then del(.mcpServers[$servers[]]) else . end)
    | (if (.mcp // null) != null then del(.mcp[$servers[]]) else . end)
    | (if (.enabledMcpjsonServers // null) != null then .enabledMcpjsonServers -= $servers else . end)
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  \mv -f "$tmp" "$file"
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
  if ! jq --argjson names "$(printf '%s\n' "${MEMORY_HOOKS[@]}" | jq -R . | jq -s .)" \
    --argjson servers "$(printf '%s\n' "${MEMORY_MCP_SERVERS[@]}" | jq -R . | jq -s .)" '
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
    | if (.mcpServers // null) != null then del(.mcpServers[$servers[]]) else . end
    | if (.enabledMcpjsonServers // null) != null then .enabledMcpjsonServers -= $servers else . end
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  \mv -f "$tmp" "$file"
}
