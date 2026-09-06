#!/usr/bin/env bash

second_brain_check() {
    if ! command -v sb &>/dev/null; then
        log_info "second-brain binaries not found (will attempt install)"
        log_info "  Manual install: cargo install --git $SECOND_BRAIN_GIT_URL --rev $SECOND_BRAIN_REV second-brain-cli"
        if ! command -v cargo &>/dev/null; then
            log_info "  Install Rust first: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
        fi
    fi
    return 0
}

# second-brain is a private repo, and crates.io lags the workspace (stuck at 0.5.3 while
# HEAD is past 0.5.7), so pin by git rev until publishing catches up. Bump SECOND_BRAIN_REV
# when a new stable rev is cut.
SECOND_BRAIN_GIT_URL="ssh://git@github.com/Anyesh/second-brain.git"
SECOND_BRAIN_REV="6c9e7387e4ce1e973eabc2c2b0cf4c61a8aefa26"  # v0.8.1

second_brain_binaries() {
  local binaries=("second-brain-api" "second-brain-mcp" "sb")
  local all_present=true

  for bin in "${binaries[@]}"; do
    if ! command -v "$bin" &>/dev/null; then
      all_present=false
      break
    fi
  done

  if [[ "$all_present" == "true" && "$FORCE" != "true" ]]; then
    log_skip "second-brain" "all binaries present"
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would install second-brain via cargo (git rev ${SECOND_BRAIN_REV:0:7})"
    return
  fi

  if ! command -v cargo &>/dev/null; then
    log_warn "cargo not found, cannot install second-brain"
    log_warn "run manually: cargo install --git $SECOND_BRAIN_GIT_URL --rev $SECOND_BRAIN_REV second-brain-cli second-brain-mcp second-brain-api"
    return 1
  fi

  local cargo_flags=()
  if [[ "$FORCE" == "true" ]]; then
    cargo_flags+=(--force)
  fi
  log_info "installing second-brain from git rev ${SECOND_BRAIN_REV:0:7}..."

  # libgit2 cannot use the ssh-agent reliably against a private repo; the git CLI can.
  export CARGO_NET_GIT_FETCH_WITH_CLI=true

  local build_log
  build_log=$(mktemp)
  local pkg all_ok=true
  for pkg in second-brain-cli second-brain-mcp second-brain-api; do
    if ! cargo install "${cargo_flags[@]}" --git "$SECOND_BRAIN_GIT_URL" --rev "$SECOND_BRAIN_REV" "$pkg" 2>&1 | tee -a "$build_log" | tail -3; then
      all_ok=false
      break
    fi
  done

  if [[ "$all_ok" == "true" ]] && command -v sb &>/dev/null; then
    log_success "second-brain installed (git rev ${SECOND_BRAIN_REV:0:7})"
    rm -f "$build_log"
    return 0
  fi

  log_warn "second-brain install failed:"
  grep -iE "error|failed|cannot|missing" "$build_log" | tail -10 >&2
  rm -f "$build_log"
  log_warn "run manually: cargo install --git $SECOND_BRAIN_GIT_URL --rev $SECOND_BRAIN_REV second-brain-cli second-brain-mcp second-brain-api"
  return 1
}

# Sets SB_MCP_BIN and SB_API_BIN to the resolved binary paths, or "" when a
# binary isn't installed. Shared by every module that registers the
# second-brain MCP server (claude, codex, opencode) so the lookup order
# lives in exactly one place.
second_brain_find_binaries() {
  SB_MCP_BIN=""
  SB_API_BIN=""
  local candidate
  for candidate in \
    "$(command -v second-brain-mcp 2>/dev/null)" \
    "$HOME/.local/bin/second-brain-mcp" \
    "$HOME/.cargo/bin/second-brain-mcp"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      SB_MCP_BIN="$candidate"
      break
    fi
  done
  for candidate in \
    "$(command -v second-brain-api 2>/dev/null)" \
    "$HOME/.local/bin/second-brain-api" \
    "$HOME/.cargo/bin/second-brain-api"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      SB_API_BIN="$candidate"
      break
    fi
  done
}

