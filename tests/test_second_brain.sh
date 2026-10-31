#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

assert() {
  local name="$1"
  local cmd="$2"
  if eval "$cmd"; then
    printf '  PASS  %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$name"
    FAIL=$((FAIL + 1))
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ISO_UTC='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z '

echo ""
echo "=== sb-sync.sh ==="

# BSD date has no -I, so this stub refuses it the way macOS does.
mkdir -p "$TMP/bsd-bin"
REAL_DATE=$(command -v date)
cat >"$TMP/bsd-bin/date" <<EOF
#!/bin/sh
case "\$1" in -I*) echo "date: illegal option -- I" >&2; exit 1 ;; esac
exec "$REAL_DATE" "\$@"
EOF
chmod +x "$TMP/bsd-bin/date"

H="$TMP/sync-nosb"
mkdir -p "$H"
rc=0
out=$(HOME="$H" PATH="$TMP/bsd-bin:$PATH" sh "$REPO_ROOT/configs/second-brain/sb-sync.sh" 2>&1) || rc=$?
assert "missing sb: exits 1 with a UTC timestamp under BSD date" '[[ $rc -eq 1 ]] && grep -Eq "${ISO_UTC}sb binary missing" <<<"$out"'

H="$TMP/sync-nopeers"
mkdir -p "$H/.cargo/bin"
printf '#!/bin/sh\nexit 0\n' >"$H/.cargo/bin/sb"
chmod +x "$H/.cargo/bin/sb"
rc=0
out=$(HOME="$H" PATH="$TMP/bsd-bin:$PATH" sh "$REPO_ROOT/configs/second-brain/sb-sync.sh" 2>&1) || rc=$?
assert "no peers file: exits 0 with a UTC timestamp under BSD date" '[[ $rc -eq 0 ]] && grep -Eq "${ISO_UTC}no peers file" <<<"$out"'

# Builds a fake HOME with a fake second-brain-api and service-manager stubs
# that log their argv; $home/active makes the daemon look running.
new_home() {
  local home="$1" tool
  mkdir -p "$home/bin" "$home/.cargo/bin"
  printf '#!/bin/sh\nexit 0\n' >"$home/.cargo/bin/second-brain-api"
  chmod +x "$home/.cargo/bin/second-brain-api"
  touch -t 202001010000 "$home/.cargo/bin/second-brain-api"
  for tool in systemctl launchctl loginctl; do
    cat >"$home/bin/$tool" <<EOF
#!/bin/sh
echo "$tool \$*" >> "$home/calls.log"
case "\$*" in
  *is-active*) [ -e "$home/active" ] ;;
  print*) [ -e "$home/active" ] ;;
  *) exit 0 ;;
esac
EOF
    chmod +x "$home/bin/$tool"
  done
  cat >"$home/bin/uname" <<EOF
#!/bin/sh
case "\$1" in -m) echo arm64 ;; *) echo "\${FAKE_OS:-Linux}" ;; esac
EOF
  chmod +x "$home/bin/uname"
  : >"$home/calls.log"
}

module() {
  local home="$1"
  shift
  HOME="$home" PATH="$home/bin:$PATH" REPO_ROOT="$REPO_ROOT" DRY_RUN=false FORCE=false bash -c '
      set -euo pipefail
      source "$REPO_ROOT/lib/common.sh"
      source "$REPO_ROOT/modules/second-brain.sh"
      "$@"' _ "$@"
}

daemon() { module "$1" second_brain_daemon "$1/.cargo/bin/second-brain-api"; }
sync_timer() { module "$1" second_brain_sync_timer; }

echo ""
echo "=== Linux daemon and sync timer ==="

H="$TMP/linux"
new_home "$H"
out=$(daemon "$H" 2>&1)
UNIT="$H/.config/systemd/user/second-brain.service"
assert "linux: unit runs the api with its environment" \
  'grep -q "ExecStart=$H/.cargo/bin/second-brain-api" "$UNIT" && grep -q "Environment=SECOND_BRAIN_DB=$H/.second-brain/brain.db" "$UNIT" && grep -q "Environment=SECOND_BRAIN_BIND=127.0.0.1:7200" "$UNIT" && grep -q "Environment=FASTEMBED_CACHE_DIR=$H/.second-brain/fastembed" "$UNIT"'
assert "linux: a stopped daemon is enabled and started" \
  'grep -q "systemctl --user enable second-brain.service" "$H/calls.log" && grep -q "systemctl --user start second-brain.service" "$H/calls.log"'
assert "linux: linger enabled" 'grep -q "loginctl enable-linger" "$H/calls.log"'

touch "$H/active"
: >"$H/calls.log"
out=$(daemon "$H" 2>&1)
assert "linux: a running daemon on the current binary is left alone" \
  '! grep -q "restart second-brain.service" "$H/calls.log" && grep -q "already running the current binary" <<<"$out"'

