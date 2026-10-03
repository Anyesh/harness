#!/bin/bash
# Records every guard block as one JSONL line so false positives show up as data
# (scripts/hook-blocks.sh) instead of waiting for an agent to complain.
# Sourced by bash guards; executed as `bash log-block.sh HOOK [DETAIL] <payload`
# by non-bash guards so every record has the same shape.
# A failed write must never change a guard's decision, so these functions
# discard their own errors and always return 0.

_HARNESS_BLOCK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

harness_log_block() {
  local hook="$1" input="$2" detail="${3:-}" log agent
  log="${HARNESS_BLOCK_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/harness/hook-blocks.jsonl}"
  agent=$("$_HARNESS_BLOCK_DIR/detect-agent.sh" <<<"$input" 2>/dev/null) || agent=unknown
  {
    mkdir -p "$(dirname "$log")" &&
      printf '%s' "$input" | jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg hook "$hook" \
        --arg agent "$agent" --arg detail "$detail" '{
          ts: $ts,
          hook: $hook,
          event: (.hook_event_name // ""),
          agent: $agent,
          tool: (.tool_name // ""),
          detail: ((if $detail != "" then $detail
                    else (.tool_input.command // .command // .tool_input.file_path // .tool_input.path
                          // .tool_input.notebook_path // .file_path // "") end)[0:500]),
          cwd: (.cwd // ""),
          session: (.session_id // .conversation_id // "")
        }' >>"$log"
  } 2>/dev/null
  return 0
}

# Logs when the guard exits 2, which covers guards with many separate
# `exit 2` sites without touching each one. Guards that deny through JSON on
# stdout and exit 0 must call harness_log_block themselves.
harness_log_block_on_exit() {
  _HARNESS_BLOCK_HOOK="$1"
  _HARNESS_BLOCK_INPUT="$2"
  trap '_harness_block_rc=$?; [ "$_harness_block_rc" -eq 2 ] && harness_log_block "$_HARNESS_BLOCK_HOOK" "$_HARNESS_BLOCK_INPUT"; exit "$_harness_block_rc"' EXIT
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  harness_log_block "$1" "$(cat)" "${2:-}"
fi
