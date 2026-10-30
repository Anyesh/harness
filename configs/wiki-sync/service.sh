#!/usr/bin/env bash

WS_LABEL=com.harness.wiki-sync

ws_is_darwin() {
  [[ "$(uname -s)" == Darwin ]]
}

ws_agent_plist() {
  printf '%s/Library/LaunchAgents/%s.plist\n' "$HOME" "${1:-$WS_LABEL}"
}

ws_loaded() {
  if ws_is_darwin; then
    launchctl print "gui/$(id -u)/$WS_LABEL" >/dev/null 2>&1
  else
    systemctl --user is-active --quiet wiki-sync.service
  fi
}

ws_stop() {
  if ws_is_darwin; then
    launchctl bootout "gui/$(id -u)/$WS_LABEL" 2>/dev/null || true
  else
    systemctl --user stop wiki-sync.service
  fi
}

ws_start() {
  if ws_is_darwin; then
    ws_loaded || launchctl bootstrap "gui/$(id -u)" "$(ws_agent_plist)"
  else
    systemctl --user start wiki-sync.service
  fi
}

ws_try_restart() {
  if ws_is_darwin; then
    ws_loaded && launchctl kickstart -k "gui/$(id -u)/$WS_LABEL"
  else
    systemctl --user try-restart wiki-sync.service
  fi
}
