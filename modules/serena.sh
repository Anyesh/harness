#!/usr/bin/env bash

serena_check() {
  if [[ "$HAS_CLAUDE" != "true" && "$HAS_CURSOR" != "true" ]]; then
    log_info "neither Claude Code nor Cursor detected, skipping serena"
    return 1
  fi
  if ! command -v uv &>/dev/null; then
    log_info "uv not found, serena requires uv (https://docs.astral.sh/uv/)"
    return 1
  fi
  return 0
}

serena_install() {
  if command -v serena &>/dev/null && [[ "$FORCE" != "true" ]]; then
    log_skip "serena" "already installed"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would install serena via uv tool install and run serena init"
    return 0
  fi

  if ! command -v uv &>/dev/null; then
    log_warn "uv not found, cannot install serena"
    log_warn "run manually: uv tool install -p 3.13 serena-agent"
    return 1
  fi

  local uv_flags=()
  if [[ "$FORCE" == "true" ]]; then
    uv_flags+=(--force)
  fi

  if ! uv tool install -p 3.13 "${uv_flags[@]}" serena-agent; then
    log_warn "serena install failed: run manually: uv tool install -p 3.13 serena-agent"
    return 1
  fi

  if ! command -v serena &>/dev/null; then
    log_warn "serena installed but binary not on PATH"
    return 1
  fi

  if serena init; then
    log_success "serena installed and initialized"
  else
    log_warn "serena init failed, run manually: serena init"
    return 1
  fi
}

serena_test() {
  local tmp_dir
  tmp_dir=$(mktemp -d)

  local orig_home="$HOME"
  local orig_dry="$DRY_RUN"

  export HOME="$tmp_dir"
  DRY_RUN=true

  local output
  output=$(serena_install 2>&1)

  HOME="$orig_home"
  DRY_RUN="$orig_dry"
  rm -rf "$tmp_dir"

  if ! echo "$output" | grep -q '\[dry-run\]'; then
    log_error "serena_test: no dry-run output produced"
    return 1
  fi

  return 0
}
