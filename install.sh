#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$SCRIPT_DIR/lib/common.sh" ]]; then
  HARNESS_DIR="${HARNESS_DIR:-$HOME/.harness}"
  if [[ ! -d "$HARNESS_DIR" ]]; then
    echo "[harness] Cloning repository..."
    git clone https://github.com/anyesh/harness.git "$HARNESS_DIR"
  else
    echo "[harness] Updating repository..."
    git -C "$HARNESS_DIR" pull --ff-only 2>/dev/null || true
  fi
  exec "$HARNESS_DIR/install.sh" "$@"
fi

REPO_ROOT="$SCRIPT_DIR"

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/template.sh"
source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/detect.sh"
source "$REPO_ROOT/lib/backup.sh"

COMMAND="${1:-install}"
FORCE=false
DRY_RUN=false
NO_PLUGINS=false
NO_BACKUP=false
CLAUDE_ONLY=false
CURSOR_ONLY=false
CODEX_ONLY=false

if [[ "$COMMAND" == --* ]]; then
  COMMAND="install"
else
  shift || true
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true ;;
    --dry-run) DRY_RUN=true ;;
    --no-plugins) NO_PLUGINS=true ;;
    --no-backup) NO_BACKUP=true ;;
    --claude-only) CLAUDE_ONLY=true ;;
    --cursor-only) CURSOR_ONLY=true ;;
    --codex-only) CODEX_ONLY=true ;;
    *) die "unknown flag: $1" ;;
  esac
  shift
done