touch -t 203001010000 "$H/.cargo/bin/second-brain-api"
: >"$H/calls.log"
out=$(daemon "$H" 2>&1)
assert "linux: a binary newer than the last start restarts the daemon" \
  'grep -q "systemctl --user restart second-brain.service" "$H/calls.log"'

: >"$H/calls.log"
out=$(sync_timer "$H" 2>&1)
assert "linux: sync timer units written and enabled" \
  '[[ -f $H/.config/systemd/user/sb-sync.service && -f $H/.config/systemd/user/sb-sync.timer ]] && grep -q "systemctl --user enable --now sb-sync.timer" "$H/calls.log"'
assert "linux: sb-sync.sh installed and peers file seeded" '[[ -x $H/.local/bin/sb-sync.sh && -f $H/.second-brain/sync-peers ]]'
assert "linux: no launchctl calls" '! grep -q launchctl "$H/calls.log"'

echo ""
echo "=== macOS daemon and sync agents ==="

H="$TMP/mac"
new_home "$H"
AGENTS="$H/Library/LaunchAgents"
DAEMON_PLIST="$AGENTS/com.harness.second-brain.plist"
SYNC_PLIST="$AGENTS/com.harness.sb-sync.plist"
out=$(FAKE_OS=Darwin daemon "$H" 2>&1)
out+=$(FAKE_OS=Darwin sync_timer "$H" 2>&1)
assert "mac: both agents bootstrapped" \
  'grep -q "launchctl bootstrap gui/[0-9]* $DAEMON_PLIST" "$H/calls.log" && grep -q "launchctl bootstrap gui/[0-9]* $SYNC_PLIST" "$H/calls.log"'
assert "mac: no systemctl calls and no systemd units" '! grep -q systemctl "$H/calls.log" && [[ ! -e $H/.config/systemd ]]'
assert "mac: daemon agent runs the api with its environment and stays alive" \
  'grep -q "<string>$H/.cargo/bin/second-brain-api</string>" "$DAEMON_PLIST" && grep -q "<string>$H/.second-brain/brain.db</string>" "$DAEMON_PLIST" && grep -q "<string>127.0.0.1:7200</string>" "$DAEMON_PLIST" && grep -q "<string>$H/.second-brain/fastembed</string>" "$DAEMON_PLIST" && grep -A1 "<key>KeepAlive</key>" "$DAEMON_PLIST" | grep -q "<true/>"'
assert "mac: sync agent runs sb-sync.sh every 30 minutes and at load" \
  'grep -q "<string>$H/.local/bin/sb-sync.sh</string>" "$SYNC_PLIST" && grep -A1 "<key>StartInterval</key>" "$SYNC_PLIST" | grep -q "<integer>1800</integer>" && grep -A1 "<key>RunAtLoad</key>" "$SYNC_PLIST" | grep -q "<true/>"'
assert "mac: agents get a Homebrew PATH, log under Library/Logs and keep no placeholder" \
  'grep -q "/opt/homebrew/bin" "$DAEMON_PLIST" && grep -q "/opt/homebrew/bin" "$SYNC_PLIST" && grep -q "$H/Library/Logs/second-brain.log" "$DAEMON_PLIST" && grep -q "$H/Library/Logs/sb-sync.log" "$SYNC_PLIST" && ! grep -q @ "$DAEMON_PLIST" "$SYNC_PLIST"'
if command -v plutil >/dev/null 2>&1; then
  assert "mac: plists pass plutil -lint" 'plutil -lint "$DAEMON_PLIST" "$SYNC_PLIST" >/dev/null'
fi

touch "$H/active"
: >"$H/calls.log"
out=$(FAKE_OS=Darwin daemon "$H" 2>&1)
out+=$(FAKE_OS=Darwin sync_timer "$H" 2>&1)
assert "mac: loaded agents with unchanged plists and binary are left alone" \
  '! grep -qE "bootstrap|bootout|kickstart" "$H/calls.log"'

touch -t 203001010000 "$H/.cargo/bin/second-brain-api"
: >"$H/calls.log"
out=$(FAKE_OS=Darwin daemon "$H" 2>&1)
assert "mac: a binary newer than the last start restarts the daemon in place" \
  'grep -q "launchctl kickstart -k gui/[0-9]*/com.harness.second-brain$" "$H/calls.log" && ! grep -q bootstrap "$H/calls.log"'

echo "<!-- stale -->" >>"$DAEMON_PLIST"
: >"$H/calls.log"
out=$(FAKE_OS=Darwin daemon "$H" 2>&1)
assert "mac: a changed plist is booted out and bootstrapped again" \
  'grep -q "launchctl bootout gui/[0-9]*/com.harness.second-brain$" "$H/calls.log" && grep -q "launchctl bootstrap gui/[0-9]* $DAEMON_PLIST" "$H/calls.log" && ! grep -q stale "$DAEMON_PLIST"'

echo ""
echo "Second-brain: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
