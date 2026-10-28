#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/template.sh"
source "$REPO_ROOT/lib/deploy.sh"
source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/backup.sh"
source "$REPO_ROOT/modules/herdr.sh"

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
ORIG_PATH="$PATH"

export HOME="$TMP/home"
export HARNESS_MANIFEST="$TMP/manifest.json"
FORCE=false
NO_BACKUP=true
DRY_RUN=false

FAKE_BIN="$TMP/fakebin"
mkdir -p "$HOME/.local/bin" "$FAKE_BIN"
CALLS="$TMP/calls.log"
PLUGIN_JSON="$TMP/plugins.json"
export CALLS PLUGIN_JSON

cat >"$HOME/.local/bin/herdr" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
case "$1" in
  --version) echo "herdr 0.9.3" ;;
  plugin)
    [[ "$2" == "list" ]] && cat "$PLUGIN_JSON"
    exit 0
    ;;
  config)
    grep -q bogus "$HERDR_CONFIG_PATH" && { echo "config: issues found"; exit 1; }
    echo "config: ok"
    ;;
esac
EOF
chmod +x "$HOME/.local/bin/herdr"
HERDR="$HOME/.local/bin/herdr"

plugin_json() {
  local owner="$1" repo="$2" commit="$3"
  printf '{"result":{"plugins":[{"plugin_id":"x","source":{"kind":"github","owner":"%s","repo":"%s","resolved_commit":"%s","managed_path":"%s"}}]}}\n' \
    "$owner" "$repo" "$commit" "$TMP/checkout"
}

echo "=== plugins.tsv ==="

rows=$(herdr_read_plugins "$REPO_ROOT/configs/herdr/plugins.tsv")
assert "pins seven plugins" '[[ $(wc -l <<<"$rows") -eq 7 ]]'
assert "every ref is a full 40-char sha" \
  '[[ $(awk -F"\t" "\$2 ~ /^[0-9a-f]{40}\$/" <<<"$rows" | wc -l) -eq 7 ]]'
assert "every row has three fields" \
  '[[ $(awk -F"\t" "NF == 3" <<<"$rows" | wc -l) -eq 7 ]]'
assert "godview builds with cargo" \
  '[[ $(awk -F"\t" "\$1 == \"Anyesh/godview\" { print \$3 }" <<<"$rows") == cargo ]]'

printf '# comment\n\nowner/a\t%040d\t-\n  # indented comment\nowner/b\t%040d\tcargo\n' 0 1 >"$TMP/fixture.tsv"
rows=$(herdr_read_plugins "$TMP/fixture.tsv")
assert "comments and blank lines are dropped" '[[ $(wc -l <<<"$rows") -eq 2 ]]'
assert "fields stay tab separated" '[[ "$(cut -f1 <<<"$rows" | tail -1)" == "owner/b" ]]'

echo "=== plugin install ==="

SHA_A=$(printf 'a%.0s' {1..40})
SHA_B=$(printf 'b%.0s' {1..40})

plugin_json Owner Repo "$SHA_A" >"$PLUGIN_JSON"
: >"$CALLS"
out=$(herdr_install_plugin "$HERDR" owner/repo "$SHA_A" - 2>&1)
assert "installed at the pinned commit: skip" 'grep -q "skip: herdr plugin owner/repo" <<<"$out"'
assert "installed at the pinned commit: no install call" '! grep -q "plugin install" "$CALLS"'

: >"$CALLS"
out=$(herdr_install_plugin "$HERDR" owner/repo "$SHA_B" - 2>&1)
assert "installed at another commit: install at the pin" \
  'grep -qx "plugin install owner/repo --ref $SHA_B --yes" "$CALLS"'
assert "installed at another commit: reported as update" 'grep -q "updated: herdr plugin owner/repo" <<<"$out"'

echo '{"result":{"plugins":[]}}' >"$PLUGIN_JSON"
: >"$CALLS"
out=$(herdr_install_plugin "$HERDR" owner/new "$SHA_A" - 2>&1)
assert "not installed: install at the pin" 'grep -qx "plugin install owner/new --ref $SHA_A --yes" "$CALLS"'

