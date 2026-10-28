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
for slug in Anyesh/godview razajamil/herdr-plugin-workspace-manager; do
  assert "$slug builds with cargo and links with cc" \
    '[[ $(awk -F"\t" -v s="$slug" "\$1 == s { print \$3 }" <<<"$rows") == cargo,cc ]]'
done

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

plugin_json owner repo "$SHA_A" >"$PLUGIN_JSON"
declared() {
  printf '[package]\nname = "x"\n%b\n' "$1" >"$TMP/checkout/Cargo.toml"
  printf 'module x\n\n%s\n' "$2" >"$TMP/checkout/go.mod"
  rc=0
  out=$(herdr_install_plugin "$HERDR" owner/repo "${4:-$SHA_A}" "$3" 2>&1) || rc=$?
}
declared "rust-version = \"$HERDR_RUST_VERSION\"" "go $HERDR_GO_VERSION" cargo,go
assert "declared versions equal to the pins: no error" '[[ $rc -eq 0 ]] && ! grep -qE "ERROR|declares no" <<<"$out"'
declared "rust-version = '9.0'" 'go 1.26.0' cargo
assert "single-quoted rust-version is read" 'grep -q "needs rust 9.0" <<<"$out"'
declared 'rust-version = "9.0"\n\n[workspace.package]\nrust-version = "1.80"' 'go 1.26.0' cargo
assert "the package rust-version wins over the workspace one" 'grep -q "needs rust 9.0" <<<"$out"'
declared 'rust-version.workspace = true\n\n[workspace.package]\nrust-version = "9.0"' 'go 1.26.0' cargo
assert "rust-version inherited from the workspace is read" 'grep -q "needs rust 9.0" <<<"$out"'
declared 'edition = "2024"\n\n[dependencies.foo]\nrust-version = "9.0"' 'go 1.26.0' cargo
assert "a rust-version outside the package tables is ignored" '! grep -q "needs rust" <<<"$out"'
mkdir -p "$TMP/stubgo"
printf '#!/bin/sh\n' >"$TMP/stubgo/go"
chmod +x "$TMP/stubgo/go"
PATH="$TMP/stubgo:$PATH" declared 'rust-version = "1.82"' 'go 9.1' go "$SHA_B"
assert "a fresh install also checks the declared version" '[[ $rc -ne 0 ]] && grep -q "needs go 9.1" <<<"$out"'
declared 'rust-version = "1.82"' 'go 1.24rc1 // x' go
assert "a go prerelease line parses to its version" '[[ $rc -eq 0 ]] && ! grep -q "declares no" <<<"$out"'
command rm -f "$TMP/checkout/Cargo.toml"
rc=0
out=$(herdr_install_plugin "$HERDR" owner/repo "$SHA_A" cargo 2>&1) || rc=$?
assert "a missing Cargo.toml is named, not read as no version" '[[ $rc -eq 0 ]] && grep -q "no Cargo.toml" <<<"$out"'
declared 'rust-version = "1.82"' 'go 1.26.0' cargo,cc,go
assert "declared versions within the pins: no error" '[[ $rc -eq 0 ]] && ! grep -q ERROR <<<"$out"'
declared 'rust-version = "9.0"' 'go 1.26.0' cargo,cc
assert "declared rust above the pin fails the step" '[[ $rc -ne 0 ]]'
assert "declared rust above the pin names the pin" 'grep -q "needs rust 9.0 but HERDR_RUST_VERSION is $HERDR_RUST_VERSION" <<<"$out"'
declared 'rust-version = "1.82"' 'go 9.1' go
assert "declared go above the pin fails the step" '[[ $rc -ne 0 ]]'
assert "declared go above the pin names the pin" 'grep -q "needs go 9.1 but HERDR_GO_VERSION is $HERDR_GO_VERSION" <<<"$out"'
declared 'edition = "2024"' '' cargo,cc
assert "no declared rust version: warns without failing" '[[ $rc -eq 0 ]] && grep -q "declares no rust version" <<<"$out"'
declared 'rust-version = "9.0"' 'go 9.1' tar
assert "a plugin that builds neither is not checked" '[[ $rc -eq 0 ]] && ! grep -qE "ERROR|declares no" <<<"$out"'
rm -f "$TMP/checkout/Cargo.toml" "$TMP/checkout/go.mod"

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

