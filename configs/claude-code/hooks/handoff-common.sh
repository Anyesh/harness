#!/usr/bin/env bash
# Shared by the handoff hooks and handoff-digest.sh, which must agree on where handoffs and
# the pointer live and how the pointer is keyed.

HANDOFF_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for candidate in "$HANDOFF_COMMON_DIR" "$HANDOFF_COMMON_DIR/../../shared/hooks"; do
  if [[ -f "$candidate/harness-project.sh" ]]; then
    # shellcheck source=/dev/null
    source "$candidate/harness-project.sh"
    break
  fi
done

# Outside ~/.claude because every claude-profile has its own config dir; a profile path
# would need a symlink, which find and rg do not follow, so agents searching it miss them.
handoff_out_root() {
  printf '%s\n' "${HARNESS_HANDOFF_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/harness/handoffs}"
}

handoff_project_dir() {
  local cwd="$1" root
  declare -F harness_project_slug >/dev/null || return 1
  root="$(harness_repo_root "$(jq -nc --arg c "$cwd" '{workspace_roots:[$c]}')")"
  printf '%s/%s\n' "$(handoff_out_root)" "$(harness_project_slug "$root")"
}

handoff_pending_dir() {
  printf '%s/.pending\n' "$(handoff_out_root)"
}

# The claude process survives /clear, so its pid is the one key both hooks can compute
# for the same conversation. $CLAUDE_PID is set by Claude Code for hook commands; the
# ancestor walk covers hosts that do not set it.
handoff_claude_pid() {
  if [[ "${CLAUDE_PID:-}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$CLAUDE_PID"
    return 0
  fi

  local pid="${1:-$$}" fallback="" comm depth
  for depth in 1 2 3 4 5 6 7 8; do
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )) || break
    comm="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')"
    case "$comm" in
      claude|node) printf '%s\n' "$pid"; return 0 ;;
      bash|sh|zsh|dash|fish|"") ;;
      *) [[ -n "$fallback" ]] || fallback="$pid" ;;
    esac
  done

  [[ -n "$fallback" ]] || return 1
  printf '%s\n' "$fallback"
}

handoff_prune() {
  find "$(handoff_pending_dir)" -maxdepth 1 -name '*.json' -mtime +0 -delete 2>/dev/null || true
}
