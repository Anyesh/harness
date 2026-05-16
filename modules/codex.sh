#!/usr/bin/env bash

codex_check() {
    if [[ "$HAS_CODEX" != "true" ]]; then
        log_info "Codex not detected, skipping"
        return 1
    fi
    if [[ ! -d "$CODEX_CONFIG_DIR" ]]; then
        mkdir -p "$CODEX_CONFIG_DIR"
    fi
    return 0
}

codex_deploy_config() {
  local config_src="$REPO_ROOT/configs/codex/config.toml.tmpl"
  local instructions_src="$REPO_ROOT/configs/codex/instructions.md.tmpl"
  local hooks_src="$REPO_ROOT/configs/codex/hooks.json"

  if [[ -f "$config_src" ]] && ! head -1 "$config_src" | grep -q '^# harness does not manage'; then
    local dest="$CODEX_CONFIG_DIR/config.toml"
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would deploy codex config.toml"
    else
      [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"
      if deploy_template "$config_src" "$dest"; then
        manifest_add "$dest" "configs/codex/config.toml.tmpl" "true"
        log_success "codex config.toml deployed"
      else
        log_error "failed to deploy codex config.toml"
      fi
    fi
  fi

  if [[ -f "$instructions_src" ]]; then
    local dest="$CODEX_CONFIG_DIR/instructions.md"
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would deploy codex instructions.md"
    else
      [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"
      if deploy_template "$instructions_src" "$dest"; then
        manifest_add "$dest" "configs/codex/instructions.md.tmpl" "true"
        log_success "codex instructions.md deployed"
      else
        log_error "failed to deploy codex instructions.md"
      fi
    fi
  fi

  if [[ -f "$hooks_src" ]]; then
    local dest="$CODEX_CONFIG_DIR/hooks.json"
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would deploy codex hooks.json"
    else
      [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"
      if deploy_template "$hooks_src" "$dest"; then
        manifest_add "$dest" "configs/codex/hooks.json" "true"
        log_success "codex hooks.json deployed"
      else
        log_error "failed to deploy codex hooks.json"
      fi
    fi
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would deploy codex hook scripts"
    return
  fi

  local codex_hooks_dir="$CODEX_CONFIG_DIR/hooks"
  mkdir -p "$codex_hooks_dir"

  local shared_hooks=("pre-bash-guard.sh" "format-on-save.sh" "pre-edit-comment-guard.py" "cost-guard.sh" "stop-sloppiness-guard.sh")
  for hook in "${shared_hooks[@]}"; do
    local hook_src="$REPO_ROOT/configs/claude-code/hooks/$hook"
    local hook_dest="$codex_hooks_dir/$hook"
    if [[ -f "$hook_src" ]]; then
      cp "$hook_src" "$hook_dest"
      chmod +x "$hook_dest" 2>/dev/null || true
      manifest_add "$hook_dest" "configs/claude-code/hooks/$hook" "false"
      log_update "codex hook: $hook"
    fi
  done
}

codex_install() {
  codex_deploy_config
  deploy_shared_skills "$CODEX_CONFIG_DIR/skills"
}

codex_test() {
    return 0
}
