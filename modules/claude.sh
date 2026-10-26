#!/usr/bin/env bash

source "$REPO_ROOT/lib/claude_profiles.sh"

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
  if [[ -d "$CLAUDE_CONFIG_DIR/harness-mods" || "$DRY_RUN" == "true" ]]; then
    marketplaces+=("$CLAUDE_CONFIG_DIR/harness-mods")
  fi
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

    if claude plugin list 2>/dev/null | grep -qF -- "$plugin"; then
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

  # Dropping a line from plugins.list unregisters nothing, so a removed mod would linger
  # as an installed plugin whose marketplace entry is gone.
  local retired_plugins=("handoff@harness-mods") retired
  for retired in "${retired_plugins[@]}"; do
    claude plugin list 2>/dev/null | grep -qF -- "$retired" || continue
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would uninstall retired plugin: $retired"
    elif claude plugin uninstall "$retired" 2>/dev/null; then
      log_success "uninstalled retired plugin: $retired"
    else
      log_error "failed to uninstall retired plugin: $retired"
    fi
  done
}

# Tests stay in the repo: `claude plugin test` runs them from the source tree,
# and the engine writes its generated types and tsconfig beside a mod it is developing.
claude_mods() {
  local mods_src="$REPO_ROOT/configs/claude-code/mods"
  local mods_dest="$CLAUDE_CONFIG_DIR/harness-mods"
  [[ -d "$mods_src" ]] || return 0

  local file rel
  while IFS= read -r -d '' file; do
    rel="${file#"$mods_src"/}"
    deploy_file "$file" "$mods_dest/$rel" "configs/claude-code/mods/$rel" "false" "mod $rel"
  done < <(find "$mods_src" -type f -not -path '*/tests/*' -not -path '*/.claude-plugin/types/*' -not -name tsconfig.json -print0 | sort -z)
}

claude_config() {
  local tmpl_name="$1" dest="$2"
  local src="$REPO_ROOT/configs/claude-code/$tmpl_name"

  if [[ ! -f "$src" ]]; then
    log_warn "template not found: $src"
    return
  fi

  deploy_rendered_template "$src" "$dest" "configs/claude-code/$tmpl_name" "$tmpl_name" || true
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
    deploy_file "$script_file" "$scripts_dest/$filename" "configs/claude-code/scripts/$filename" "false" "script $filename" executable
  done
}

