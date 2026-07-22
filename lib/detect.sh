#!/bin/bash

HAS_CLAUDE=false
HAS_CURSOR=false
HAS_CODEX=false
HAS_OPENCODE=false

CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CURSOR_CONFIG_DIR="${CURSOR_CONFIG_DIR:-$HOME/.cursor}"
CODEX_CONFIG_DIR="${CODEX_CONFIG_DIR:-$HOME/.codex}"
OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"

detect_tools() {
  if command -v claude &>/dev/null; then
    HAS_CLAUDE=true
  fi

  if command -v cursor &>/dev/null || [[ -d "$CURSOR_CONFIG_DIR" ]]; then
    HAS_CURSOR=true
  fi

  if command -v codex &>/dev/null || [[ -d "$CODEX_CONFIG_DIR" ]]; then
    HAS_CODEX=true
  fi

  if command -v opencode &>/dev/null || [[ -d "$OPENCODE_CONFIG_DIR" ]]; then
    HAS_OPENCODE=true
  fi

  log_info "Detected tools:"
  [[ "$HAS_CLAUDE" == "true" ]] && log_info "  Claude Code"
  [[ "$HAS_CURSOR" == "true" ]] && log_info "  Cursor"
  [[ "$HAS_CODEX" == "true" ]] && log_info "  Codex"
  [[ "$HAS_OPENCODE" == "true" ]] && log_info "  opencode"

  if [[ "$HAS_CLAUDE" == "false" && "$HAS_CURSOR" == "false" && "$HAS_CODEX" == "false" && "$HAS_OPENCODE" == "false" ]]; then
    die "No supported tools detected. Install Claude Code, Cursor, Codex, or opencode first."
  fi
}