install_claude_plugins() {
  local plugins_file="$REPO_ROOT/configs/claude-code/plugins.list"
  if [[ ! -f "$plugins_file" ]]; then
    log_warn "plugins.list not found, skipping"
    return
  fi

  local marketplaces=("anthropics/claude-plugins-official" "Anyesh/caveman")
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

deploy_claude_config() {
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

deploy_claude_hooks() {
  local hooks_src="$REPO_ROOT/configs/claude-code/hooks"
  local hooks_dest="$CLAUDE_CONFIG_DIR/hooks"

  if [[ ! -d "$hooks_src" ]]; then
    log_warn "hooks directory not found: $hooks_src"
    return
  fi

  mkdir -p "$hooks_dest"

  for hook_file in "$hooks_src"/*; do
    [[ ! -f "$hook_file" ]] && continue
    local filename
    filename=$(basename "$hook_file")
    local dest="$hooks_dest/$filename"

    if [[ "$FORCE" == "false" && -f "$dest" ]]; then
      local src_hash dest_hash
      src_hash=$(file_checksum "$hook_file")
      dest_hash=$(file_checksum "$dest")
      if [[ "$src_hash" == "$dest_hash" ]]; then
        log_skip "hook $filename" "unchanged"
        continue
      fi
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would deploy hook: $filename"
      continue
    fi

    if [[ "$NO_BACKUP" == "false" ]]; then
      backup_if_exists "$dest"
    fi

    cp "$hook_file" "$dest"
    chmod +x "$dest" 2>/dev/null || true
    manifest_add "$dest" "configs/claude-code/hooks/$filename" "false"
    log_update "hook: $filename"
  done

  if [[ "$DRY_RUN" == "false" && -f "$hooks_dest/package.json" && ! -d "$hooks_dest/node_modules" ]]; then
    if command -v npm &>/dev/null; then
      log_info "installing hook dependencies..."
      (cd "$hooks_dest" && npm install --production --silent 2>/dev/null) || true
    fi
  fi
}

deploy_claude_scripts() {
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

deploy_tools() {
  local tools_src="$REPO_ROOT/tools"
  local tools_dest="$HOME/.harness/tools"

  if [[ ! -d "$tools_src" ]]; then
    return
  fi

  mkdir -p "$tools_dest"

  for tool_dir in "$tools_src"/*/; do
    [[ ! -d "$tool_dir" ]] && continue
    local tool_name
    tool_name=$(basename "$tool_dir")
    local dest="$tools_dest/$tool_name"

    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would deploy tool: $tool_name"
      continue
    fi

    mkdir -p "$dest"
    cp "$tool_dir"/*.js "$dest/" 2>/dev/null || true
    cp "$tool_dir"/*.json "$dest/" 2>/dev/null || true

    if [[ -f "$dest/package.json" && ! -d "$dest/node_modules" ]]; then
      if command -v npm &>/dev/null; then
        log_info "installing $tool_name dependencies..."
        (cd "$dest" && npm install --production --silent 2>/dev/null) || log_warn "$tool_name: npm install failed"
      else
        log_warn "$tool_name requires npm but npm not found"
      fi
    fi

    chmod +x "$dest/index.js" 2>/dev/null || true
    log_success "tool: $tool_name"
  done
}

install_rtk() {
  if [[ "$HAS_RTK" == "true" ]]; then
    log_skip "rtk" "already installed ($(rtk --version 2>/dev/null || echo 'unknown version'))"
    return
  fi

  log_info "RTK not found, attempting installation..."

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would install RTK via cargo or prebuilt binary"
    return
  fi

  local installed=false

  if command -v cargo &>/dev/null; then
    log_info "installing RTK via cargo..."
    if cargo install rtk-cli 2>/dev/null; then
      installed=true
      log_success "RTK installed via cargo"
    else
      log_warn "cargo install failed, trying prebuilt binary..."
    fi
  fi

  if [[ "$installed" == "false" ]]; then
    local arch os_name
    arch=$(uname -m)
    os_name=$(uname -s | tr '[:upper:]' '[:lower:]')

    local rtk_url="https://github.com/Anyesh/rtk/releases/latest/download/rtk-${os_name}-${arch}"
    local rtk_dest="${HOME}/.local/bin/rtk"

    mkdir -p "$(dirname "$rtk_dest")"
    if curl -fsSL "$rtk_url" -o "$rtk_dest" 2>/dev/null; then
      chmod +x "$rtk_dest"
      installed=true
      log_success "RTK installed to $rtk_dest"
    else
      log_warn "RTK binary download failed (${rtk_url}), skipping RTK installation"
      log_warn "Install manually: cargo install rtk-cli or visit https://github.com/Anyesh/rtk"
      return
    fi
  fi

  if [[ "$installed" == "true" ]]; then
    log_info "configuring RTK shell hook..."
    rtk setup 2>/dev/null || log_warn "rtk setup failed; configure manually with 'rtk setup'"
    HAS_RTK=true
  fi
}

deploy_shared_skills() {
  local dest_dir="$1"
  local skills_src="$REPO_ROOT/configs/shared/skills"

  if [[ ! -d "$skills_src" ]]; then
    log_warn "shared skills directory not found"
    return
  fi

  mkdir -p "$dest_dir"

  for skill_dir in "$skills_src"/*/; do
    [[ ! -d "$skill_dir" ]] && continue
    local skill_name
    skill_name=$(basename "$skill_dir")
    local dest="$dest_dir/$skill_name"

    if [[ "$FORCE" == "false" && -d "$dest" ]]; then
      log_skip "skill $skill_name" "exists"
      continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would deploy skill: $skill_name"
      continue
    fi

    rm -rf "$dest"
    cp -r "$skill_dir" "$dest"
    log_success "skill: $skill_name"
  done
}

deploy_cursor_config() {
  local src="$REPO_ROOT/configs/cursor/rules.tmpl"
  local dest="$CURSOR_CONFIG_DIR/.cursorrules"

  if [[ -f "$src" ]]; then
    if [[ "$FORCE" == "false" && -f "$dest" ]]; then
      local tmp_check
      tmp_check=$(mktemp)
      render_template "$src" "$tmp_check"
      local src_hash dest_hash
      src_hash=$(file_checksum "$tmp_check")
      dest_hash=$(file_checksum "$dest")
      rm -f "$tmp_check"
      if [[ "$src_hash" == "$dest_hash" ]]; then
        log_skip "cursor rules" "unchanged"
      else
        if [[ "$DRY_RUN" == "false" ]]; then
          [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"
          if deploy_template "$src" "$dest"; then
            manifest_add "$dest" "configs/cursor/rules.tmpl" "true"
            log_success "cursor rules deployed"
          else
            log_error "failed to deploy cursor rules"
          fi
        else
          log_info "[dry-run] would deploy cursor rules"
        fi
      fi
    else
      if [[ "$DRY_RUN" == "false" ]]; then
        [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"
        if deploy_template "$src" "$dest"; then
          manifest_add "$dest" "configs/cursor/rules.tmpl" "true"
          log_success "cursor rules deployed"
        else
          log_error "failed to deploy cursor rules"
        fi
      else
        log_info "[dry-run] would deploy cursor rules"
      fi
    fi
  fi

  deploy_cursor_hooks
}

deploy_cursor_hooks() {
  local hooks_src="$REPO_ROOT/configs/cursor/hooks.json"
  local hooks_dest="$CURSOR_CONFIG_DIR/hooks.json"

  if [[ ! -f "$hooks_src" ]]; then
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would deploy cursor hooks.json"
    return
  fi

  [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$hooks_dest"

  if deploy_template "$hooks_src" "$hooks_dest"; then
    manifest_add "$hooks_dest" "configs/cursor/hooks.json" "true"
    log_success "cursor hooks.json deployed"
  else
    log_error "failed to deploy cursor hooks.json"
  fi

  # Deploy shared hook scripts to cursor hooks dir
  local cursor_hooks_dir="$CURSOR_CONFIG_DIR/hooks"
  mkdir -p "$cursor_hooks_dir"

  local shared_hooks=("pre-bash-guard.sh" "format-on-save.sh" "pre-edit-comment-guard.py" "cost-guard.sh" "stop-sloppiness-guard.sh")
  for hook in "${shared_hooks[@]}"; do
    local hook_src="$REPO_ROOT/configs/claude-code/hooks/$hook"
    local hook_dest="$cursor_hooks_dir/$hook"
    if [[ -f "$hook_src" ]]; then
      cp "$hook_src" "$hook_dest"
      chmod +x "$hook_dest" 2>/dev/null || true
      manifest_add "$hook_dest" "configs/claude-code/hooks/$hook" "false"
      log_update "cursor hook: $hook"
    fi
  done
}

deploy_codex_config() {
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

cmd_status() {
  manifest_init
  local manifest="${HARNESS_MANIFEST}"
  local dirty=0

  log_section "Harness Status"

  for dest in $(manifest_list_files); do
    if [[ ! -f "$dest" ]]; then
      printf "  ${RED}MISSING${RESET}  %s\n" "$dest"
      dirty=$((dirty + 1))
    elif manifest_check_changed "$dest"; then
      printf "  ${YELLOW}DIRTY${RESET}    %s\n" "$dest"
      dirty=$((dirty + 1))
    else
      printf "  ${GREEN}CLEAN${RESET}    %s\n" "$dest"
    fi
  done

  echo ""
  if [[ $dirty -eq 0 ]]; then
    log_info "all managed files are clean"
    return 0
  else
    log_warn "$dirty file(s) have local modifications"
    return 1
  fi
}

cmd_uninstall() {
  log_section "Harness Uninstall"
  log_info "restoring from latest backup..."
  restore_latest
  log_info "removing manifest..."
  rm -f "$HARNESS_MANIFEST"
  log_success "uninstall complete"
}

cmd_edit() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    die "usage: install.sh edit <path-relative-to-repo>"
  fi

  local full_path="$REPO_ROOT/$target"
  if [[ ! -f "$full_path" ]]; then
    die "file not found: $full_path"
  fi

  local checksum_before
  checksum_before=$(file_checksum "$full_path")

  "${EDITOR:-vim}" "$full_path"

  local checksum_after
  checksum_after=$(file_checksum "$full_path")

  if [[ "$checksum_before" != "$checksum_after" ]]; then
    log_info "file changed, re-deploying..."
    exec "$REPO_ROOT/install.sh" --force
  else
    log_info "no changes detected"
  fi
}

case "$COMMAND" in
  install) ;;
  status) cmd_status; exit $? ;;
  uninstall) cmd_uninstall; exit $? ;;
  edit) cmd_edit "${2:-}"; exit $? ;;
  *) die "unknown command: $COMMAND. Use: install, status, edit, uninstall" ;;