for v in go1.20.4 go1.26.0 go1.27.1 "go$HERDR_GO_VERSION" go1.99.0; do
  printf '#!/bin/sh\n[ "$1 $2" = "env GOVERSION" ] && echo %s\n' "$v" >"$FAKE_BIN/go"
  chmod +x "$FAKE_BIN/go"
  PATH="$FAKE_BIN:$ORIG_PATH" herdr_system_go_ok && ok=yes || ok=no
  case "$v" in
    go1.20.4 | go1.26.0 | go1.27.1) assert "system $v is older than the pin" '[[ $ok == no ]]' ;;
    *) assert "system $v is at or above the pin" '[[ $ok == yes ]]' ;;
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
for v in 1.85.0 1.88.0 1.96.0 "$HERDR_RUST_VERSION" 1.99.0-nightly; do
  printf '#!/bin/sh\n[ "$1" = --version ] && echo "rustc %s (0000000 2026-01-01)"\n' "$v" >"$FAKE_BIN/rustc"
  chmod +x "$FAKE_BIN/rustc"
  PATH="$FAKE_BIN:$NO_RUST_PATH" herdr_system_rust_ok && ok=yes || ok=no
  case "$v" in
    1.85.0 | 1.88.0 | 1.96.0) assert "system rustc $v is older than the pin" '[[ $ok == no ]]' ;;
    *) assert "system rustc $v is at or above the pin" '[[ $ok == yes ]]' ;;
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

TARGET=$(herdr_rust_target)
FIXTURES="$TMP/rust-dist"
mkdir -p "$FIXTURES/src"
for c in rustc cargo rust-std; do
  dir="$FIXTURES/src/$c-$HERDR_RUST_VERSION-$TARGET"
  mkdir -p "$dir/payload"
  cat >"$dir/install.sh" <<EOF
#!/usr/bin/env bash
prefix=""
[[ -n "\${FAIL_INSTALL:-}" ]] && exit 1
for a in "\$@"; do [[ "\$a" == --prefix=* ]] && prefix="\${a#--prefix=}"; done
mkdir -p "\$prefix/bin" "\$prefix/lib/rustlib"
cp "\$(dirname "\$0")"/payload/* "\$prefix/bin/" 2>/dev/null
echo "\$*" >"\$prefix/lib/rustlib/$c-args"
EOF
done
printf '#!/bin/sh\necho "rustc %s (fixture 2026-01-01)"\n' "$HERDR_RUST_VERSION" \
  >"$FIXTURES/src/rustc-$HERDR_RUST_VERSION-$TARGET/payload/rustc"
printf '#!/bin/sh\necho "cargo %s"\n' "$HERDR_RUST_VERSION" \
  >"$FIXTURES/src/cargo-$HERDR_RUST_VERSION-$TARGET/payload/cargo"
chmod +x "$FIXTURES"/src/*/payload/* "$FIXTURES"/src/*/install.sh
for c in rustc cargo rust-std; do
  tar -cJf "$FIXTURES/$c-$HERDR_RUST_VERSION-$TARGET.tar.xz" -C "$FIXTURES/src" "$c-$HERDR_RUST_VERSION-$TARGET"
done

cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
echo "curl $url" >>"$CALLS"
cp "$FIXTURES/${url##*/}" "$out"
EOF
chmod +x "$FAKE_BIN/curl"
export FIXTURES
BAD_COMPONENT=""
herdr_rust_sha256() {
  [[ "$1" == "$BAD_COMPONENT" ]] && { echo "$BAD_SHA"; return; }
  herdr_sha256 "$FIXTURES/$1-$HERDR_RUST_VERSION-$2.tar.xz"
}
RUST_ROOT=$(herdr_rust_root)
no_stage() { ! compgen -G "$(dirname "$RUST_ROOT")/.rust.*" >/dev/null; }

mkdir -p "$RUST_ROOT"
touch "$RUST_ROOT/stale"
: >"$CALLS"
rc=0
out=$(PATH="$FAKE_BIN:$NO_RUST_PATH" herdr_ensure_rust 2>&1) || rc=$?
assert "rust install succeeds" '[[ $rc -eq 0 ]] && grep -q "installed: rust $HERDR_RUST_VERSION" <<<"$out"'
assert "rust install fetches each component for the target" \
  '[[ $(grep -c "^curl https://static.rust-lang.org/dist/.*-$HERDR_RUST_VERSION-$TARGET.tar.xz$" "$CALLS") -eq 3 ]]'
assert "rust install puts rustc and cargo in the root" '[[ -x "$RUST_ROOT/bin/rustc" && -x "$RUST_ROOT/bin/cargo" ]]'
assert "rust install includes rust-std" '[[ -e "$RUST_ROOT/lib/rustlib/rust-std-args" ]]'
assert "rust install runs each installer without ldconfig" \
  'grep -q -- "--disable-ldconfig" "$RUST_ROOT/lib/rustlib/rustc-args"'
assert "rust install replaces an older root" '[[ ! -e "$RUST_ROOT/stale" ]]'
assert "rust install leaves no stage" 'no_stage'

: >"$CALLS"
out=$(PATH="$FAKE_BIN:$NO_RUST_PATH" herdr_ensure_rust 2>&1)
assert "provisioned rust: reported as already installed" 'grep -q "skip: rust $HERDR_RUST_VERSION (already installed)" <<<"$out"'
assert "provisioned rust: no fetch" '! grep -q "^curl" "$CALLS"'