second_brain_mcp() {
  if ! command -v claude &>/dev/null; then
    return
  fi

  second_brain_find_binaries
  local sb_mcp="$SB_MCP_BIN" sb_api="$SB_API_BIN"

  if [[ -z "$sb_mcp" ]]; then
    log_warn "second-brain-mcp binary not found, skipping MCP registration"
    return
  fi

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
Environment=SECOND_BRAIN_DB=$HOME/.second-brain/brain.db
Environment=SECOND_BRAIN_BIND=127.0.0.1:7200
Restart=on-failure
RestartSec=5
TimeoutStartSec=60

[Install]
WantedBy=default.target
UNIT

  # WHY: lingering keeps this user's systemd instance (and this service) running
  # across logout/reboot; without it the daemon looks healthy right up until the
  # session ends, then silently stops until someone logs back in.
  if command -v loginctl &>/dev/null; then
    loginctl enable-linger "$(whoami)" 2>/dev/null || true
  fi

  if command -v systemctl &>/dev/null; then
    systemctl --user daemon-reload
    systemctl --user enable second-brain.service 2>/dev/null || true
    if systemctl --user is-active --quiet second-brain.service 2>/dev/null; then
      # WHY: cargo install --force replaces the binary on disk but the running
      # process keeps its old copy open until restarted, so a rebuilt binary
      # (e.g. after bumping SECOND_BRAIN_REV) would otherwise silently keep
      # serving the previous rev with no error anywhere.
      local bin_mtime svc_start_epoch
      bin_mtime=$(stat -c %Y "$sb_api" 2>/dev/null || echo 0)
      svc_start_epoch=$(date -d "$(systemctl --user show second-brain.service -p ActiveEnterTimestamp --value)" +%s 2>/dev/null || echo 0)
      if [[ "$bin_mtime" -gt "$svc_start_epoch" ]]; then
        systemctl --user restart second-brain.service 2>/dev/null || true
        log_success "daemon: second-brain service restarted (binary updated since last start)"
      else
        log_skip "daemon: second-brain service" "already running the current binary"
      fi
    else
      systemctl --user start second-brain.service 2>/dev/null || true
      log_success "daemon: second-brain service installed and started"
    fi
  else
    log_warn "systemctl not found, service file written but not activated"
  fi
}


second_brain_sync_timer() {
  local sb_sync_src="$REPO_ROOT/configs/second-brain/sb-sync.sh"
  local bin_dir="$HOME/.local/bin"
  local service_dir="$HOME/.config/systemd/user"
  local peers_file="$HOME/.second-brain/sync-peers"

  if [[ ! -f "$sb_sync_src" ]]; then
    log_warn "sb-sync.sh template missing, skipping sync timer"
    return
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would install second-brain sync timer"
    return
  fi

  mkdir -p "$bin_dir" "$service_dir" "$HOME/.second-brain"
  install -m755 "$sb_sync_src" "$bin_dir/sb-sync.sh"

  # Peers are per-machine; never overwrite an existing list. Seed an empty,
  # commented file so the guard exits cleanly until the user adds peers.
  if [[ ! -f "$peers_file" ]]; then
    cat > "$peers_file" <<'PEERS'
# second-brain sync peers, one user@host per line. Example:
# anish@10.0.0.2
PEERS
    log_info "seeded empty $peers_file (add peers to enable auto-sync)"
  fi

  cat > "$service_dir/sb-sync.service" <<'UNIT'
[Unit]
Description=Second Brain peer sync (skips silently when a peer is unreachable)
After=network-online.target

[Service]
Type=oneshot
ExecStart=%h/.local/bin/sb-sync.sh
UNIT

  cat > "$service_dir/sb-sync.timer" <<'UNIT'
[Unit]
Description=Run Second Brain peer sync every 30 minutes when peers are reachable

[Timer]
OnCalendar=*:0/30
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
UNIT

  if command -v systemctl &>/dev/null; then
    systemctl --user daemon-reload
    systemctl --user enable --now sb-sync.timer 2>/dev/null || true
    log_success "sync timer: sb-sync.timer installed and enabled"
  else
    log_warn "systemctl not found, sync timer written but not activated"
  fi
}

second_brain_install() {
  second_brain_binaries
  second_brain_sync_timer
}

second_brain_test() {
    local tmp_dir
    tmp_dir=$(mktemp -d)

    local orig_home="$HOME"
    local orig_dry="$DRY_RUN"
    local orig_path="$PATH"

    export HOME="$tmp_dir"
    export PATH="/nonexistent:$orig_path"
    DRY_RUN=true

    # Hide existing binaries so dry-run install path triggers
    hash -r 2>/dev/null || true

    local output
    output=$(second_brain_install 2>&1)

    HOME="$orig_home"
    DRY_RUN="$orig_dry"
    export PATH="$orig_path"
    rm -rf "$tmp_dir"

    if ! echo "$output" | grep -q '\[dry-run\]\|skip'; then
        log_error "second_brain_test: no output produced"
        return 1
    fi

    return 0
}
