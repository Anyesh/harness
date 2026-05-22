#!/usr/bin/env bash

claude_check() {
    if [[ "$HAS_CLAUDE" != "true" ]]; then
        log_info "Claude Code not detected, skipping"
        log_info "  Install: https://docs.anthropic.com/claude-code"
        return 1
    fi
    if [[ ! -d "$CLAUDE_CONFIG_DIR" ]]; then
        mkdir -p "$CLAUDE_CONFIG_DIR"
    fi
    return 0
}

claude_plugins() {
  local plugins_file="$REPO_ROOT/configs/claude-code/plugins.list"
  if [[ ! -f "$plugins_file" ]]; then
    log_warn "plugins.list not found, skipping"
    return
  fi

  local marketplaces=("anthropics/claude-plugins-official")
  for mp in "${marketplaces[@]}"; do
    local mp_name="${mp##*/}"
    if claude plugin marketplace list 2>/dev/null | grep -qi "$mp_name"; then
      log_skip "marketplace $mp" "already registered"
    else
      if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would register marketplace: $mp"
      else
        if claude plugin marketplace add "$mp" 2>/dev/null; then
          log_success "registered marketplace: $mp"
        else
          log_error "failed to register marketplace: $mp"
        fi
      fi
    fi
  done

  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    local plugin
    plugin=$(echo "$line" | xargs)

    if claude plugin list 2>/dev/null | grep -qi "${plugin%%@*}"; then
      log_skip "plugin $plugin" "already installed"
    else
      if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would install plugin: $plugin"
      else
        if claude plugin install "$plugin" 2>/dev/null; then
          log_success "installed plugin: $plugin"
        else
          log_error "failed to install plugin: $plugin"
        fi
      fi
    fi
  done < "$plugins_file"
}

