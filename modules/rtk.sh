#!/usr/bin/env bash

rtk_check() {
    if [[ "$HAS_RTK" != "true" ]]; then
        log_info "RTK not found (will attempt install)"
        if ! command -v cargo &>/dev/null; then
            log_info "  Install Rust: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
            log_info "  Then: cargo install --git https://github.com/Anyesh/rtk.git"
        else
            log_info "  Install: cargo install --git https://github.com/Anyesh/rtk.git"
        fi
    fi
    return 0
}

rtk_binary() {
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
  local rtk_repo="https://github.com/Anyesh/rtk"

  if command -v cargo &>/dev/null; then
    local rustc_ver
    rustc_ver=$(rustc --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    local rustc_major rustc_minor
    rustc_major=$(echo "$rustc_ver" | cut -d. -f1)
    rustc_minor=$(echo "$rustc_ver" | cut -d. -f2)

    if [[ "$rustc_major" -ge 1 && "$rustc_minor" -ge 80 ]]; then
      log_info "building RTK from Anyesh/rtk fork (rustc $rustc_ver)..."
      local rtk_log
      rtk_log=$(mktemp)
      if cargo install --git "${rtk_repo}.git" 2>&1 | tee "$rtk_log" | tail -3; then
        if command -v rtk &>/dev/null; then
          log_success "RTK installed from Anyesh/rtk ($(rtk --version 2>/dev/null || echo 'unknown'))"
          installed=true
        fi
      fi
      if [[ "$installed" == "false" ]]; then
        log_warn "RTK build from source failed:"
        grep -iE "error|failed|cannot|missing|not found" "$rtk_log" | tail -10 >&2
        log_info "falling back to prebuilt binary..."
      fi
      rm -f "$rtk_log"
    else
      log_warn "rustc $rustc_ver is too old for RTK (needs 1.80+), trying prebuilt binary..."
    fi
  else
    log_info "cargo not found, trying prebuilt binary..."
  fi

  if [[ "$installed" == "false" ]]; then
    local arch os_name
    arch=$(uname -m)
    os_name=$(uname -s | tr '[:upper:]' '[:lower:]')

    local rtk_dest="${HOME}/.local/bin/rtk"
    local rtk_url="${rtk_repo}/releases/latest/download/rtk-${os_name}-${arch}"

    mkdir -p "$(dirname "$rtk_dest")"
    if curl -fsSL "$rtk_url" -o "$rtk_dest" 2>/dev/null; then
      chmod +x "$rtk_dest"
      installed=true
      log_success "RTK installed to $rtk_dest"
    else
      log_warn "prebuilt binary not available for ${os_name}-${arch}"
      log_warn "Install RTK manually: update Rust (rustup update) then: cargo install --git ${rtk_repo}.git"
    fi
  fi

  if [[ "$installed" == "true" ]]; then
    HAS_RTK=true
  fi
}

rtk_config() {
  if [[ "$HAS_RTK" != "true" ]]; then
    return
  fi

  local src="$REPO_ROOT/configs/shared/rtk-config.toml"
  local dest="$HOME/.config/rtk/config.toml"

  if [[ ! -f "$src" ]]; then
    return
  fi

  if [[ "$FORCE" == "false" && -f "$dest" ]]; then
    local src_hash dest_hash
    src_hash=$(file_checksum "$src")
    dest_hash=$(file_checksum "$dest")
    if [[ "$src_hash" == "$dest_hash" ]]; then
      log_skip "rtk config" "unchanged"
      return
    fi
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would deploy rtk config"
    return
  fi

  mkdir -p "$(dirname "$dest")"
  [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"
  cp "$src" "$dest"
  manifest_add "$dest" "configs/shared/rtk-config.toml" "false"
  log_update "rtk config: $dest"
}

rtk_install() {
  rtk_binary
  rtk_config
}

rtk_test() {
    local tmp_dir
    tmp_dir=$(mktemp -d)

    local orig_home="$HOME"
    local orig_dry="$DRY_RUN"
    local orig_has_rtk="$HAS_RTK"

    export HOME="$tmp_dir"
    DRY_RUN=true
    HAS_RTK=false

    local output
    output=$(rtk_install 2>&1)

    HOME="$orig_home"
    DRY_RUN="$orig_dry"
    HAS_RTK="$orig_has_rtk"
    rm -rf "$tmp_dir"

    if ! echo "$output" | grep -q '\[dry-run\]'; then
        log_error "rtk_test: no dry-run output produced"
        return 1
    fi

    return 0
}
