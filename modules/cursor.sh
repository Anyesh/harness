#!/usr/bin/env bash

cursor_check() {
    if [[ "$HAS_CURSOR" != "true" ]]; then
        log_info "Cursor not detected, skipping"
        return 1
    fi
    if [[ ! -d "$CURSOR_CONFIG_DIR" ]]; then
        mkdir -p "$CURSOR_CONFIG_DIR"
    fi
    return 0
}

cursor_config() {
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
}

cursor_mcp() {
  local src="$REPO_ROOT/configs/cursor/mcp.json.tmpl"
  local dest="$CURSOR_CONFIG_DIR/mcp.json"

  if [[ ! -f "$src" ]]; then
    return
  fi

  local tmp_rendered
  tmp_rendered=$(mktemp)
  render_template "$src" "$tmp_rendered"

  if ! validate_template "$tmp_rendered"; then
    rm -f "$tmp_rendered"
    log_error "failed to deploy cursor mcp.json (unresolved template vars)"
    return
  fi

  local tmp_merged
  tmp_merged=$(mktemp)
  if [[ -f "$dest" ]]; then
    python3 - "$tmp_rendered" "$dest" "$tmp_merged" <<'PYEOF'
import json, sys
harness = json.load(open(sys.argv[1]))
existing = json.load(open(sys.argv[2]))
merged = existing.copy()
merged.setdefault("mcpServers", {}).update(harness.get("mcpServers", {}))
json.dump(merged, open(sys.argv[3], "w"), indent=2)
open(sys.argv[3], "a").write("\n")
PYEOF
  else
    cp "$tmp_rendered" "$tmp_merged"
  fi
  rm -f "$tmp_rendered"

  if [[ "$FORCE" == "false" && -f "$dest" ]]; then
    local src_hash dest_hash
    src_hash=$(file_checksum "$tmp_merged")
    dest_hash=$(file_checksum "$dest")
    if [[ "$src_hash" == "$dest_hash" ]]; then
      rm -f "$tmp_merged"
      log_skip "cursor mcp.json" "unchanged"
      return
    fi
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    rm -f "$tmp_merged"
    log_info "[dry-run] would deploy cursor mcp.json"
    return
  fi

  [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"
  mkdir -p "$(dirname "$dest")"
  mv "$tmp_merged" "$dest"
  manifest_add "$dest" "configs/cursor/mcp.json.tmpl" "true"
  log_success "cursor mcp.json deployed"
}

cursor_hooks() {
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

  local cursor_hooks_dir="$CURSOR_CONFIG_DIR/hooks"
  mkdir -p "$cursor_hooks_dir"

  local shared_hooks=("session-start.sh" "pre-bash-guard.sh" "format-on-save.sh" "pre-edit-comment-guard.py" "cost-guard.sh" "stop-sloppiness-guard.sh" "humanize-config.js" "humanize-activate.js" "humanize-mode-tracker.js" "ownit-config.js" "ownit-activate.js" "ownit-mode-tracker.js")
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

cursor_install() {
  cursor_config
  cursor_mcp
  cursor_hooks
  deploy_shared_skills "$CURSOR_CONFIG_DIR/skills-cursor"
}

cursor_test() {
    return 0
}