claude_bin_tools() {
  local bin_file filename
  for bin_file in "$REPO_ROOT/configs/claude-code/bin"/*; do
    [[ ! -f "$bin_file" ]] && continue
    filename=$(basename "$bin_file")
    deploy_file "$bin_file" "$HOME/.local/bin/$filename" "configs/claude-code/bin/$filename" "false" "$filename" executable
  done
}

# Handoffs used to live in ~/.claude/handoffs. The old path becomes a symlink to the
# new root because running sessions still hold digest and handoff paths under it.
claude_handoffs_migrate() {
  local old="$CLAUDE_CONFIG_DIR/handoffs" new
  [[ -d "$old" && ! -L "$old" ]] || return 0
  new=$(source "$REPO_ROOT/configs/claude-code/hooks/handoff-common.sh" && handoff_out_root)
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would move $old to $new"
    return
  fi
  mkdir -p "$new"
  if cp -an "$old/." "$new/" && rm -rf "$old" && ln -s "$new" "$old"; then
    log_success "handoffs moved to $new"
  else
    log_warn "could not move $old to $new"
  fi
}

# Runs last so that profiles link entries and MCP servers this install created.
claude_profiles_sync() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would sync claude-profile profiles"
    return
  fi
  [[ -x "$HOME/.local/bin/claude-profile" ]] || return 0
  local line
  while IFS= read -r line; do
    log_info "profile: $line"
  done < <("$HOME/.local/bin/claude-profile" sync 2>&1 || true)
}

# Must run before restore_originals, because that deletes claude-profile and
# the profiles are not in the manifest, so nothing else can find them.
claude_profiles_remove() {
  [[ -x "$HOME/.local/bin/claude-profile" ]] || return 0
  local line
  while IFS= read -r line; do
    log_info "profile: $line"
  done < <("$HOME/.local/bin/claude-profile" remove --all --yes 2>&1 || true)
}

claude_verdant_rules() {
  local src="$REPO_ROOT/configs/claude-code/verdant-bash.toml"
  local dest="$CLAUDE_CONFIG_DIR/verdant-bash.toml"

  if [[ ! -f "$src" ]]; then
    return
  fi

  deploy_file "$src" "$dest" "configs/claude-code/verdant-bash.toml" "false" "verdant-bash.toml"
}

# A work install withholds these servers; an earlier personal install may have
# registered them at user scope, where no config file render can reach them.
claude_withdraw_mcp() {
  command -v claude &>/dev/null || return 0
  local name
  for name in "$@"; do
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would remove MCP server $name (withheld from work installs)"
    elif claude mcp remove -s user "$name" >/dev/null 2>&1; then
      log_success "mcp: $name removed (withheld from work installs)"
    fi
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
  claude_mods
  if [[ "$NO_PLUGINS" == "false" ]]; then
    claude_plugins
  else
    log_skip "plugins" "--no-plugins flag"
  fi

  claude_config "CLAUDE.md.tmpl" "$CLAUDE_CONFIG_DIR/CLAUDE.md"
  deploy_reconciled_template "$REPO_ROOT/configs/claude-code/settings.json.tmpl" "$CLAUDE_CONFIG_DIR/settings.json" \
    "configs/claude-code/settings.json.tmpl" "settings.json.tmpl" || true
  claude_config ".mcp.json.tmpl" "$CLAUDE_CONFIG_DIR/.mcp.json"
  claude_mcp
  if profile_work; then
    claude_withdraw_mcp "${WORK_MCP_SERVERS[@]}"
  elif ! profile_no_memory; then
    # --claude-only skips loading the second-brain module, so source it for its mcp helper
    declare -f second_brain_mcp >/dev/null 2>&1 || source "$REPO_ROOT/modules/second-brain.sh"
    second_brain_mcp
  fi

  claude_verdant_rules
  claude_hooks
  claude_scripts
  claude_handoffs_migrate
  deploy_shared_skills "$CLAUDE_CONFIG_DIR/skills" "$REPO_ROOT/configs/claude-code/skills"
  deploy_impeccable_skill "claude" "$CLAUDE_CONFIG_DIR/skills/impeccable"
  deploy_shared_commands "$CLAUDE_CONFIG_DIR/commands" "$REPO_ROOT/configs/claude-code/commands"
  claude_bin_tools
  claude_profiles_render_all
  claude_profiles_sync
}

claude_test() {
    local tmp_dir
    tmp_dir=$(mktemp -d)

    local orig_home="$HOME"
    local orig_xdg="${XDG_CONFIG_HOME-}" had_xdg="${XDG_CONFIG_HOME+set}"
    local orig_config="${CLAUDE_CONFIG_DIR:-}"
    local orig_dry="$DRY_RUN"
    local orig_force="$FORCE"
    local orig_no_backup="$NO_BACKUP"
    local orig_no_plugins="$NO_PLUGINS"

    export HOME="$tmp_dir"
    export XDG_CONFIG_HOME="$tmp_dir/.config"
    CLAUDE_CONFIG_DIR="$tmp_dir/.claude"
    DRY_RUN=true
    FORCE=true
    NO_BACKUP=true
    NO_PLUGINS=true
    mkdir -p "$CLAUDE_CONFIG_DIR"

    local output
    output=$(claude_install 2>&1)

    HOME="$orig_home"
    if [[ -n "$had_xdg" ]]; then XDG_CONFIG_HOME="$orig_xdg"; else unset XDG_CONFIG_HOME; fi
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
