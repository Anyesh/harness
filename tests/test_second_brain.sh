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

# The real install's binaries must never answer for the fakes below.
TEST_PATH=$(tr ':' '\n' <<<"$PATH" | grep -vxF -e "$HOME/.cargo/bin" -e "$HOME/.local/bin" | paste -sd: -)

# Builds a fake HOME whose service-manager, cargo and claude stubs log their
# argv to calls.log, with a password database that names it the account home.
# cargo lists the crates from $home/cargo-list; $home/cargo-bump makes an
# install raise that crate's listed version and $home/cargo-fail-<crate> makes
# that crate's install fail.
new_home() {
  local home="$1" tool
  mkdir -p "$home/bin"
  for tool in systemctl launchctl loginctl; do
    cat >"$home/bin/$tool" <<EOF
#!/bin/sh
echo "$tool \$*" >> "$home/calls.log"
case "\$*" in
  *is-active*|print*) exit 1 ;;
  *) exit 0 ;;
esac
EOF
    chmod +x "$home/bin/$tool"
  done
  cat >"$home/bin/cargo" <<EOF
#!/bin/sh
echo "cargo \$*" >> "$home/calls.log"
[ "\$1" = install ] || exit 0
if [ "\$2" = --list ]; then cat "$home/cargo-list"; exit 0; fi
for crate; do :; done
if [ -e "$home/cargo-fail-\$crate" ]; then echo "error: could not compile \$crate" >&2; exit 101; fi
[ -e "$home/cargo-bump" ] && sed -i.bak "s/^\$crate v[0-9.]*:/\$crate v9.9.9:/" "$home/cargo-list"
exit 0
EOF
  cat >"$home/bin/claude" <<EOF
#!/bin/sh
echo "claude \$*" >> "$home/calls.log"
exit 0
EOF
  for tool in sb second-brain-mcp second-brain-api; do printf '#!/bin/sh\nexit 0\n' >"$home/bin/$tool"; done
  printf '#!/bin/sh\necho "NFSHomeDirectory: %s"\n' "$home" >"$home/bin/dscl"
  printf '#!/bin/sh\necho "me:*:501:20:Me:%s:/bin/sh"\n' "$home" >"$home/bin/getent"
  cat >"$home/bin/uname" <<EOF
#!/bin/sh
case "\$1" in -m) echo arm64 ;; *) echo "\${FAKE_OS:-Linux}" ;; esac
EOF
  chmod +x "$home/bin/"*
  printf 'second-brain-api v0.11.0:\n    second-brain-api\nsecond-brain-cli v0.11.0:\n    sb\nsecond-brain-mcp v0.11.0:\n    second-brain-mcp\n' >"$home/cargo-list"
  : >"$home/calls.log"
}

module() {
  local home="$1"
  shift
  HOME="$home" PATH="$home/bin:$TEST_PATH" REPO_ROOT="$REPO_ROOT" \
    DRY_RUN="${DRY_RUN:-false}" FORCE="${FORCE:-false}" bash -c '
      set -euo pipefail
      source "$REPO_ROOT/lib/common.sh"
      source "$REPO_ROOT/modules/second-brain.sh"
      "$@"' _ "$@"
}

calls() { grep -c "$2" "$1/calls.log" || true; }

echo ""
echo "=== binaries ==="

H="$TMP/bins"
new_home "$H"
out=$(module "$H" second_brain_binaries 2>&1)
assert "every run installs each crate once, also when all binaries exist" \
  '[[ $(calls "$H" "^cargo install second-brain-cli$") -eq 1 && $(calls "$H" "^cargo install second-brain-mcp$") -eq 1 && $(calls "$H" "^cargo install second-brain-api$") -eq 1 ]]'
assert "no version pin and no --force by default" '! grep -qE "^cargo install.*(--version|@|--force)" "$H/calls.log"'
assert "nothing upgraded: logged as a skip, not an install" 'grep -q "already at the latest release" <<<"$out" && ! grep -q "latest release installed" <<<"$out"'

: >"$H/calls.log"
touch "$H/cargo-bump"
out=$(module "$H" second_brain_binaries 2>&1)
rm "$H/cargo-bump"
assert "a crate upgraded: logged as installed" 'grep -q "latest release installed" <<<"$out"'

: >"$H/calls.log"
out=$(FORCE=true module "$H" second_brain_binaries 2>&1)
assert "FORCE reinstalls each crate with --force" '[[ $(calls "$H" "^cargo install --force second-brain-") -eq 3 ]]'

: >"$H/calls.log"
out=$(DRY_RUN=true module "$H" second_brain_binaries 2>&1)
assert "dry-run installs nothing and says so" '! grep -q "^cargo install second-brain" "$H/calls.log" && grep -q "\[dry-run\]" <<<"$out"'

