#!/usr/bin/env bash
set -euo pipefail

INSTALL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$INSTALL/state"
# shellcheck source=/dev/null
source "$INSTALL/env"
# shellcheck source=service.sh
source "$INSTALL/service.sh"

ws_loaded && ws_stop
mkdir -p "$INSTALL/snapshots"
snap="$INSTALL/snapshots/reset-$(date -u +%Y%m%dT%H%M%S).tar.gz"
[[ ! -e "$snap" ]] || {
  echo "reset: $snap already exists" >&2
  exit 1
}
tar -czf "$snap" -C "$(dirname "$WIKI_SYNC_DIR")" "$(basename "$WIKI_SYNC_DIR")"
echo "reset: snapshot of the wiki in $snap"
rm -rf "$STATE/base"
rm -f "$STATE/checkpoint.json" "$STATE/identity.json" "$STATE/pauses.json" "$STATE/first-start-done" \
  "$STATE/health.json" "$STATE/release-deletions"
echo "reset: sync state cleared; the next start runs as a first start"
ws_start
echo "reset: wiki-sync started"
