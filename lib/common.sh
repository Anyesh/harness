#!/usr/bin/env bash

set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-$HOME/.harness}"
HARNESS_ENV="${HARNESS_ENV:-$HOME/.harness.env}"
HARNESS_MANIFEST="${HARNESS_MANIFEST:-$HOME/.harness-manifest.json}"
HARNESS_BACKUP_DIR="${HARNESS_BACKUP_DIR:-$HOME/.harness-backups}"

if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

INSTALLED=0
UPDATED=0
SKIPPED=0
FAILED=0

log_info() {
  printf "${BLUE}[harness]${RESET} %s\n" "$1"
}

log_success() {
  printf "${GREEN}[harness]${RESET} %s\n" "$1"
  INSTALLED=$((INSTALLED + 1))
}

log_update() {
  printf "${GREEN}[harness]${RESET} %s\n" "$1"
  UPDATED=$((UPDATED + 1))
}

log_skip() {
  printf "${YELLOW}[harness]${RESET} skip: %s (%s)\n" "$1" "$2"
  SKIPPED=$((SKIPPED + 1))
}

log_error() {
  printf "${RED}[harness]${RESET} ERROR: %s\n" "$1" >&2
  FAILED=$((FAILED + 1))
}

log_warn() {
  printf "${YELLOW}[harness]${RESET} WARN: %s\n" "$1" >&2
}

log_section() {
  printf "\n${BOLD}=== %s ===${RESET}\n\n" "$1"
}

report_summary() {
  echo ""
  log_section "Summary"
  printf "  Installed: ${GREEN}%d${RESET}\n" "$INSTALLED"
  printf "  Updated:   ${GREEN}%d${RESET}\n" "$UPDATED"
  printf "  Skipped:   ${YELLOW}%d${RESET}\n" "$SKIPPED"
  printf "  Failed:    ${RED}%d${RESET}\n" "$FAILED"
  echo ""
}

die() {
  log_error "$1"
  exit 1
}

require_command() {
  if ! command -v "$1" &>/dev/null; then
    die "required command not found: $1"
  fi
}

# The env file can hold tokens: keep its mode (mktemp gives a new one 600) and
# check every step explicitly, since callers run this under `|| die` where set -e is off.
harness_env_set() {
  local name="$1" value="$2" file="$HARNESS_ENV" tmp
  tmp=$(mktemp "$file.XXXXXX") || return 1
  if [[ -f "$file" ]]; then
    cp -p "$file" "$tmp" && { grep -v "^${name}=" "$file" >"$tmp" || [[ $? -eq 1 ]]; } || {
      rm -f "$tmp"
      return 1
    }
  fi
  printf '%s=%s\n' "$name" "$value" >>"$tmp" && mv "$tmp" "$file" || {
    rm -f "$tmp"
    return 1
  }
}

# Plain readlink in a loop because BSD readlink only learned -f in macOS 12.3.
resolve_symlink_chain() {
  local path="$1" target hops=0
  while [[ -L "$path" ]]; do
    if ((hops >= 40)); then
      log_error "too many symlink hops resolving $1 (cycle?)"
      return 1
    fi
    hops=$((hops + 1))
    target=$(readlink "$path") || return 1
    [[ "$target" == /* ]] || target="$(dirname "$path")/$target"
    path="$target"
  done
  printf '%s\n' "$path"
}

atomic_copy_stage() {
  local src="$1" target="$2" tmp="$3" mode="$4"
  if [[ "$mode" == "preserve" ]]; then
    cp -p "$src" "$tmp" || return 1
  elif [[ -e "$target" ]]; then
    cp -p "$target" "$tmp" || return 1
    cp "$src" "$tmp" || return 1
  else
    rm -f "$tmp" || return 1
    cp "$src" "$tmp" || return 1
  fi
  if [[ "$mode" == "executable" ]]; then
    chmod +x "$tmp" || return 1
  fi
}

# Replaces dest by rename so a process still reading the old file (a running
# bash script) keeps its inode. A symlinked dest is followed and its target
# replaced, so the link survives. A replaced file keeps its mode, a new one gets
# plain cp's mode; "executable" adds +x, "preserve" takes the source's mode.
atomic_copy() {
  local src="$1" dest="$2" mode="${3:-}" target dir tmp
  target=$(resolve_symlink_chain "$dest") || return 1
  dir=$(dirname "$target")
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.$(basename "$target").XXXXXX") || return 1
  if ! atomic_copy_stage "$src" "$target" "$tmp" "$mode" || ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"
    return 1
  fi
}
