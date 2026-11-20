# shellcheck shell=bash
# Sourced by the crew hooks.

# Prints worker, lead or none for the session in $1 (the hook payload). Anything
# but a clean answer counts as none, so a broken or slow crew-role never blocks
# a session that is not in a crew.
crew_hook_role() {
  local session cwd args=()
  if [[ "${HARNESS_UNATTENDED:-}" == 1 ]]; then
    echo worker
    return 0
  fi
  session=$(jq -r '.session_id // empty' <<<"$1" 2>/dev/null) || return 1
  cwd=$(jq -r '.cwd // empty' <<<"$1" 2>/dev/null) || return 1
  [[ -n "$session" ]] && args+=(--session "$session")
  [[ -n "$cwd" ]] && args+=("$cwd")
  timeout 2 crew-role "${args[@]}" 2>/dev/null
}

# Emits a Stop-hook block for hook $1 with reason $2 and logs it against payload $3.
crew_hook_block() {
  harness_log_block "$1" "$3"
  jq -cn --arg m "BLOCKED by $1: $2" '{decision: "block", reason: $m}'
}
