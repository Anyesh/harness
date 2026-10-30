#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_HOME="$HOME"
unset HARNESS_WORK WIKI_VAULT

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
PINNED=$(sed -n 's/^WIKI_SYNC_DENO_VERSION=//p' "$REPO_ROOT/configs/wiki-sync/pins.env")

# Args: home, "work" for a work machine. Builds a fake HOME with a vault, the
# plugin's data.json, a pre-installed fake Deno and stubs that log their argv.
new_home() {
  local home="$1" mode="${2:-}" tool
  mkdir -p "$home/bin" "$home/vault/wiki/projects" "$home/vault/.obsidian/plugins/obsidian-livesync"
  echo '{}' >"$home/vault/.obsidian/plugins/obsidian-livesync/data.json"
  echo "note" >"$home/vault/wiki/projects/a.md"
  if [[ "$mode" == work ]]; then
    mkdir -p "$home/vault/Work/agent-wiki/wiki"
    printf 'WIKI_VAULT=%s/vault\nHARNESS_WORK=1\n' "$home" >"$home/.harness.env"
  else
    printf 'WIKI_VAULT=%s/vault\n' "$home" >"$home/.harness.env"
  fi
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
case "\$1" in -s) echo "\${FAKE_OS:-Linux}" ;; -m) echo x86_64 ;; *) echo "\${FAKE_OS:-Linux}" ;; esac
EOF
  chmod +x "$home/bin/uname"
  cat >"$home/bin/curl" <<EOF
#!/bin/sh
echo "curl \$*" >> "$home/calls.log"
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && { shift; echo notdeno > "\$1"; }; shift; done
EOF
  chmod +x "$home/bin/curl"
  mkdir -p "$home/.local/share/harness/wiki-sync/deno"
  cat >"$home/.local/share/harness/wiki-sync/deno/deno" <<EOF
#!/bin/sh
echo "deno \$*" >> "$home/calls.log"
[ "\$1" = --version ] && echo "deno $PINNED (stable, release, x86_64-unknown-linux-gnu)"
exit 0
EOF
  chmod +x "$home/.local/share/harness/wiki-sync/deno/deno"
  : >"$home/calls.log"
}

# Runs one module function in a fresh shell so profile.sh rereads the env file.
module() {
  local home="$1"
  shift
  HOME="$home" HARNESS_ENV="$home/.harness.env" PATH="$home/bin:$PATH" XDG_CONFIG_HOME="$home/.config" \
    REPO_ROOT="$REPO_ROOT" DRY_RUN="${DRY_RUN:-false}" bash -c '
      source "$REPO_ROOT/lib/common.sh"
      source "$REPO_ROOT/lib/profile.sh"
      source "$REPO_ROOT/modules/wiki-sync.sh"
      "$@"' _ "$@"
}

echo ""
echo "=== gates ==="

H="$TMP/gate"
new_home "$H"
rm "$H/vault/.obsidian/plugins/obsidian-livesync/data.json"
rc=0
out=$(module "$H" wiki_sync_check 2>&1) || rc=$?
assert "no plugin settings: check fails and says why" '[[ $rc -ne 0 ]] && grep -q "no LiveSync plugin settings" <<<"$out"'

H="$TMP/wsl"
new_home "$H"
echo "Linux version 5.15 microsoft-standard-WSL2" >"$TMP/wsl-version"
rc=0
out=$(WIKI_SYNC_PROC_VERSION="$TMP/wsl-version" module "$H" wiki_sync_check 2>&1) || rc=$?
assert "WSL: check fails" '[[ $rc -ne 0 ]] && grep -q WSL <<<"$out"'

