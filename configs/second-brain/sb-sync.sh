#!/bin/sh
# Auto-sync second-brain to reachable peers.
# An unreachable peer is not a failure: the timer simply retries next schedule, so
# those are skipped silently. A sync that actually runs and fails DOES exit non-zero,
# because the alternative hid a broken pull for weeks behind a green systemd unit.
# Peers: one "user@host" per line in ~/.second-brain/sync-peers (blank lines and # comments ignored).
SB="$HOME/.cargo/bin/sb"
PEERS_FILE="$HOME/.second-brain/sync-peers"
KNOWN_HOSTS="$HOME/.second-brain/known_hosts"

[ -x "$SB" ] || { echo "$(date -Is) sb binary missing at $SB"; exit 1; }
[ -f "$PEERS_FILE" ] || { echo "$(date -Is) no peers file ($PEERS_FILE); nothing to sync"; exit 0; }

# Local daemon must be up for sb to proxy. Not treated as a failure here because
# second-brain.service reports its own health; this unit only owns the sync.
curl -sf --max-time 5 http://127.0.0.1:7200/health >/dev/null 2>&1 || {
  echo "$(date -Is) local daemon down; pausing (timer retries next schedule)"; exit 0; }

rc=0
out="$(mktemp)"
trap 'rm -f "$out"' EXIT INT TERM

while IFS= read -r peer; do
  case "$peer" in ''|\#*) continue ;; esac
  # SSH reachability probe with the sync-owned known_hosts; silent skip if the peer is down.
  if ! ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=yes \
        -o "UserKnownHostsFile=$KNOWN_HOSTS" -o GlobalKnownHostsFile=/dev/null \
        "$peer" true >/dev/null 2>&1; then
    continue
  fi

  echo "$(date -Is) syncing with $peer"
  "$SB" sync "$peer" >"$out" 2>&1
  status=$?

  if [ "$status" -eq 0 ]; then
    grep -iE "created|updated|deleted|pushed through|warning" "$out" | sed 's/^/  /'
  else
    echo "$(date -Is) sync with $peer FAILED (exit $status)"
    tail -n 20 "$out" | sed 's/^/  /'
    rc=1
  fi
done < "$PEERS_FILE"

exit "$rc"
