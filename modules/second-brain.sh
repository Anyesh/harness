#!/usr/bin/env bash

source "$REPO_ROOT/lib/launchd.sh"
source "$REPO_ROOT/lib/service_manager.sh"

SECOND_BRAIN_CRATES=(second-brain-cli second-brain-mcp second-brain-api)
SECOND_BRAIN_UPDATED=false

second_brain_check() {
    if ! command -v sb &>/dev/null; then
        log_info "second-brain binaries not found (will attempt install)"
        if ! command -v cargo &>/dev/null; then
            log_info "  Install Rust first: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
        fi
    fi
    return 0
}

# Plain `cargo install` upgrades a crate whenever crates.io has a newer
# release, so every run lands the latest. One call per crate: a single
# multi-crate call can resolve the later crates against a stale index.
second_brain_binaries() {
  SECOND_BRAIN_UPDATED=false
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would install or upgrade ${SECOND_BRAIN_CRATES[*]} from crates.io"
    return
  fi

  if ! command -v cargo &>/dev/null; then
    log_warn "cargo not found, cannot install second-brain"
    log_warn "install Rust from https://rustup.rs, then rerun $REPO_ROOT/install.sh --only second-brain"
    return 1
  fi

  local cargo_flags=() failed=() crate before build_log
  if [[ "$FORCE" == "true" ]]; then
    cargo_flags+=(--force)
  fi
  before=$(cargo install --list 2>/dev/null || true)
  build_log=$(mktemp)
  for crate in "${SECOND_BRAIN_CRATES[@]}"; do
    log_info "second-brain: installing the latest $crate..."
    cargo install ${cargo_flags[@]+"${cargo_flags[@]}"} "$crate" >>"$build_log" 2>&1 || failed+=("$crate")
  done
  if [[ "$(cargo install --list 2>/dev/null || true)" != "$before" ]]; then
    SECOND_BRAIN_UPDATED=true
  fi

  if [[ ${#failed[@]} -eq 0 ]] && command -v sb &>/dev/null; then
    if [[ "$SECOND_BRAIN_UPDATED" == "true" ]]; then
      log_success "second-brain: latest release installed"
    else
      log_skip "second-brain" "already at the latest release"
    fi
    rm -f "$build_log"
    return 0
  fi

  log_warn "second-brain install failed: ${failed[*]:-sb is not on PATH}"
  grep -iE "error|failed|cannot|missing" "$build_log" | tail -10 >&2 || true
  rm -f "$build_log"
  log_warn "rerun: $REPO_ROOT/install.sh --only second-brain"
  return 1
}

# Sets SB_MCP_BIN to the resolved second-brain-mcp path, or "" when it isn't
# installed. Shared by every module that registers the second-brain MCP server
# (claude, codex, opencode) so the lookup order lives in exactly one place.
second_brain_find_binaries() {
  SB_MCP_BIN=""
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
}

second_brain_mcp() {
  if ! command -v claude &>/dev/null; then
    return
  fi

  second_brain_find_binaries
  local sb_mcp="$SB_MCP_BIN"

  if [[ -z "$sb_mcp" ]]; then
    log_warn "second-brain-mcp binary not found, skipping MCP registration"
    return
  fi

  local existing
  existing=$(claude mcp list 2>/dev/null | grep "^second-brain:" || true)
  if [[ -n "$existing" ]]; then
    log_skip "mcp: second-brain" "already registered"
  elif [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would register second-brain MCP (binary: $sb_mcp)"
  else
    if claude mcp add -s user "second-brain" \
      -e SECOND_BRAIN_API="http://127.0.0.1:7200" \
      -- "$sb_mcp" 2>/dev/null; then
      log_success "mcp: second-brain registered (binary: $sb_mcp)"
    else
      log_warn "mcp: second-brain registration failed"
    fi
  fi
}

# The API service belongs to second-brain's own `sb setup`, which writes
# service.json; harness only points at it.
second_brain_service_hint() {
  if [[ ! -f "$HOME/.second-brain/service.json" ]]; then
    log_info "second-brain: run sb setup to install the second-brain service"
  elif [[ "$SECOND_BRAIN_UPDATED" == "true" ]]; then
    log_warn "second-brain: run sb restart to load the new version"
  fi
}

second_brain_render_agent() {
  local label="$1" dest="$2"
  sed -e "s|@HOME@|$HOME|g" "$REPO_ROOT/configs/second-brain/launchd/$label.plist" >"$dest"
}

# Succeeds when the agent is loaded from a plist identical to the rendered one.
second_brain_agent_current() {
  local label="$1" rendered="$2"
  launchctl print "$(launchd_domain)/$label" >/dev/null 2>&1 &&
    cmp -s "$rendered" "$(launchd_agents_dir)/$label.plist"
}

second_brain_sync_timer() {
  local sb_sync_src="$REPO_ROOT/configs/second-brain/sb-sync.sh"
  local bin_dir="$HOME/.local/bin"
  local peers_file="$HOME/.second-brain/sync-peers"

  if [[ ! -f "$sb_sync_src" ]]; then
    log_warn "sb-sync.sh template missing, skipping sync timer"
    return
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would install second-brain sync timer"
    return
  fi

  mkdir -p "$bin_dir" "$HOME/.second-brain"
  install -m755 "$sb_sync_src" "$bin_dir/sb-sync.sh"

  # Peers are per-machine; never overwrite an existing list. Seed an empty,
  # commented file so the guard exits cleanly until the user adds peers.
  if [[ ! -f "$peers_file" ]]; then
    cat > "$peers_file" <<'PEERS'
# second-brain sync peers, one user@host per line. Example:
# user@host
PEERS
    log_info "seeded empty $peers_file (add peers to enable auto-sync)"
  fi

  if [[ "$(uname -s)" == Darwin ]]; then
    second_brain_sync_agent_darwin
  else
    second_brain_sync_timer_linux
  fi
}

second_brain_sync_timer_linux() {
  local service_dir="$HOME/.config/systemd/user"

  service_manager_owns "$service_dir/sb-sync.timer" || return 0
  mkdir -p "$service_dir"

  # WHY: without lingering the user's systemd instance, and this timer with
  # it, stops at logout and stays stopped until the next login.
  if command -v loginctl &>/dev/null; then
    loginctl enable-linger "$(whoami)" 2>/dev/null || true
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

second_brain_sync_agent_darwin() {
  local label=com.harness.sb-sync rendered
  service_manager_owns "$(launchd_agents_dir)/$label.plist" || return 0
  rendered=$(mktemp)
  second_brain_render_agent "$label" "$rendered"
  if second_brain_agent_current "$label" "$rendered"; then
    log_skip "sync agent: $label" "already loaded"
  elif launchd_reload_agent "$rendered" "$label"; then
    log_success "sync agent: $label installed, runs every 30 minutes"
  else
    log_warn "sync agent: launchctl could not load $label"
  fi
  rm -f "$rendered"
}

second_brain_install() {
  second_brain_binaries
  second_brain_service_hint
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
