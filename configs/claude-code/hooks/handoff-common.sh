#!/usr/bin/env bash
# Shared by the SessionEnd and SessionStart handoff hooks, which must agree on where the pointer lives and how it is keyed.

handoff_out_root() {
  printf '%s\n' "${HARNESS_HANDOFF_DIR:-$HOME/.claude/handoffs}"
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
  local root
  root="$(handoff_out_root)"
  find "$(handoff_pending_dir)" -maxdepth 1 -name '*.json' -mtime +0 -delete 2>/dev/null || true
  find "$root" -mindepth 2 -maxdepth 2 -name '*.md' -mtime +14 -delete 2>/dev/null || true
}
