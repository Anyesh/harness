#!/usr/bin/env bash

verdant_check() {
  if ! command -v cargo &>/dev/null; then
    log_info "cargo not found, verdant requires Rust toolchain"
    return 1
  fi
  return 0
}

verdant_install() {
  local repo="https://github.com/Anyesh/verdant"
  local binaries=("verdant" "verdant-mcp")
  local dest_dir="${HOME}/.local/bin"
  local all_present=true

  for bin in "${binaries[@]}"; do
    if ! command -v "$bin" &>/dev/null && [[ ! -x "$dest_dir/$bin" ]]; then
      all_present=false
      break
    fi
  done

  if [[ "$all_present" == "true" ]]; then
    log_skip "verdant" "all binaries present"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would install verdant binaries"
    return 0
  fi

  local installed=false
  local arch os_name
  arch=$(uname -m)
  os_name=$(uname -s | tr '[:upper:]' '[:lower:]')

  local tag
  tag=$(curl -fsSL -o /dev/null -w '%{url_effective}' "${repo}/releases/latest" 2>/dev/null | grep -oE '[^/]+$' || echo "")

  if [[ -n "$tag" ]]; then
    mkdir -p "$dest_dir"
    local all_ok=true
    for bin in "${binaries[@]}"; do
      if command -v "$bin" &>/dev/null || [[ -x "$dest_dir/$bin" ]]; then
        continue
      fi
      local url="${repo}/releases/download/${tag}/${bin}-${os_name}-${arch}"
      if curl -fsSL "$url" -o "$dest_dir/$bin" 2>/dev/null; then
        chmod +x "$dest_dir/$bin"
      else
        all_ok=false
      fi
    done
    if [[ "$all_ok" == "true" ]]; then
      installed=true
      log_success "verdant installed from release $tag"
    else
      log_info "prebuilt binaries not available, trying cargo..."
    fi
  fi

  if [[ "$installed" == "false" ]]; then
    log_info "building verdant from source..."
    local build_log
    build_log=$(mktemp)
    if cargo install verdant-cache-mcp 2>&1 | tee "$build_log" | tail -3; then
      if command -v verdant &>/dev/null; then
        installed=true
        log_success "verdant installed from crates.io"
      fi
    fi
    if [[ "$installed" == "false" ]]; then
      log_warn "verdant build failed:"
      grep -iE "error|failed|cannot|missing" "$build_log" | tail -10 >&2
    fi
    rm -f "$build_log"
  fi

  if [[ "$installed" == "false" ]]; then
    log_warn "verdant not installed. Run: cargo install verdant-cache-mcp"
  fi
}

verdant_test() {
  local tmp_dir
  tmp_dir=$(mktemp -d)

  local orig_home="$HOME"
  local orig_dry="$DRY_RUN"

  export HOME="$tmp_dir"
  DRY_RUN=true

  local output
  output=$(verdant_install 2>&1)

  HOME="$orig_home"
  DRY_RUN="$orig_dry"
  rm -rf "$tmp_dir"

  if ! echo "$output" | grep -q '\[dry-run\]'; then
    log_error "verdant_test: no dry-run output produced"
    return 1
  fi

  return 0
}
