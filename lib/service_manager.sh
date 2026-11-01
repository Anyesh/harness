#!/usr/bin/env bash

service_account_home() {
  local home
  if [[ "$(uname -s)" == Darwin ]]; then
    home=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
  else
    home=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)
  fi
  [[ -n "$home" ]] && printf '%s\n' "$home"
}

service_units_subdir() {
  if [[ "$(uname -s)" == Darwin ]]; then
    printf 'Library/LaunchAgents\n'
  else
    printf '.config/systemd/user\n'
  fi
}

# Resolves symlinks in the part of the path that exists.
service_physical_path() {
  local dir="$1" rest=""
  while [[ ! -d "$dir" ]]; do
    rest="/$(basename "$dir")$rest"
    dir=$(dirname "$dir")
  done
  printf '%s%s\n' "$(cd -P "$dir" && pwd -P)" "$rest"
}

# launchd and the systemd user manager serve the account, not $HOME: loading a
# unit from a HOME that is not the account home (a test's temp dir) replaces
# the account's live service with one that points into that HOME.
service_manager_owns() {
  local unit="$1" name account
  name=$(basename "$unit" .plist)
  if ! account=$(service_account_home); then
    log_warn "cannot read the account home; not loading $name"
    return 1
  fi
  if [[ "$(service_physical_path "$(dirname "$unit")")" != "$(service_physical_path "$account/$(service_units_subdir)")" ]]; then
    log_warn "HOME is not the account home; not loading $name"
    return 1
  fi
}