esac

log_section "Harness Bootstrap"
log_info "repo: $REPO_ROOT"

if [[ -f "$HARNESS_ENV" ]]; then
  log_info "using env overrides from $HARNESS_ENV"
else
  log_info "no $HARNESS_ENV found, using defaults (HOME_DIR=$HOME)"
fi

detect_tools

if [[ "$CLAUDE_ONLY" == "true" ]]; then
  HAS_CURSOR=false; HAS_CODEX=false
fi
if [[ "$CURSOR_ONLY" == "true" ]]; then
  HAS_CLAUDE=false; HAS_CODEX=false
fi
if [[ "$CODEX_ONLY" == "true" ]]; then
  HAS_CLAUDE=false; HAS_CURSOR=false
fi

manifest_init

if [[ "$HAS_CLAUDE" == "true" ]]; then
  log_section "Claude Code"

  if [[ "$NO_PLUGINS" == "false" ]]; then
    install_claude_plugins
  else
    log_skip "plugins" "--no-plugins flag"
  fi

  deploy_claude_config "CLAUDE.md.tmpl" "$CLAUDE_CONFIG_DIR/CLAUDE.md"
  deploy_claude_config "settings.json.tmpl" "$CLAUDE_CONFIG_DIR/settings.json"
  deploy_claude_config ".mcp.json.tmpl" "$CLAUDE_CONFIG_DIR/.mcp.json"

  deploy_claude_hooks
  deploy_claude_scripts
  deploy_shared_skills "$CLAUDE_CONFIG_DIR/skills"
fi

if [[ "$HAS_CURSOR" == "true" ]]; then
  log_section "Cursor"
  deploy_cursor_config
  deploy_shared_skills "$CURSOR_CONFIG_DIR/skills-cursor"
fi

if [[ "$HAS_CODEX" == "true" ]]; then
  log_section "Codex"
  deploy_codex_config
  deploy_shared_skills "$CODEX_CONFIG_DIR/skills"
fi

log_section "Token Optimization"
deploy_tools
install_rtk

manifest_finalize
report_summary

if [[ $FAILED -gt 0 && $INSTALLED -eq 0 && $UPDATED -eq 0 ]]; then
  exit 1
fi
exit 0
