#!/usr/bin/env bash

wiki_check() {
  if ! command -v sb &>/dev/null; then
    log_warn "sb command not found, wiki module requires second-brain-cli"
    log_info "  Install: cargo install second-brain-cli"
    return 1
  fi

  local vault="${WIKI_VAULT:-}"
  if [[ -z "$vault" ]]; then
    if [[ -f "$HOME/.harness.env" ]]; then
      vault=$(grep -E '^WIKI_VAULT=' "$HOME/.harness.env" 2>/dev/null | cut -d= -f2- || true)
    fi
  fi

  if [[ -z "$vault" ]]; then
    log_warn "WIKI_VAULT not set"
    log_info "  Set WIKI_VAULT in ~/.harness.env"
    return 1
  fi

  return 0
}

wiki_install() {
  local vault="${WIKI_VAULT:-}"
  if [[ -z "$vault" ]]; then
    if [[ -f "$HOME/.harness.env" ]]; then
      vault=$(grep -E '^WIKI_VAULT=' "$HOME/.harness.env" 2>/dev/null | cut -d= -f2- || true)
    fi
  fi

  if [[ -z "$vault" ]]; then
    vault="$HOME/Obsidian/SecondBrain"
    log_info "WIKI_VAULT not set, defaulting to $vault"
  fi

  if ! command -v sb &>/dev/null; then
    log_warn "sb command not found, skipping wiki module"
    return
  fi

  wiki_init_vault "$vault"
  wiki_deploy_timer "$vault"
  wiki_ensure_env "$vault"

  log_info "wiki hooks (session-start-wiki.sh, session-end-ingest.sh) are deployed by the claude module"
}

wiki_init_vault() {
  local vault="$1"

  if [[ -d "$vault/wiki" ]]; then
    log_skip "wiki vault" "already initialized at $vault"
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would run: sb wiki init \"$vault\""
    return
  fi

  if sb wiki init "$vault" 2>/dev/null; then
    log_success "wiki vault initialized at $vault"
  else
    log_warn "sb wiki init failed (vault: $vault), wiki export may not work until initialized"
  fi
}

wiki_deploy_timer() {
  local vault="$1"
  local service_dir="$HOME/.config/systemd/user"
  local service_src="$REPO_ROOT/configs/shared/second-brain-wiki-export.service"
  local timer_src="$REPO_ROOT/configs/shared/second-brain-wiki-export.timer"
  local service_dest="$service_dir/second-brain-wiki-export.service"
  local timer_dest="$service_dir/second-brain-wiki-export.timer"

  if [[ ! -f "$service_src" || ! -f "$timer_src" ]]; then
    log_warn "wiki export systemd unit files not found in $REPO_ROOT/configs/shared/"
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would deploy wiki export timer to $service_dir"
    return
  fi

  mkdir -p "$service_dir"

  sed "s|%h|$HOME|g" "$service_src" | sed "s|\${WIKI_VAULT}|$vault|g" > "$service_dest"
  cp "$timer_src" "$timer_dest"

  if command -v systemctl &>/dev/null; then
    systemctl --user daemon-reload
    systemctl --user enable second-brain-wiki-export.timer 2>/dev/null || true
    if ! systemctl --user is-active --quiet second-brain-wiki-export.timer 2>/dev/null; then
      systemctl --user start second-brain-wiki-export.timer 2>/dev/null || true
    fi
    log_success "wiki export timer installed and started (vault: $vault)"
  else
    log_warn "systemctl not found, timer files written but not activated"
  fi
}

wiki_ensure_env() {
  local vault="$1"
  local env_file="$HOME/.harness.env"
  local env_example="$REPO_ROOT/.env.example"

  if [[ -f "$env_file" ]] && grep -qE '^WIKI_VAULT=' "$env_file" 2>/dev/null; then
    log_skip "WIKI_VAULT in .harness.env" "already set"
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would add WIKI_VAULT=$vault to $env_file"
    return
  fi

  echo "WIKI_VAULT=$vault" >> "$env_file"
  log_success "WIKI_VAULT=$vault added to $env_file"

  if [[ -f "$env_example" ]] && ! grep -qE 'WIKI_VAULT' "$env_example" 2>/dev/null; then
    printf '\n# Path to the Obsidian vault for wiki export\n# WIKI_VAULT=~/Obsidian/SecondBrain\n' >> "$env_example"
  fi
}

wiki_test() {
  local tmp_dir
  tmp_dir=$(mktemp -d)

  local orig_home="$HOME"
  local orig_dry="$DRY_RUN"
  local orig_vault="${WIKI_VAULT:-}"
  local orig_path="$PATH"

  export HOME="$tmp_dir"
  DRY_RUN=true
  WIKI_VAULT="$tmp_dir/test-vault"
  echo "WIKI_VAULT=$tmp_dir/test-vault" > "$tmp_dir/.harness.env"

  printf '#!/bin/sh\necho "mock sb $*"\n' > "$tmp_dir/sb"
  chmod +x "$tmp_dir/sb"
  export PATH="$tmp_dir:$PATH"

  local output
  output=$(wiki_install 2>&1)

  HOME="$orig_home"
  DRY_RUN="$orig_dry"
  WIKI_VAULT="$orig_vault"
  export PATH="$orig_path"
  rm -rf "$tmp_dir"

  if ! echo "$output" | grep -q '\[dry-run\]'; then
      log_error "wiki_test: no dry-run output produced"
      return 1
  fi

  return 0
}
