#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
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
TMP=$(cd -P "$TMP" && pwd -P)

# Args: home, account home the password database reports ("" makes the lookup
# fail). The service managers are stubs that log their argv.
new_home() {
  local home="$1" account="$2" tool
  mkdir -p "$home/bin" "$home/.cargo/bin" "$home/vault/wiki" "$home/vault/.obsidian/plugins/obsidian-livesync"
  echo '{}' >"$home/vault/.obsidian/plugins/obsidian-livesync/data.json"
  printf 'WIKI_VAULT=%s/vault\n' "$home" >"$home/.harness.env"
  printf '#!/bin/sh\nexit 0\n' >"$home/.cargo/bin/second-brain-api"
  chmod +x "$home/.cargo/bin/second-brain-api"
  for tool in systemctl launchctl loginctl; do
    printf '#!/bin/sh\necho "%s $*" >>"%s/calls.log"\ncase "$*" in *is-active* | print*) exit 3 ;; esac\n' "$tool" "$home" >"$home/bin/$tool"
    chmod +x "$home/bin/$tool"
  done
  if [[ -n "$account" ]]; then
    printf '#!/bin/sh\necho "NFSHomeDirectory: %s"\n' "$account" >"$home/bin/dscl"
    printf '#!/bin/sh\necho "me:*:501:20:Me:%s:/bin/sh"\n' "$account" >"$home/bin/getent"
  else
    printf '#!/bin/sh\nexit 2\n' >"$home/bin/dscl"
    printf '#!/bin/sh\nexit 2\n' >"$home/bin/getent"
  fi
  printf '#!/bin/sh\nexit 1\n' >"$home/bin/curl"
  cat >"$home/bin/uname" <<EOF
#!/bin/sh
case "\$1" in -m) echo x86_64 ;; *) echo "\${FAKE_OS:-Linux}" ;; esac
EOF
  chmod +x "$home/bin/dscl" "$home/bin/getent" "$home/bin/curl" "$home/bin/uname"
  : >"$home/calls.log"
}

module() {
  local home="$1"
  shift
  HOME="$home" HARNESS_ENV="$home/.harness.env" PATH="$home/bin:$PATH" XDG_CONFIG_HOME="$home/.config" \
    REPO_ROOT="$REPO_ROOT" DRY_RUN=false FORCE=false bash -c '
      set -euo pipefail
      source "$REPO_ROOT/lib/common.sh"
      source "$REPO_ROOT/lib/profile.sh"
      source "$REPO_ROOT/modules/second-brain.sh"
      source "$REPO_ROOT/modules/wiki-sync.sh"
      "$@"' _ "$@"
}

service_step() {
  module "$1" second_brain_sync_timer
  module "$1" wiki_sync_install
}

echo ""
echo "=== account home check ==="

H="$TMP/owner"
new_home "$H" "$H"
assert "linux: a unit in the account's systemd dir is owned" \
  'module "$H" service_manager_owns "$H/.config/systemd/user/x.service" >/dev/null 2>&1'
assert "mac: a plist in the account's LaunchAgents is owned" \
  'FAKE_OS=Darwin module "$H" service_manager_owns "$H/Library/LaunchAgents/x.plist" >/dev/null 2>&1'
assert "mac: a plist outside LaunchAgents is not owned" \
  '! FAKE_OS=Darwin module "$H" service_manager_owns "$H/elsewhere/x.plist" >/dev/null 2>&1'

ln -s "$H" "$TMP/owner-link"
assert "a HOME that is a symlink to the account home is owned" \
  'module "$TMP/owner-link" service_manager_owns "$TMP/owner-link/.config/systemd/user/x.service" >/dev/null 2>&1'

H="$TMP/nolookup"
new_home "$H" ""
assert "a failed account lookup refuses (fail closed)" \
  '! module "$H" service_manager_owns "$H/.config/systemd/user/x.service" >/dev/null 2>&1'

for os in Linux Darwin; do
  echo ""
  echo "=== $os: HOME is not the account home ==="
  H="$TMP/temp-$os"
  new_home "$H" "$TMP/real-account"
  rc=0
  out=$(FAKE_OS=$os service_step "$H" 2>&1) || rc=$?
  assert "$os: service step succeeds" '[[ $rc -eq 0 ]]'
  assert "$os: no service manager call" '[[ ! -s $H/calls.log ]]'
  assert "$os: says why it skipped" 'grep -q "HOME is not the account home; not loading" <<<"$out"'
  assert "$os: no unit written outside the account" '[[ ! -e $H/Library/LaunchAgents && ! -e $H/.config/systemd ]]'

  echo ""
  echo "=== $os: HOME is the account home ==="
  H="$TMP/account-$os"
  new_home "$H" "$H"
  out=$(FAKE_OS=$os module "$H" second_brain_sync_timer 2>&1)
  if [[ $os == Linux ]]; then
    assert "$os: sync timer loaded and linger enabled" \
      'grep -q "systemctl --user enable --now sb-sync.timer" "$H/calls.log" && grep -q "loginctl enable-linger" "$H/calls.log"'
  else
    assert "$os: sync agent bootstrapped" \
      'grep -q "launchctl bootstrap gui/[0-9]* $H/Library/LaunchAgents/com.harness.sb-sync.plist" "$H/calls.log"'
  fi
  assert "$os: no api daemon unit or agent" \
    '! grep -qE "second-brain\.service|com\.harness\.second-brain\.plist" "$H/calls.log" && [[ ! -e $H/.config/systemd/user/second-brain.service && ! -e $H/Library/LaunchAgents/com.harness.second-brain.plist ]]'
done

echo ""
echo "Service manager: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