: >"$CALLS"
out=$(herdr_install_plugin "$HERDR" owner/new "$SHA_A" "git,no-such-tool-xyz" 2>&1) && rc=0 || rc=$?
assert "missing need: no install call" '! grep -q "plugin install" "$CALLS"'
assert "missing need: names the tool" 'grep -q "no-such-tool-xyz" <<<"$out"'
assert "missing need: does not fail the module" '[[ $rc -eq 0 ]]'

mkdir -p "$TMP/checkout/bin"
cat >"$TMP/checkout/bin/herdr-workspace-manager" <<'EOF'
mkdir -p target/release
touch target/release/herdr-workspace-manager
chmod +x target/release/herdr-workspace-manager
echo "wsm $*" >>"$CALLS"
EOF
plugin_json razajamil herdr-plugin-workspace-manager "$SHA_A" >"$PLUGIN_JSON"
: >"$CALLS"
out=$(herdr_install_plugin "$HERDR" razajamil/herdr-plugin-workspace-manager "$SHA_A" - 2>&1)
assert "wsm: pre-built in its managed checkout" 'grep -qx "wsm --help" "$CALLS"'
: >"$CALLS"
out=$(herdr_install_plugin "$HERDR" razajamil/herdr-plugin-workspace-manager "$SHA_A" - 2>&1)
assert "wsm: an existing build is not rebuilt" '! grep -q "^wsm" "$CALLS"'

rm -rf "$TMP/checkout/target"
: >"$CALLS"
rc=0
out=$(PATH="$(dirname "$(command -v sh)")" herdr_prebuild_wsm "$HERDR" 2>&1) || rc=$?
assert "wsm without cargo: no build attempt" '! grep -q "^wsm" "$CALLS"'
assert "wsm without cargo: warns and does not fail the module" '[[ $rc -eq 0 ]] && grep -q cargo <<<"$out"'

echo '{"result":{"plugins":[]}}' >"$PLUGIN_JSON"
: >"$CALLS"
out=$(NO_PLUGINS=true herdr_install_plugins 2>&1) || true
assert "--no-plugins: no install call" '! grep -q "plugin install" "$CALLS"'
assert "--no-plugins: reported as skip" 'grep -q "skip: herdr plugins (--no-plugins flag)" <<<"$out"'

echo "=== verified download ==="

cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == "-o" ]] && { out="$2"; shift; }
  shift
done
printf 'payload' >"$out"
EOF
chmod +x "$FAKE_BIN/curl"
export PATH="$FAKE_BIN:$ORIG_PATH"
GOOD_SHA=$(printf 'payload' | sha256sum | cut -d' ' -f1)
BAD_SHA=$(printf '0%.0s' {1..64})

rc=0
herdr_fetch_verified https://example.invalid/x "$BAD_SHA" "$TMP/bad" 2>/dev/null || rc=$?
assert "digest mismatch fails" '[[ $rc -ne 0 ]]'
assert "digest mismatch leaves no file" '[[ ! -e "$TMP/bad" ]]'

rc=0
herdr_fetch_verified https://example.invalid/x "$GOOD_SHA" "$TMP/good" 2>/dev/null || rc=$?
assert "matching digest succeeds" '[[ $rc -eq 0 && -s "$TMP/good" ]]'

rc=0
out=$(herdr_ensure_binary 2>&1) || rc=$?
assert "binary with a wrong digest is not installed" 'grep -q "herdr 0.9.3" <<<"$("$HERDR" --version)"'
assert "binary with a wrong digest fails the step" '[[ $rc -ne 0 ]]'
export PATH="$ORIG_PATH"

echo "=== go ==="

for v in go1.20.4 go1.25.9 go1.26.0 go1.27.2; do
  printf '#!/bin/sh\n[ "$1 $2" = "env GOVERSION" ] && echo %s\n' "$v" >"$FAKE_BIN/go"
  chmod +x "$FAKE_BIN/go"
  PATH="$FAKE_BIN:$ORIG_PATH" herdr_system_go_ok && ok=yes || ok=no
  case "$v" in
    go1.20.4 | go1.25.9) assert "system $v is too old for the plugin builds" '[[ $ok == no ]]' ;;
    *) assert "system $v is new enough" '[[ $ok == yes ]]' ;;
  esac
