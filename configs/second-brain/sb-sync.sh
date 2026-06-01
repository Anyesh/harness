#!/bin/sh
# Auto-sync second-brain to reachable peers. Silent (exit 0) when a peer is down so the
# timer simply retries next schedule; logs a line only when a sync actually runs.
# Peers: one "user@host" per line in ~/.second-brain/sync-peers (blank lines and # comments ignored).
SB="$HOME/.cargo/bin/sb"
PEERS_FILE="$HOME/.second-brain/sync-peers"
KNOWN_HOSTS="$HOME/.second-brain/known_hosts"

[ -x "$SB" ] || { echo "$(date -Is) sb binary missing at $SB"; exit 0; }
[ -f "$PEERS_FILE" ] || { echo "$(date -Is) no peers file ($PEERS_FILE); nothing to sync"; exit 0; }

# Local daemon must be up for sb to proxy; if not, stay quiet and let the next tick retry.
curl -sf --max-time 5 http://127.0.0.1:7200/health >/dev/null 2>&1 || {
  echo "$(date -Is) local daemon down; pausing (timer retries next schedule)"; exit 0; }

while IFS= read -r peer; do
  case "$peer" in ''|\#*) continue ;; esac
  host="${peer#*@}"
  # SSH reachability probe with the sync-owned known_hosts; silent skip if the peer is down.
  if ! ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=yes \
        -o "UserKnownHostsFile=$KNOWN_HOSTS" -o GlobalKnownHostsFile=/dev/null \
        "$peer" true >/dev/null 2>&1; then
    continue
  fi
  echo "$(date -Is) syncing with $peer"
  "$SB" sync "$peer" 2>&1 | grep -iE "created|updated|deleted|pushed through|error" | sed "s/^/  /"
done < "$PEERS_FILE"
exit 0
