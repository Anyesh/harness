#!/usr/bin/env bash

opencode_check() {
    if [[ "$HAS_OPENCODE" != "true" ]]; then
        log_info "opencode not detected, skipping"
        log_info "  Install: npm install -g opencode-ai"
        return 1
    fi
    if [[ ! -d "$OPENCODE_CONFIG_DIR" ]]; then
        mkdir -p "$OPENCODE_CONFIG_DIR"
    fi
    return 0
}

opencode_deploy_config() {
  local rules_src="$REPO_ROOT/configs/opencode/AGENTS.md.tmpl"
  local config_src="$REPO_ROOT/configs/opencode/opencode.jsonc.tmpl"

  if [[ -f "$rules_src" ]]; then
    local dest="$OPENCODE_CONFIG_DIR/AGENTS.md"
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would deploy opencode AGENTS.md"
    else
      [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"
      if deploy_template "$rules_src" "$dest"; then
        manifest_add "$dest" "configs/opencode/AGENTS.md.tmpl" "true"
        log_success "opencode AGENTS.md deployed"
      else
        log_error "failed to deploy opencode AGENTS.md"
      fi
    fi
  fi

  if [[ -f "$config_src" ]] && ! head -1 "$config_src" | grep -q '^// harness does not manage'; then
    local dest="$OPENCODE_CONFIG_DIR/opencode.jsonc"
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would deploy opencode.jsonc"
    else
      [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"
      if deploy_template "$config_src" "$dest"; then
        manifest_add "$dest" "configs/opencode/opencode.jsonc.tmpl" "true"
        log_success "opencode.jsonc deployed"
      else
        log_error "failed to deploy opencode.jsonc"
      fi
    fi
  fi
}

opencode_install() {
  opencode_deploy_config
  deploy_shared_commands "$OPENCODE_CONFIG_DIR/commands"
  # opencode auto-scans ~/.claude/skills and ~/.agents/skills for SKILL.md files,
  # so shared skills land in ~/.agents/skills (same target as the codex module;
  # both calls are checksum-idempotent) rather than a private opencode dir.
  deploy_shared_skills "$HOME/.agents/skills"
  deploy_impeccable_skill "codex" "$HOME/.agents/skills/impeccable"
}

opencode_test() {
    local tmp_dir
    tmp_dir=$(mktemp -d)

    local orig_home="$HOME"
    local orig_config="${OPENCODE_CONFIG_DIR:-}"
    local orig_dry="$DRY_RUN"
    local orig_force="$FORCE"
    local orig_no_backup="$NO_BACKUP"

    export HOME="$tmp_dir"
    OPENCODE_CONFIG_DIR="$tmp_dir/.config/opencode"
    DRY_RUN=true
    FORCE=true
    NO_BACKUP=true
    mkdir -p "$OPENCODE_CONFIG_DIR"

    local output
    output=$(opencode_deploy_config 2>&1)

    HOME="$orig_home"
    OPENCODE_CONFIG_DIR="$orig_config"
    DRY_RUN="$orig_dry"
    FORCE="$orig_force"
    NO_BACKUP="$orig_no_backup"
    rm -rf "$tmp_dir"

    if ! echo "$output" | grep -q '\[dry-run\]'; then
        log_error "opencode_test: no dry-run output produced"
        return 1
    fi

    return 0
}
