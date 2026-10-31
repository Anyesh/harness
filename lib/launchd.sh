#!/usr/bin/env bash

launchd_domain() {
  printf 'gui/%s\n' "$(id -u)"
}

launchd_agents_dir() {
  printf '%s\n' "$HOME/Library/LaunchAgents"
}

# launchd can refuse a bootstrap for a moment after bootout of the same label (error 5).
launchd_bootstrap() {
  local attempt
  for attempt in 1 2 3 4 5; do
    launchctl bootstrap "$1" "$2" 2>/dev/null && return 0
    sleep 1
  done
  launchctl bootstrap "$1" "$2"
}

# Args: rendered plist, label. Unloads any running copy of the agent, installs
# the plist into ~/Library/LaunchAgents and loads it.
launchd_reload_agent() {
  local rendered="$1" label="$2" dir domain
  dir=$(launchd_agents_dir)
  domain=$(launchd_domain)
  mkdir -p "$dir" "$HOME/Library/Logs"
  launchctl bootout "$domain/$label" 2>/dev/null || true
  install -m 644 "$rendered" "$dir/$label.plist"
  launchd_bootstrap "$domain" "$dir/$label.plist"
}
