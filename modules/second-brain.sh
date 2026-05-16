#!/usr/bin/env bash

second_brain_check() {
    if ! command -v sb &>/dev/null && ! command -v second-brain-cli &>/dev/null; then
        log_info "second-brain binaries not found (will attempt install)"
        log_info "  Manual install: cargo install second-brain-cli"
        if ! command -v cargo &>/dev/null; then
            log_info "  Install Rust first: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
        fi
    fi
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

second_brain_wiki() {
  local config_dir="$HOME/.second-brain"
  local config_file="$config_dir/config.toml"
  local systemd_dir="$HOME/.config/systemd/user"
  local default_vault="$HOME/Obsidian/SecondBrain"

  local cli_bin=""
  cli_bin=$(command -v sb 2>/dev/null || command -v second-brain-cli 2>/dev/null || echo "")
  if [[ -z "$cli_bin" ]]; then
    log_warn "sb binary not found, skipping wiki setup"
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would configure wiki vault + daily timer"
    return
  fi

  # Resolve vault path: existing config → interactive prompt
  local vault_path=""
  if [[ -f "$config_file" ]] && grep -q 'vault' "$config_file" 2>/dev/null; then
    vault_path=$(grep 'vault' "$config_file" | sed 's/.*= *"//;s/"//')
    log_skip "wiki vault" "already configured: ${vault_path}"
  else
    echo ""
    read -rp "  Obsidian vault path [${default_vault}] (or 'skip'): " input
    input="${input:-$default_vault}"
    if [[ "${input,,}" == "skip" || "${input,,}" == "none" ]]; then
      log_skip "wiki vault" "skipped by user"
      return
    fi
    vault_path="${input/#\~/$HOME}"

    # Write config
    mkdir -p "$config_dir"
    if [[ -f "$config_file" ]] && grep -q '^\[wiki\]' "$config_file"; then
      sed -i "s|^vault = .*|vault = \"${vault_path}\"|" "$config_file"
    else
      printf '\n[wiki]\nvault = "%s"\n' "$vault_path" >> "$config_file"
    fi
    log_success "wiki config: ${config_file}"
  fi

  # Init vault
  if [[ ! -d "${vault_path}/entities" ]]; then
    "$cli_bin" wiki init "${vault_path}" 2>/dev/null || {
      mkdir -p "${vault_path}"/{entities,synthesis,concepts,sources}
    }
    log_success "wiki vault initialized: ${vault_path}"
  else
    log_skip "wiki vault" "already initialized"
  fi

  # Daily pipeline timer
  local timer_file="${systemd_dir}/sb-daily-pipeline.timer"
  if [[ -f "$timer_file" ]]; then
    log_skip "daily timer" "already installed"
    return
  fi

  mkdir -p "$systemd_dir"

  cat > "${systemd_dir}/sb-daily-pipeline.service" <<SVC
[Unit]
Description=Second Brain daily pipeline

[Service]
Type=oneshot
ExecStart=${cli_bin} daily-pipeline --vault ${vault_path}
Environment=HOME=%h
SVC

  cat > "$timer_file" <<TMR
[Unit]
Description=Run second-brain daily pipeline at 23:00

[Timer]
OnCalendar=*-*-* 23:00:00
Persistent=true

[Install]
WantedBy=timers.target
TMR

  if command -v systemctl &>/dev/null; then
    systemctl --user daemon-reload
    systemctl --user enable --now sb-daily-pipeline.timer 2>/dev/null &&       log_success "daily timer enabled (23:00)" ||       log_warn "could not enable daily timer"
  else
    log_warn "systemctl not available; timer file written but not activated"
  fi
}

second_brain_install() {
  second_brain_binaries
  second_brain_wiki
}

second_brain_test() {
    local tmp_dir
    tmp_dir=$(mktemp -d)

    local orig_home="$HOME"
    local orig_dry="$DRY_RUN"

    export HOME="$tmp_dir"
    DRY_RUN=true

    local output
    output=$(second_brain_install 2>&1)

    HOME="$orig_home"
    DRY_RUN="$orig_dry"
    rm -rf "$tmp_dir"

    if ! echo "$output" | grep -q '\[dry-run\]'; then
        log_error "second_brain_test: no dry-run output produced"
        return 1
    fi

    return 0
}