rm -rf "$RUST_ROOT"
BAD_COMPONENT=cargo
rc=0
out=$(PATH="$FAKE_BIN:$NO_RUST_PATH" herdr_ensure_rust 2>&1) || rc=$?
BAD_COMPONENT=""
assert "rust digest mismatch fails the step" '[[ $rc -ne 0 ]]'
assert "rust digest mismatch leaves no root" '[[ ! -e "$RUST_ROOT" ]]'
assert "rust digest mismatch leaves no stage" 'no_stage'

mkdir -p "$RUST_ROOT"
touch "$RUST_ROOT/kept"
rc=0
out=$(FAIL_INSTALL=1 PATH="$FAKE_BIN:$NO_RUST_PATH" herdr_ensure_rust 2>&1) || rc=$?
assert "failing component installer fails the step" '[[ $rc -ne 0 ]]'
assert "failing component installer keeps the old root" '[[ -e "$RUST_ROOT/kept" ]]'
assert "failing component installer leaves no stage" 'no_stage'
rm -rf "$RUST_ROOT"

SYS_RUST="$TMP/sysrust"
mkdir -p "$SYS_RUST"
printf '#!/bin/sh\necho "rustc 1.99.0 (0000000 2026-01-01)"\n' >"$SYS_RUST/rustc"
printf '#!/bin/sh\n' >"$SYS_RUST/cargo"
chmod +x "$SYS_RUST"/*
: >"$CALLS"
out=$(PATH="$FAKE_BIN:$SYS_RUST:$NO_RUST_PATH" herdr_ensure_rust 2>&1)
assert "good system rust: skipped" 'grep -q "skip: rust" <<<"$out"'
assert "good system rust: no fetch and no root" '! grep -q "^curl" "$CALLS" && [[ ! -e "$RUST_ROOT" ]]'

: >"$CALLS"
DRY_RUN=true
out=$(PATH="$FAKE_BIN:$NO_RUST_PATH" herdr_ensure_rust 2>&1)
DRY_RUN=false
assert "rust dry run: lists the install" 'grep -qF "[dry-run] would install rust $HERDR_RUST_VERSION ($TARGET)" <<<"$out"'
assert "rust dry run: no fetch and no root" '! grep -q "^curl" "$CALLS" && [[ ! -e "$RUST_ROOT" ]]'

PATH="$FAKE_BIN:$NO_RUST_PATH" herdr_ensure_rust >/dev/null 2>&1
found=$(PATH="$NO_RUST_PATH" herdr_with_toolchain command -v cargo) || found=""
assert "no system cargo: the provisioned cargo resolves" '[[ "$found" == "$RUST_ROOT/bin/cargo" ]]'
found=$(PATH="$SYS_RUST:$NO_RUST_PATH" herdr_with_toolchain command -v cargo) || found=""
assert "good system rust: the system cargo resolves" '[[ "$found" == "$SYS_RUST/cargo" ]]'
OLD_RUST="$TMP/oldrust"
mkdir -p "$OLD_RUST"
printf '#!/bin/sh\necho "rustc 1.85.0 (0000000 2026-01-01)"\n' >"$OLD_RUST/rustc"
printf '#!/bin/sh\n' >"$OLD_RUST/cargo"
chmod +x "$OLD_RUST"/*
found=$(PATH="$OLD_RUST:$NO_RUST_PATH" herdr_with_toolchain command -v cargo) || found=""
assert "too old system rust: the provisioned cargo resolves" '[[ "$found" == "$RUST_ROOT/bin/cargo" ]]'
mkdir -p "$TMP/emptybin"
missing=$(PATH="$TMP/emptybin" herdr_missing_needs cargo,cc)
assert "provisioned cargo without cc: names only cc" '[[ "$missing" == cc ]]'

CHECK_BIN="$TMP/checkbin"
mkdir -p "$CHECK_BIN"
for tool in curl git jq tar sha256sum btop uname sort head; do
  real=$(PATH="$NO_RUST_PATH" command -v "$tool") && ln -sf "$real" "$CHECK_BIN/$tool"
done
out=$(PATH="$CHECK_BIN" herdr_check 2>&1) || true
assert "check with provisioned rust does not ask for xz" '! grep -q "xz not found" <<<"$out"'
rm -rf "$RUST_ROOT"
out=$(PATH="$CHECK_BIN" herdr_check 2>&1) || true
assert "check warns that Rust plugin builds need cc" 'grep -q "cc not found" <<<"$out"'
if [[ "$(uname -s)" == Linux ]]; then
  assert "check warns that unpacking Rust needs xz" 'grep -q "xz not found" <<<"$out"'
fi
out=$(PATH="$CHECK_BIN:$SYS_RUST" herdr_check 2>&1) || true
assert "check with a good system rust does not ask for xz" '! grep -q "xz not found" <<<"$out"'

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
out=$(PATH="$NO_RUST_PATH" herdr_install 2>&1) && rc=0 || rc=$?
after=$(find "$HOME" | sort)
DRY_RUN=false
assert "dry run succeeds" '[[ $rc -eq 0 ]]'
assert "dry run without system rust lists rust" 'grep -qF "[dry-run] would install rust $HERDR_RUST_VERSION" <<<"$out"'
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