done
rm -f "$FAKE_BIN/go"

echo "=== rust ==="

NO_RUST_PATH=""
IFS=: read -ra path_dirs <<<"$ORIG_PATH"
for d in "${path_dirs[@]}"; do
  [[ -e "$d/cargo" || -e "$d/rustc" ]] || NO_RUST_PATH+="${NO_RUST_PATH:+:}$d"
done

printf '#!/bin/sh\n' >"$FAKE_BIN/cargo"
chmod +x "$FAKE_BIN/cargo"
for v in 1.85.0 1.88.0 1.96.1 1.97.0-nightly; do
  printf '#!/bin/sh\n[ "$1" = --version ] && echo "rustc %s (0000000 2026-01-01)"\n' "$v" >"$FAKE_BIN/rustc"
  chmod +x "$FAKE_BIN/rustc"
  PATH="$FAKE_BIN:$NO_RUST_PATH" herdr_system_rust_ok && ok=yes || ok=no
  case "$v" in
    1.85.0) assert "system rustc $v is too old for the plugin builds" '[[ $ok == no ]]' ;;
    *) assert "system rustc $v is new enough" '[[ $ok == yes ]]' ;;
  esac
done
rm -f "$FAKE_BIN/cargo"
PATH="$FAKE_BIN:$NO_RUST_PATH" herdr_system_rust_ok && ok=yes || ok=no
assert "system rustc without cargo is not enough" '[[ $ok == no ]]'
rm -f "$FAKE_BIN/rustc"

for pair in linux-x86_64:x86_64-unknown-linux-gnu linux-aarch64:aarch64-unknown-linux-gnu \
  macos-x86_64:x86_64-apple-darwin macos-aarch64:aarch64-apple-darwin; do
  target=$(herdr_platform() { echo "${pair%%:*}"; } && herdr_rust_target) || target=""
  assert "${pair%%:*} maps to ${pair#*:}" '[[ "$target" == "${pair#*:}" ]]'
  for c in rustc cargo rust-std; do
    assert "$c has a pinned digest for ${pair#*:}" '[[ "$(herdr_rust_sha256 "$c" "${pair#*:}")" =~ ^[0-9a-f]{64}$ ]]'
  done
done
assert "an unknown component has no digest" '! herdr_rust_sha256 rust-docs x86_64-unknown-linux-gnu'

echo "=== config ==="

mkdir -p "$TMP/repo/configs/herdr"
printf 'key = "prefix+bogus"\n' >"$TMP/repo/configs/herdr/config.toml"
rc=0
out=$(REPO_ROOT="$TMP/repo" herdr_deploy_config 2>&1) || rc=$?
assert "invalid config fails the step" '[[ $rc -ne 0 ]]'
assert "invalid config is not deployed" '[[ ! -e "$HOME/.config/herdr/config.toml" ]]'
assert "invalid config names the check output" 'grep -q "issues found" <<<"$out"'

echo "=== dry run ==="

echo '{"result":{"plugins":[]}}' >"$PLUGIN_JSON"
: >"$CALLS"
DRY_RUN=true
before=$(find "$HOME" | sort)
out=$(herdr_install 2>&1) && rc=0 || rc=$?
after=$(find "$HOME" | sort)
DRY_RUN=false
assert "dry run succeeds" '[[ $rc -eq 0 ]]'
assert "dry run writes nothing under HOME" '[[ "$before" == "$after" && ! -e "$HOME/.config" ]]'
assert "dry run calls no installer" '! grep -q "plugin install" "$CALLS"'
assert "dry run lists the binary" 'grep -q "\[dry-run\] would install herdr 0.9.5" <<<"$out"'
assert "dry run lists the config" 'grep -q "\[dry-run\] would deploy: herdr config.toml" <<<"$out"'
while IFS=$'\t' read -r slug _ _; do
  assert "dry run lists $slug" 'grep -q "\[dry-run\] would install: herdr plugin $slug" <<<"$out"'
done < <(herdr_read_plugins "$REPO_ROOT/configs/herdr/plugins.tsv")

echo ""
echo "herdr module: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
