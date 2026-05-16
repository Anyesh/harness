#!/usr/bin/env bash

second_brain_check() {
    return 0
}

second_brain_binaries() {
  local sb_repo="https://github.com/Anyesh/second-brain"
  local binaries=("second-brain-api" "second-brain-mcp" "second-brain-cli")
  local dest_dir="${HOME}/.local/bin"
  local all_present=true

  for bin in "${binaries[@]}"; do
    if ! command -v "$bin" &>/dev/null && [[ ! -x "$dest_dir/$bin" ]]; then
      all_present=false
      break
    fi
  done

  if [[ "$all_present" == "true" ]]; then
    log_skip "second-brain" "all binaries present"
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would install second-brain binaries"
    return
  fi

  local installed=false

  local arch os_name
  arch=$(uname -m)
  os_name=$(uname -s | tr '[:upper:]' '[:lower:]')

  local tag_url="${sb_repo}/releases/latest"
  local tag
  tag=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$tag_url" 2>/dev/null | grep -oE '[^/]+$' || echo "")

  if [[ -n "$tag" ]]; then
    mkdir -p "$dest_dir"
    local all_ok=true
    for bin in "${binaries[@]}"; do
      if command -v "$bin" &>/dev/null || [[ -x "$dest_dir/$bin" ]]; then
        continue
      fi
      local url="${sb_repo}/releases/download/${tag}/${bin}-${os_name}-${arch}"
      if curl -fsSL "$url" -o "$dest_dir/$bin" 2>/dev/null; then
        chmod +x "$dest_dir/$bin"
      else
        all_ok=false
      fi
    done
    if [[ "$all_ok" == "true" ]]; then
      installed=true
      log_success "second-brain installed from release $tag"
    else
      log_info "some prebuilt binaries not available, trying cargo..."
    fi
  fi

  if [[ "$installed" == "false" ]] && command -v cargo &>/dev/null; then
    log_info "building second-brain from source..."
    local build_log
    build_log=$(mktemp)
    if cargo install second-brain-cli second-brain-mcp second-brain-api 2>&1 | tee "$build_log" | tail -3; then
      if command -v second-brain-mcp &>/dev/null; then
        installed=true
        log_success "second-brain installed from source"
      fi
    fi
    if [[ "$installed" == "false" ]]; then
      log_warn "second-brain build failed:"
      grep -iE "error|failed|cannot|missing" "$build_log" | tail -10 >&2
    fi
    rm -f "$build_log"
  fi

  if [[ "$installed" == "false" ]]; then
    log_warn "second-brain not installed. Install Rust and run: cargo install second-brain-cli second-brain-mcp second-brain-api"
  fi
}

second_brain_mcp() {
  if ! command -v claude &>/dev/null; then
    return
  fi

  local sb_mcp=""
  for candidate in \
    "$(command -v second-brain-mcp 2>/dev/null)" \
    "/mnt/data/second-brain/target/release/second-brain-mcp" \
    "/opt/second-brain/bin/second-brain-mcp" \
    "$HOME/.local/bin/second-brain-mcp" \
    "$HOME/.cargo/bin/second-brain-mcp"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      sb_mcp="$candidate"
      break
    fi
  done

  if [[ -z "$sb_mcp" ]]; then
    log_warn "second-brain-mcp binary not found, skipping MCP registration"
    return
  fi

  local sb_api=""
  for candidate in \
    "$(command -v second-brain-api 2>/dev/null)" \
    "/mnt/data/second-brain/target/release/second-brain-api" \
    "/opt/second-brain/bin/second-brain-api" \
    "$HOME/.local/bin/second-brain-api" \
    "$HOME/.cargo/bin/second-brain-api"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      sb_api="$candidate"
      break
    fi
  done

  second_brain_daemon "$sb_api"

  local existing
  existing=$(claude mcp list 2>/dev/null | grep "^second-brain:" || true)
  if [[ -n "$existing" ]]; then
    log_skip "mcp: second-brain" "already registered"
  elif [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would register second-brain MCP (binary: $sb_mcp)"
  else
    if claude mcp add -s user "second-brain" \
      -e SECOND_BRAIN_API="http://127.0.0.1:7200" \
      -e SECOND_BRAIN_DAEMON_BIN="$sb_api" \
      -- "$sb_mcp" 2>/dev/null; then
      log_success "mcp: second-brain registered (binary: $sb_mcp)"
    else
      log_warn "mcp: second-brain registration failed"
    fi
  fi
}

second_brain_daemon() {
  local sb_api="${1:-}"
  local service_dir="$HOME/.config/systemd/user"
  local service_file="$service_dir/second-brain.service"

  if [[ -z "$sb_api" ]]; then
    log_warn "second-brain-api binary not found, skipping daemon setup"
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would install second-brain daemon service"
    return
  fi

  mkdir -p "$service_dir"

  cat > "$service_file" <<UNIT
[Unit]
Description=Second Brain daemon
After=network.target

[Service]
Type=simple
ExecStart=$sb_api
Environment=SECOND_BRAIN_DB=$HOME/.second-brain/graph.kuzu
Environment=SECOND_BRAIN_BIND=127.0.0.1:7200
Restart=on-failure
RestartSec=5
TimeoutStartSec=60

[Install]
WantedBy=default.target
UNIT

  if command -v systemctl &>/dev/null; then
    systemctl --user daemon-reload
    systemctl --user enable second-brain.service 2>/dev/null || true
    if ! systemctl --user is-active --quiet second-brain.service 2>/dev/null; then
      systemctl --user start second-brain.service 2>/dev/null || true
    fi
    log_success "daemon: second-brain service installed and started"
  else
    log_warn "systemctl not found, service file written but not activated"
  fi
}

second_brain_install() {
  second_brain_binaries
}

second_brain_test() {
    return 0
}
