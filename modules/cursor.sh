#!/usr/bin/env bash

cursor_check() {
    if [[ "$HAS_CURSOR" != "true" ]]; then
        log_info "Cursor not detected, skipping"
        log_info "  Install: https://cursor.sh"
        return 1
    fi
    if [[ ! -d "$CURSOR_CONFIG_DIR" ]]; then
        mkdir -p "$CURSOR_CONFIG_DIR"
    fi
    return 0
}

cursor_rules() {
  local src_dir="$REPO_ROOT/configs/shared/rules"
  local dest_dir="$CURSOR_CONFIG_DIR/rules"

  if [[ ! -d "$src_dir" ]]; then
    log_warn "cursor rules source missing: $src_dir"
    return
  fi

  mkdir -p "$dest_dir"

  local legacy="$CURSOR_CONFIG_DIR/.cursorrules"
  if [[ -f "$legacy" ]] && manifest_is_managed "$legacy"; then
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would remove legacy $legacy (Cursor Agent mode ignores it)"
    else
      rm -f "$legacy"
      log_info "removed legacy: $legacy"
    fi
  fi

  for src in "$src_dir"/*.mdc; do
    [[ ! -f "$src" ]] && continue
    local filename
    filename=$(basename "$src")
    local dest="$dest_dir/$filename"

    local tmp_render
    tmp_render=$(mktemp)
    render_template "$src" "$tmp_render"

    if ! validate_template "$tmp_render"; then
      rm -f "$tmp_render"
      log_error "cursor rule failed validation: $filename"
      continue
    fi

    if [[ "$FORCE" == "false" && -f "$dest" ]]; then
      local src_hash dest_hash
      src_hash=$(file_checksum "$tmp_render")
      dest_hash=$(file_checksum "$dest")
      if [[ "$src_hash" == "$dest_hash" ]]; then
        rm -f "$tmp_render"
        log_skip "cursor rule $filename" "unchanged"
        continue
      fi
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      rm -f "$tmp_render"
      log_info "[dry-run] would deploy cursor rule: $filename"
      continue
    fi

    [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"
    mv "$tmp_render" "$dest"
    manifest_add "$dest" "configs/shared/rules/$filename" "true"
    log_update "cursor rule: $filename"
  done
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
  else
    [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$hooks_dest"

    if deploy_template "$hooks_src" "$hooks_dest"; then
      manifest_add "$hooks_dest" "configs/cursor/hooks.json" "true"
      log_success "cursor hooks.json deployed"
    else
      log_error "failed to deploy cursor hooks.json"
    fi
  fi

  local cursor_hooks_dir="$CURSOR_CONFIG_DIR/hooks"
  [[ "$DRY_RUN" == "false" ]] && mkdir -p "$cursor_hooks_dir"

  deploy_hooks_from "$REPO_ROOT/configs/shared/hooks" "$cursor_hooks_dir" "configs/shared/hooks"

  if [[ "$DRY_RUN" == "false" && -f "$cursor_hooks_dir/package.json" && ! -d "$cursor_hooks_dir/node_modules" ]]; then
    if command -v npm &>/dev/null; then
      log_info "installing cursor hook dependencies..."
      (cd "$cursor_hooks_dir" && npm install --production --silent 2>/dev/null) || true
    fi
  fi
}

cursor_install() {
  cursor_rules
  cursor_mcp
  cursor_hooks
  deploy_shared_skills "$CURSOR_CONFIG_DIR/skills"
  deploy_shared_commands "$CURSOR_CONFIG_DIR/commands"
}

cursor_test() {
    local tmp_dir
    tmp_dir=$(mktemp -d)

    local orig_home="$HOME"
    local orig_config="${CURSOR_CONFIG_DIR:-}"
    local orig_dry="$DRY_RUN"
    local orig_force="$FORCE"
    local orig_no_backup="$NO_BACKUP"

    export HOME="$tmp_dir"
    CURSOR_CONFIG_DIR="$tmp_dir/.cursor"
    DRY_RUN=true
    FORCE=true
    NO_BACKUP=true
    mkdir -p "$CURSOR_CONFIG_DIR"

    local output
    output=$(cursor_install 2>&1)

    HOME="$orig_home"
    CURSOR_CONFIG_DIR="$orig_config"
    DRY_RUN="$orig_dry"
    FORCE="$orig_force"
    NO_BACKUP="$orig_no_backup"
    rm -rf "$tmp_dir"

    if ! echo "$output" | grep -q '\[dry-run\]'; then
        log_error "cursor_test: no dry-run output produced"
        return 1
    fi

    return 0
}
