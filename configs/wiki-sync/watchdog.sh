#!/usr/bin/env bash
set -uo pipefail

INSTALL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$INSTALL/state"
HEALTH="$STATE/health.json"
# shellcheck source=service.sh
source "$INSTALL/service.sh"

say() {
  printf 'wiki-sync watchdog: %s\n' "$*"
}

restart() {
  say "restarting: $1"
  ws_try_restart
}

ws_loaded || exit 0

if ! "$INSTALL/run.sh" --check-fingerprint >/dev/null 2>&1; then
  restart "the CouchDB login or passphrase in the plugin settings changed"
  exit 0
fi

[[ -r "$HEALTH" ]] || exit 0
now=$(($(date +%s) * 1000))
read -r ts feed paused remote handler caught < <(jq -r \
  '[.ts, .feedTs, ((.paused or .locked) | tostring), .remote, .oldestHandlerMs, (.caughtUp | tostring)] | @tsv' \
  "$HEALTH" 2>/dev/null) || exit 0

if [[ "$remote" == ok && "$caught" == true && ! -e "$STATE/first-start-done" ]]; then
  : >"$STATE/first-start-done"
  say "first start finished"
fi
if [[ "$remote" == auth ]]; then
  say "CouchDB rejected the login; fix the plugin settings (not restarting)"
  exit 0
fi
if ((now - ts > 90000)); then
  restart "health.json is $(((now - ts) / 1000)) s old"
elif [[ "$paused" != true && "$remote" != unreachable ]] && ((now - feed > 180000)); then
  restart "the changes feed has been silent for $(((now - feed) / 1000)) s"
elif ((handler > 300000)); then
  restart "a handler has run for $((handler / 1000)) s"
fi
exit 0
