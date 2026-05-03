#!/bin/bash

backup_file() {
  local file="$1"
  local backup_dir="${HARNESS_BACKUP_DIR:-$HOME/.harness-backups}"
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)
  local dest_dir="$backup_dir/$timestamp"

  if [[ ! -f "$file" ]]; then
    return 0
  fi

  mkdir -p "$dest_dir"
  local relative="${file#$HOME/}"
  local backup_path="$dest_dir/$relative"
  mkdir -p "$(dirname "$backup_path")"
  cp -p "$file" "$backup_path"
  log_info "backed up: $file"
}

backup_if_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then
    backup_file "$file"
  fi
}

restore_latest() {
  local backup_dir="${HARNESS_BACKUP_DIR:-$HOME/.harness-backups}"
  local latest
  latest=$(ls -1t "$backup_dir" 2>/dev/null | head -1)

  if [[ -z "$latest" ]]; then
    log_error "no backups found"
    return 1
  fi

  log_info "restoring from backup: $latest"
  local src_dir="$backup_dir/$latest"

  find "$src_dir" -type f | while read -r backup_file; do
    local relative="${backup_file#$src_dir/}"
    local dest="$HOME/$relative"
    mkdir -p "$(dirname "$dest")"
    cp -p "$backup_file" "$dest"
    log_info "restored: $dest"
  done
}