: >"$H/calls.log"
touch "$H/cargo-fail-second-brain-mcp"
rc=0
out=$(module "$H" second_brain_binaries 2>&1) || rc=$?
rm "$H/cargo-fail-second-brain-mcp"
assert "a failed crate fails the step, is named and gets the rerun line" \
  '[[ $rc -ne 0 ]] && grep -q "second-brain-mcp" <<<"$out" && grep -q "install.sh --only second-brain" <<<"$out" && [[ $(calls "$H" "^cargo install second-brain-api$") -eq 1 ]]'
assert "the failure prints no cargo command to copy" '! grep -q "cargo install" <<<"$out"'

echo ""
echo "=== service hint ==="

H="$TMP/hint"
new_home "$H"
out=$(module "$H" second_brain_install 2>&1)
assert "no service.json: hints sb setup" 'grep -q "sb setup" <<<"$out" && ! grep -q "sb restart" <<<"$out"'

mkdir -p "$H/.second-brain"
echo '{}' >"$H/.second-brain/service.json"
out=$(module "$H" second_brain_install 2>&1)
assert "service.json and nothing upgraded: no hint" '! grep -qE "sb (setup|restart)" <<<"$out"'

touch "$H/cargo-bump"
out=$(module "$H" second_brain_install 2>&1)
assert "service.json and a crate upgraded: hints sb restart" 'grep -q "sb restart" <<<"$out" && ! grep -q "sb setup" <<<"$out"'

echo ""
echo "=== no daemon of its own ==="

for os in Linux Darwin; do
  H="$TMP/nodaemon-$os"
  new_home "$H"
  out=$(FAKE_OS=$os module "$H" second_brain_install 2>&1)
  out+=$(FAKE_OS=$os module "$H" second_brain_mcp 2>&1)
  assert "$os: no service call or file for the api daemon" \
    '! grep -qE "second-brain\.service|com\.harness\.second-brain( |$|\.plist)" "$H/calls.log" && [[ ! -e $H/.config/systemd/user/second-brain.service && ! -e $H/Library/LaunchAgents/com.harness.second-brain.plist ]]'
  assert "$os: MCP registered with only SECOND_BRAIN_API" \
    'grep "^claude mcp add" "$H/calls.log" | grep -q "SECOND_BRAIN_API=http://127.0.0.1:7200" && [[ $(grep "^claude mcp add" "$H/calls.log" | grep -o -- " -e " | wc -l) -eq 1 ]]'
done

echo ""
echo "=== Linux sync timer ==="

H="$TMP/linux"
new_home "$H"
out=$(module "$H" second_brain_sync_timer 2>&1)
assert "linux: sync timer units written and enabled" \
  '[[ -f $H/.config/systemd/user/sb-sync.service && -f $H/.config/systemd/user/sb-sync.timer ]] && grep -q "systemctl --user enable --now sb-sync.timer" "$H/calls.log"'
assert "linux: linger enabled for the user timer" 'grep -q "loginctl enable-linger" "$H/calls.log"'
assert "linux: sb-sync.sh installed and peers file seeded" '[[ -x $H/.local/bin/sb-sync.sh && -f $H/.second-brain/sync-peers ]]'
assert "linux: no launchctl calls" '! grep -q launchctl "$H/calls.log"'

echo ""
echo "=== macOS sync agent ==="

H="$TMP/mac"
new_home "$H"
SYNC_PLIST="$H/Library/LaunchAgents/com.harness.sb-sync.plist"
out=$(FAKE_OS=Darwin module "$H" second_brain_sync_timer 2>&1)
assert "mac: sync agent bootstrapped" 'grep -q "launchctl bootstrap gui/[0-9]* $SYNC_PLIST" "$H/calls.log"'
assert "mac: no systemctl calls and no systemd units" '! grep -q systemctl "$H/calls.log" && [[ ! -e $H/.config/systemd ]]'
assert "mac: sync agent runs sb-sync.sh every 30 minutes and at load" \
  'grep -q "<string>$H/.local/bin/sb-sync.sh</string>" "$SYNC_PLIST" && grep -A1 "<key>StartInterval</key>" "$SYNC_PLIST" | grep -q "<integer>1800</integer>" && grep -A1 "<key>RunAtLoad</key>" "$SYNC_PLIST" | grep -q "<true/>"'
assert "mac: sync agent gets a Homebrew PATH, logs under Library/Logs and keeps no placeholder" \
  'grep -q "/opt/homebrew/bin" "$SYNC_PLIST" && grep -q "$H/Library/Logs/sb-sync.log" "$SYNC_PLIST" && ! grep -q @ "$SYNC_PLIST"'
if command -v plutil >/dev/null 2>&1; then
  assert "mac: sync plist passes plutil -lint" 'plutil -lint "$SYNC_PLIST" >/dev/null'
fi

echo ""
echo "Second-brain: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
