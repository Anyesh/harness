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

serena_python() {
  local serena_bin shebang
  local -a interp
  serena_bin=$(command -v serena) || return 1
  shebang=$(head -n1 "$serena_bin")
  [[ "$shebang" == '#!'* ]] || return 1
  read -r -a interp <<< "${shebang#\#!}"
  # WHY: uv tool shims use an absolute interpreter path, but pip/pipx-style
  # installs can use `#!/usr/bin/env python3`; take the program env would run.
  if [[ "$(basename "${interp[0]}")" == "env" ]]; then
    interp=("${interp[@]:1}")
  fi
  [[ ${#interp[@]} -gt 0 ]] || return 1
  printf '%s\n' "${interp[0]}"
}

serena_detect_languages() {
  local abs_path="$1"
  local py err_file detected
  if ! py=$(serena_python); then
    log_warn "serena language detection failed: cannot find serena's python interpreter"
    return 1
  fi
  err_file=$(mktemp)
  if ! detected=$("$py" "$REPO_ROOT/lib/serena_detect_languages.py" "$abs_path" 2>"$err_file") || [[ -z "$detected" ]]; then
    log_warn "serena language detection failed: $(tail -n1 "$err_file")"
    rm -f "$err_file"
    return 1
  fi
  rm -f "$err_file"
  printf '%s\n' "$detected"
}

serena_configure_languages() {
  local abs_path="$1"
  local yml="$abs_path/.serena/project.yml"

  if ! command -v serena &>/dev/null; then
    log_warn "serena not on PATH, skipping language setup (install it with: install.sh --only serena)"
    return 0
  fi

  local detected languages=()
  if detected=$(serena_detect_languages "$abs_path"); then
    mapfile -t languages <<< "$detected"
  fi

  if [[ ! -f "$yml" ]]; then
    local create_args=(project create "$abs_path")
    if [[ ${#languages[@]} -eq 0 ]]; then
      log_warn "letting serena infer a single language instead (check $yml afterwards)"
    else
      local lang
      for lang in "${languages[@]}"; do
        create_args+=(--language "$lang")
      done
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would run: serena ${create_args[*]}"
      return 0
    fi
    if serena "${create_args[@]}"; then
      log_update "serena project.yml: ${languages[*]:-inferred by serena}"
    else
      log_warn "serena project create failed, run manually: serena ${create_args[*]}"
    fi
    return 0
  fi

  if [[ ${#languages[@]} -eq 0 ]]; then
    log_warn "serena language detection failed, leaving $yml as is"
    return 0
  fi

  local missing
  missing=$(python3 "$REPO_ROOT/lib/serena_languages.py" missing "$yml" "${languages[@]}" | tr '\n' ' ')
  missing="${missing% }"
  if [[ -z "$missing" ]]; then
    log_skip "serena languages" "already configured (${languages[*]})"
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would add serena languages: $missing"
    return 0
  fi
  [[ "$NO_BACKUP" == "false" ]] && backup_file "$yml"
  python3 "$REPO_ROOT/lib/serena_languages.py" add "$yml" "${languages[@]}"
  log_update "serena languages added: $missing (restart the serena MCP server to pick them up)"
}
