#!/bin/bash

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