claude_config() {
  local tmpl_name="$1" dest="$2"
  local src="$REPO_ROOT/configs/claude-code/$tmpl_name"

  if [[ ! -f "$src" ]]; then
    log_warn "template not found: $src"
    return
  fi

  if [[ "$FORCE" == "false" && -f "$dest" ]]; then
    local tmp_check
    tmp_check=$(mktemp)
    render_template "$src" "$tmp_check"
    local src_hash dest_hash
    src_hash=$(file_checksum "$tmp_check")
    dest_hash=$(file_checksum "$dest")
    rm -f "$tmp_check"
    if [[ "$src_hash" == "$dest_hash" ]]; then
      log_skip "$tmpl_name" "unchanged"
      return
    fi
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would deploy: $tmpl_name -> $dest"
    return
  fi

  [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"

  if deploy_template "$src" "$dest"; then
    manifest_add "$dest" "configs/claude-code/$tmpl_name" "true"
    log_update "deployed: $dest"
  else
    log_error "failed to deploy: $dest (unresolved template vars)"
  fi
}

claude_hooks() {
  local hooks_dest="$CLAUDE_CONFIG_DIR/hooks"
  mkdir -p "$hooks_dest"

  deploy_hooks_from "$REPO_ROOT/configs/shared/hooks" "$hooks_dest" "configs/shared/hooks"
  deploy_hooks_from "$REPO_ROOT/configs/claude-code/hooks" "$hooks_dest" "configs/claude-code/hooks"

  if [[ "$DRY_RUN" == "false" && -f "$hooks_dest/package.json" && ! -d "$hooks_dest/node_modules" ]]; then
    if command -v npm &>/dev/null; then
      log_info "installing hook dependencies..."
      (cd "$hooks_dest" && npm install --production --silent 2>/dev/null) || true
    fi
  fi
}

claude_scripts() {
  local scripts_src="$REPO_ROOT/configs/claude-code/scripts"
  local scripts_dest="$CLAUDE_CONFIG_DIR/scripts"

  if [[ ! -d "$scripts_src" ]]; then
    return
  fi

  mkdir -p "$scripts_dest"

  for script_file in "$scripts_src"/*; do
    [[ ! -f "$script_file" ]] && continue
    local filename
    filename=$(basename "$script_file")
    local dest="$scripts_dest/$filename"

    if [[ "$FORCE" == "false" && -f "$dest" ]]; then
      local src_hash dest_hash
      src_hash=$(file_checksum "$script_file")
      dest_hash=$(file_checksum "$dest")
      if [[ "$src_hash" == "$dest_hash" ]]; then
        log_skip "script $filename" "unchanged"
        continue
      fi
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would deploy script: $filename"
      continue
    fi

    if [[ "$NO_BACKUP" == "false" ]]; then
      backup_if_exists "$dest"
    fi

    cp "$script_file" "$dest"
    chmod +x "$dest" 2>/dev/null || true
    manifest_add "$dest" "configs/claude-code/scripts/$filename" "false"
    log_update "script: $filename"
  done
}

claude_mcp() {
  if ! command -v claude &>/dev/null; then
    log_warn "claude CLI not found, skipping MCP server registration"
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would register MCP servers via claude mcp add"
    return
  fi

  local servers=(
    "web-strip:node:$HOME/.harness/tools/web-strip/index.js"
    "markitdown:uvx:markitdown-mcp"
    "cognitive-cache:uvx:--from cognitive-cache[mcp] cognitive-cache-mcp"
  )

  for entry in "${servers[@]}"; do
    local name cmd args
    name="${entry%%:*}"
    local rest="${entry#*:}"
    cmd="${rest%%:*}"
    args="${rest#*:}"

    local existing
    existing=$(claude mcp list 2>/dev/null | grep "^${name}:" || true)
    if [[ -n "$existing" ]]; then
      log_skip "mcp: $name" "already registered"
      continue
    fi

    if claude mcp add -s user "$name" -- "$cmd" $args 2>/dev/null; then
      log_success "mcp: $name registered"
    else
      log_warn "mcp: $name registration failed"
    fi
  done
}

claude_install() {
  if [[ "$NO_PLUGINS" == "false" ]]; then
    claude_plugins
  else
    log_skip "plugins" "--no-plugins flag"
  fi

  claude_config "CLAUDE.md.tmpl" "$CLAUDE_CONFIG_DIR/CLAUDE.md"
  claude_config "settings.json.tmpl" "$CLAUDE_CONFIG_DIR/settings.json"
  claude_config ".mcp.json.tmpl" "$CLAUDE_CONFIG_DIR/.mcp.json"
  claude_mcp
  second_brain_mcp

  claude_hooks
  claude_scripts
  deploy_shared_skills "$CLAUDE_CONFIG_DIR/skills"
}

claude_test() {
    local tmp_dir
    tmp_dir=$(mktemp -d)

    local orig_home="$HOME"
    local orig_config="${CLAUDE_CONFIG_DIR:-}"
    local orig_dry="$DRY_RUN"
    local orig_force="$FORCE"
    local orig_no_backup="$NO_BACKUP"
    local orig_no_plugins="$NO_PLUGINS"

    export HOME="$tmp_dir"
    CLAUDE_CONFIG_DIR="$tmp_dir/.claude"
    DRY_RUN=true
    FORCE=true
    NO_BACKUP=true
    NO_PLUGINS=true
    mkdir -p "$CLAUDE_CONFIG_DIR"

    local output
    output=$(claude_install 2>&1)

    HOME="$orig_home"
    CLAUDE_CONFIG_DIR="$orig_config"
    DRY_RUN="$orig_dry"
    FORCE="$orig_force"
    NO_BACKUP="$orig_no_backup"
    NO_PLUGINS="$orig_no_plugins"
    rm -rf "$tmp_dir"

    if ! echo "$output" | grep -q '\[dry-run\]'; then
        log_error "claude_test: no dry-run output produced"
        return 1
    fi

    return 0
}