H="$TMP/tools"
new_home "$H"
mkdir -p "$TMP/minbin"
for t in bash sh sed grep dirname basename cat head tail cut tr mktemp rm jq tar curl sha256sum shasum; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$TMP/minbin/$t"
done
rc=0
out=$(HOME="$H" HARNESS_ENV="$H/.harness.env" PATH="$H/bin:$TMP/minbin" REPO_ROOT="$REPO_ROOT" "$TMP/minbin/bash" -c '
  source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/profile.sh"; source "$REPO_ROOT/modules/wiki-sync.sh"
  wiki_sync_check' 2>&1) || rc=$?
assert "missing unzip: check fails and names it" '[[ $rc -ne 0 ]] && grep -q "unzip not found" <<<"$out"'

H="$TMP/ok"
new_home "$H"
rc=0
module "$H" wiki_sync_check >/dev/null 2>&1 || rc=$?
assert "complete setup: check passes" '[[ $rc -eq 0 ]]'

echo ""
echo "=== vault resolution ==="

H="$TMP/work"
new_home "$H" work
out=$(module "$H" eval 'wiki_sync_resolve; echo "$WS_VAULT|$WS_WIKI_DIR"')
assert "work mode: wiki dir is Work/agent-wiki/wiki under the vault holding data.json" \
  '[[ "$out" == "$H/vault|$H/vault/Work/agent-wiki/wiki" ]]'
printf 'WIKI_VAULT=%s/vault/Work/agent-wiki\nHARNESS_WORK=1\n' "$H" >"$H/.harness.env"
out=$(module "$H" eval 'wiki_sync_resolve; echo "$WS_VAULT|$WS_WIKI_DIR"')
assert "work mode: an already mapped WIKI_VAULT resolves the same" \
  '[[ "$out" == "$H/vault|$H/vault/Work/agent-wiki/wiki" ]]'

echo ""
echo "=== Linux install ==="

H="$TMP/linux"
new_home "$H"
INSTALL="$H/.local/share/harness/wiki-sync"
module "$H" wiki_sync_install >"$TMP/linux.out" 2>&1 || true
UNITS="$H/.config/systemd/user"
assert "linux: all four units installed" \
  '[[ -f $UNITS/wiki-sync.service && -f $UNITS/wiki-sync-watchdog.service && -f $UNITS/wiki-sync-watchdog.timer && -f $UNITS/wiki-sync-watchdog.path ]]'
assert "linux: units point at the install dir and the plugin settings" \
  'grep -q "ExecStart=$INSTALL/run.sh" "$UNITS/wiki-sync.service" && grep -q "PathChanged=$H/vault/.obsidian/plugins/obsidian-livesync/data.json" "$UNITS/wiki-sync-watchdog.path" && ! grep -q @ "$UNITS"/*'
assert "linux: daemon-reload, enable and restart ran" \
  'grep -q "systemctl --user daemon-reload" "$H/calls.log" && grep -q "systemctl --user enable wiki-sync.service wiki-sync-watchdog.timer wiki-sync-watchdog.path" "$H/calls.log" && grep -q "systemctl --user restart wiki-sync.service" "$H/calls.log"'
assert "linux: linger enabled" 'grep -q "loginctl enable-linger" "$H/calls.log"'
assert "linux: no launchctl calls" '! grep -q launchctl "$H/calls.log"'
assert "linux: first start took a snapshot of the wiki" 'ls "$INSTALL"/snapshots/first-start-*.tar.gz >/dev/null 2>&1 && tar -tzf "$INSTALL"/snapshots/first-start-*.tar.gz | grep -q "wiki/projects/a.md"'
assert "linux: source staged without tests, env records the vault and wiki dir" \
  '[[ -f $INSTALL/src/main.ts && ! -e $INSTALL/src/sync.test.ts && -x $INSTALL/run.sh ]] && grep -q "WIKI_SYNC_DIR=$H/vault/wiki" "$INSTALL/env"'
assert "linux: dependencies cached with a frozen lockfile" 'grep -q "deno install --frozen --entrypoint main.ts" "$H/calls.log"'
assert "linux: stamp written" '[[ -s $INSTALL/stamp ]]'

touch "$INSTALL/state/first-start-done"
: >"$H/calls.log"
module "$H" wiki_sync_install >"$TMP/linux2.out" 2>&1 || true
assert "linux: unchanged stamp makes reinstall a no-op" '! grep -q systemctl "$H/calls.log" && grep -q "already installed" "$TMP/linux2.out"'
assert "linux: no second snapshot once the first start is done" '[[ $(ls "$INSTALL"/snapshots | wc -l) -eq 1 ]]'

cp -R "$REPO_ROOT/configs/wiki-sync" "$TMP/src-copy"
echo "// changed" >>"$TMP/src-copy/src/log.ts"
: >"$H/calls.log"
WIKI_SYNC_SRC="$TMP/src-copy" module "$H" wiki_sync_install >/dev/null 2>&1 || true
assert "linux: a changed source restarts the service" 'grep -q "systemctl --user restart wiki-sync.service" "$H/calls.log"'

H="$TMP/running"
new_home "$H"
touch "$H/active"
module "$H" wiki_sync_install >/dev/null 2>&1 || true
assert "first start: a running service is stopped before the snapshot" \
  'grep -n "stop wiki-sync.service" "$H/calls.log" | head -1 | grep -q stop && [[ $(grep -n "stop wiki-sync.service" "$H/calls.log" | cut -d: -f1 | head -1) -lt $(grep -n "restart wiki-sync.service" "$H/calls.log" | cut -d: -f1 | head -1) ]]'

echo ""
echo "=== macOS install ==="

H="$TMP/mac"
new_home "$H"
FAKE_OS=Darwin module "$H" wiki_sync_install >"$TMP/mac.out" 2>&1 || true
AGENTS="$H/Library/LaunchAgents"
assert "mac: both launch agents installed with paths filled in" \
  '[[ -f $AGENTS/com.harness.wiki-sync.plist && -f $AGENTS/com.harness.wiki-sync-watchdog.plist ]] && ! grep -q @ "$AGENTS"/*.plist && grep -q "$H/Library/Logs/wiki-sync.log" "$AGENTS/com.harness.wiki-sync.plist"'
assert "mac: agents booted out then bootstrapped" \
  'grep -q "launchctl bootout gui/.*/com.harness.wiki-sync$" "$H/calls.log" && grep -q "launchctl bootstrap gui/[0-9]* $AGENTS/com.harness.wiki-sync.plist" "$H/calls.log" && grep -q "launchctl bootstrap gui/[0-9]* $AGENTS/com.harness.wiki-sync-watchdog.plist" "$H/calls.log"'
assert "mac: no systemctl calls" '! grep -q systemctl "$H/calls.log"'

echo ""
echo "=== Deno download ==="

H="$TMP/dl"
new_home "$H"
rm -rf "$H/.local/share/harness/wiki-sync/deno"
rc=0
out=$(module "$H" wiki_sync_ensure_deno "$H/.local/share/harness/wiki-sync" 2>&1) || rc=$?
assert "download: a zip whose sha256 differs from the pin is refused" \
  '[[ $rc -ne 0 && ! -e $H/.local/share/harness/wiki-sync/deno/deno ]] && grep -q "sha256 mismatch" <<<"$out" && grep -q "deno-x86_64-unknown-linux-gnu.zip" "$H/calls.log"'

echo ""
echo "=== run.sh, watchdog.sh, reset.sh ==="

H="$TMP/scripts"
new_home "$H"
INSTALL="$H/.local/share/harness/wiki-sync"
module "$H" wiki_sync_install >/dev/null 2>&1 || true
HOME="$H" PATH="$H/bin:$PATH" "$INSTALL/run.sh" --release-deletions >/dev/null
assert "run.sh --release-deletions only writes the marker" '[[ -e $INSTALL/state/release-deletions ]]'

cat >"$INSTALL/run.sh" <<EOF
#!/bin/sh
[ "\$1" = --check-fingerprint ] && exit \$(cat "$H/fp-rc" 2>/dev/null || echo 0)
exit 0
EOF
health() {
  local age_ms="$1" feed_ms="$2" paused="$3" remote="$4" handler="${5:-0}" caught="${6:-true}" now
  now=$(($(date +%s) * 1000))
  printf '{"ts":%d,"feedTs":%d,"paused":%s,"locked":false,"remote":"%s","oldestHandlerMs":%d,"caughtUp":%s}\n' \
    $((now - age_ms)) $((now - feed_ms)) "$paused" "$remote" "$handler" "$caught" >"$INSTALL/state/health.json"
}
dog() {
  : >"$H/calls.log"
  HOME="$H" PATH="$H/bin:$PATH" "$INSTALL/watchdog.sh"
}
touch "$H/active"
health 5000 5000 false ok
out=$(dog)
assert "watchdog: healthy daemon is left alone" '! grep -q try-restart "$H/calls.log"'
assert "watchdog: marks the first start done once caught up" '[[ -e $INSTALL/state/first-start-done ]]'
health 120000 5000 false ok
out=$(dog)
assert "watchdog: stale health restarts" 'grep -q "try-restart wiki-sync.service" "$H/calls.log"'
health 5000 200000 false ok
out=$(dog)
assert "watchdog: a silent feed restarts" 'grep -q "try-restart" "$H/calls.log"'
health 5000 200000 true ok
out=$(dog)
assert "watchdog: a silent feed while paused does not" '! grep -q "try-restart" "$H/calls.log"'
health 5000 200000 false unreachable
out=$(dog)
assert "watchdog: a silent feed while unreachable does not" '! grep -q "try-restart" "$H/calls.log"'
health 5000 5000 false ok 400000
out=$(dog)
assert "watchdog: a hung handler restarts" 'grep -q "try-restart" "$H/calls.log"'
health 5000 5000 false auth
out=$(dog)
assert "watchdog: a rejected login is flagged, not restarted" '! grep -q "try-restart" "$H/calls.log" && grep -q "rejected the login" <<<"$out"'
health 5000 5000 false ok
echo 1 >"$H/fp-rc"
out=$(dog)
assert "watchdog: rotated settings restart" 'grep -q "try-restart" "$H/calls.log" && grep -q "changed" <<<"$out"'
rm -f "$H/fp-rc" "$H/active"
health 120000 5000 false ok
out=$(dog)
assert "watchdog: a stopped service stays stopped" '! grep -q "try-restart" "$H/calls.log"'

mkdir -p "$INSTALL/state/base" "$INSTALL/recovered/wiki"
echo x >"$INSTALL/state/base/x.json"
echo r >"$INSTALL/recovered/wiki/r.md"
echo '{}' >"$INSTALL/state/checkpoint.json"
echo '{}' >"$INSTALL/state/identity.json"
touch "$H/active"
: >"$H/calls.log"
HOME="$H" PATH="$H/bin:$PATH" "$INSTALL/reset.sh" >/dev/null
assert "reset: snapshots the wiki first" 'ls "$INSTALL"/snapshots/reset-*.tar.gz >/dev/null 2>&1'
assert "reset: clears bases, checkpoint, identity and the first-start marker" \
  '[[ ! -e $INSTALL/state/base && ! -e $INSTALL/state/checkpoint.json && ! -e $INSTALL/state/identity.json && ! -e $INSTALL/state/first-start-done ]]'
assert "reset: leaves recovered/ alone" '[[ -f $INSTALL/recovered/wiki/r.md ]]'
assert "reset: stops then starts the service" 'grep -q "systemctl --user stop wiki-sync.service" "$H/calls.log" && grep -q "systemctl --user start wiki-sync.service" "$H/calls.log"'

echo ""
echo "=== daemon tests ==="
DENO_BIN="$REAL_HOME/.local/share/harness/wiki-sync/deno/deno"
if [[ -x "$DENO_BIN" ]]; then
  if (cd "$REPO_ROOT/configs/wiki-sync/src" && DENO_DIR="$TMP/denodir" "$DENO_BIN" task test >"$TMP/deno.log" 2>&1); then
    assert "deno task test passes" 'true'
  else
    tail -20 "$TMP/deno.log"
    assert "deno task test passes" 'false'
  fi
else
  echo "SKIP: no pinned Deno at $DENO_BIN; run deno task test in the denoland/deno:$PINNED container"
fi

echo ""
echo "Wiki-sync: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
