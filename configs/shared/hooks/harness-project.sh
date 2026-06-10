#!/bin/bash
# Resolve the open workspace project root and slug for harness hooks.
# User-level Cursor hooks run with cwd ~/.cursor/, so git rev-parse there
# yields ~/.cursor and slug "-cursor". Prefer workspace_roots / env vars.

harness_repo_root() {
  local input="${1:-}"
  local root

  root=$(printf '%s' "$input" | jq -r '.workspace_roots[0] // empty' 2>/dev/null || true)
  if [[ -z "$root" || "$root" == "null" ]]; then
    root="${CURSOR_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}"
  fi

  if [[ -n "$root" && -d "$root" ]]; then
    local git_root
    git_root=$(cd "$root" && git rev-parse --show-toplevel 2>/dev/null) || true
    if [[ -n "$git_root" ]]; then
      printf '%s' "$git_root"
      return 0
    fi
    printf '%s' "$root"
    return 0
  fi

  git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD"
}

harness_project_slug() {
  local root="$1"
  basename "$root" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g' \
    | sed 's/--*/-/g' \
    | sed 's/^-*//;s/-*$//'
}

harness_is_tooling_dir() {
  local root="$1"
  case "$root" in
    "$HOME/.cursor"|"$HOME/.claude"|"$HOME/.codex") return 0 ;;
  esac
  [[ "$(basename "$root")" == ".cursor" || "$(basename "$root")" == ".claude" ]] && return 0
  return 1
}
