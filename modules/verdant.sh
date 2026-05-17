#!/usr/bin/env bash

verdant_check() {
  if ! command -v cargo &>/dev/null; then
    log_info "cargo not found, verdant requires Rust toolchain"
    return 1
  fi
  return 0
}

verdant_install() {
  local binaries=("verdant" "verdant-mcp")
  local all_present=true

  for bin in "${binaries[@]}"; do
    if ! command -v "$bin" &>/dev/null; then
      all_present=false
      break
    fi
  done

  if [[ "$all_present" == "true" && "$FORCE" != "true" ]]; then
    log_skip "verdant" "all binaries present"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would install verdant via cargo"
    return 0
  fi

  local cargo_flags=()
  if [[ "$FORCE" == "true" ]]; then
    cargo_flags+=(--force)
    log_info "force-installing latest verdant from crates.io..."
  fi

  local build_log
  build_log=$(mktemp)
  if cargo install "${cargo_flags[@]}" verdant-cache-mcp 2>&1 | tee "$build_log" | tail -3; then
    if command -v verdant &>/dev/null; then
      log_success "verdant installed from crates.io"
      rm -f "$build_log"
      return 0
    fi
  fi

  log_warn "verdant install failed:"
  grep -iE "error|failed|cannot|missing" "$build_log" | tail -10 >&2
  rm -f "$build_log"
  log_warn "run manually: cargo install verdant-cache-mcp"
  return 1
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
