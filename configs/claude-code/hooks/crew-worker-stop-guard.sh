#!/usr/bin/env bash
# Stops a crew worker from ending a turn on a question the lead never sees:
# nobody watches a worker's pane, so a question is only heard through report.md.
input=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=log-block.sh
source "$HOOK_DIR/log-block.sh"
# shellcheck source=crew-hook-common.sh
source "$HOOK_DIR/crew-hook-common.sh"

[[ $(jq -r '.stop_hook_active // false' <<<"$input" 2>/dev/null) == true ]] && exit 0
[[ $(crew_hook_role "$input") == worker ]] || exit 0

transcript=$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null)
cwd=$(jq -r '.cwd // "."' <<<"$input" 2>/dev/null)
[[ -f "$transcript" ]] || exit 0

top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
[[ ${top##*/} == w-* ]] || exit 0
id=${top##*/w-}

last_text=$(tail -n 2000 "$transcript" | jq -rs '
  [.[] | select(.type == "assistant") | [.message.content[]? | select(.type == "text") | .text] | select(length > 0) | join("\n")]
  | last // ""')
last_line=$(awk 'NF { line = $0 } END { print line }' <<<"$last_text")
[[ $last_line =~ \?[\)\"\'\`*_]*[[:space:]]*$ ]] || exit 0

prompt_at=$(tail -n 2000 "$transcript" | jq -rs '
  [.[] | select(.type == "user" and (.isMeta | not)
      and (.message.content | if type == "string" then true else any(.[]; .type == "text") end))
    | .timestamp] | last // empty
  | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' 2>/dev/null)

lib=$(command -v crew-lib.sh) || exit 0
# shellcheck source=/dev/null
. "$lib"
crew=$(crew_dir "$cwd") || exit 0
report="$crew/items/$id/report.md"

if [[ -f "$report" && -n "$prompt_at" ]]; then
  written=$(stat -c %Y "$report" 2>/dev/null || stat -f %m "$report" 2>/dev/null)
  if [[ $written =~ ^[0-9]+$ ]] && ((written >= prompt_at)) &&
    grep -qE '^status:[[:space:]]*(question|blocked|handoff|done)\b' "$report"; then
    exit 0
  fi
fi

crew_hook_block crew-worker-stop-guard "your last message asks a question and report.md has no question, blocked, handoff or done status written since the last prompt: write it to report.md as status: question (with a fresh at: line), then stop" "$input"
