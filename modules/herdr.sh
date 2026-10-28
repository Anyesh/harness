#!/usr/bin/env bash

HERDR_VERSION="0.9.5"
HERDR_GO_VERSION="1.27.2"
HERDR_RUST_VERSION="1.96.1"
WSM_SLUG="razajamil/herdr-plugin-workspace-manager"

herdr_check() {
  local ok=0 tool
  for tool in curl git jq tar; do
    command -v "$tool" >/dev/null 2>&1 || { log_warn "$tool not found"; ok=1; }
  done
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    log_warn "sha256sum or shasum not found"
    ok=1
  fi
  command -v btop >/dev/null 2>&1 || log_warn "btop not found; the prefix+alt+t popup needs it"
  command -v cc >/dev/null 2>&1 || log_warn "cc not found; Rust plugin builds need it to link"
  if [[ "$(uname -s)" == Linux && ! -x "$(herdr_rust_root)/bin/cargo" ]] &&
    ! command -v xz >/dev/null 2>&1 && ! herdr_system_rust_ok; then
    log_warn "xz not found; tar needs it to unpack the Rust toolchain"
  fi
  return $ok
}

herdr_install() {
  local rc=0
  herdr_ensure_binary || return 1
  herdr_ensure_go || rc=1
  herdr_ensure_rust || rc=1
  herdr_deploy_plugin_configs || rc=1
  herdr_install_plugins || rc=1
  herdr_deploy_config || rc=1
  return $rc
}

herdr_platform() {
  local os arch
  case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=macos ;;
    *) return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) return 1 ;;
  esac
  printf '%s-%s\n' "$os" "$arch"
}

herdr_go_platform() {
  local platform
  platform=$(herdr_platform) || return 1
  platform="${platform/macos/darwin}"
  platform="${platform/x86_64/amd64}"
  printf '%s\n' "${platform/aarch64/arm64}"
}

# From the GitHub release API's assets[].digest; herdr publishes no checksum files.
herdr_asset_sha256() {
  case "$1" in
    linux-x86_64) echo 14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d ;;
    linux-aarch64) echo 17d7536f2da50859523680ef279dffcac8e4a235f4e46fe8da6c2ec44141897c ;;
    macos-x86_64) echo 5fb0a908ec7f6745e3e245738b06bfad56c46391c391ab3c0955fbead01f1369 ;;
    macos-aarch64) echo fb77c2232a05a8035421382c894392f4174e4e38a18e48af3dd0290157c3a7e2 ;;
    *) return 1 ;;
  esac
}

herdr_go_sha256() {
  case "$1" in
    linux-amd64) echo ecbadb99091a3f46e31f5f934b068b1864eafa7995211b39eaddf76996045fe5 ;;
    linux-arm64) echo 94f3e30b8e374bc285e7dadc11e0865726b9bc6e85b841ccceaabc0214c6b7c8 ;;
    darwin-amd64) echo 587b59182488b23aa6e5fc25110405a3e0e5b38ed2f5b2f46ed13c32aee356fe ;;
    darwin-arm64) echo 76812b213b1b2302c978d28fa52fa92d541704b9e7d9d5db8002c50e4018c4c5 ;;
    *) return 1 ;;
  esac
}

herdr_rust_target() {
  local platform
  platform=$(herdr_platform) || return 1
  case "$platform" in
    linux-*) printf '%s-unknown-linux-gnu\n' "${platform#linux-}" ;;
    macos-*) printf '%s-apple-darwin\n' "${platform#macos-}" ;;
  esac
}

# From the .sha256 files on static.rust-lang.org, matching channel-rust-1.96.1.toml.
herdr_rust_sha256() {
  case "$1 $2" in
    "rustc x86_64-unknown-linux-gnu") echo 3545a0efad2355ecb0a3b9ac02efee96e27f1f9d24b7ce2fc3f279b2efb0d923 ;;
    "cargo x86_64-unknown-linux-gnu") echo ecc53a3c49fab5ab8c9301b3bbc8fb1dff9be6c65287add3f57a0fe8fddfea9e ;;
    "rust-std x86_64-unknown-linux-gnu") echo 1bf4fde5048cca33e6ea00c7471281ed96d792f6923141e3db45072743a1afae ;;
    "rustc aarch64-unknown-linux-gnu") echo 4bc079af433c730af16aa90c96777985b86d40c4670670380160bd61626a577f ;;
    "cargo aarch64-unknown-linux-gnu") echo 02a4d7bf424ea28d574fe5b5d29e7ae99b0bc11a5920d8f28fa7408aa6a37992 ;;
    "rust-std aarch64-unknown-linux-gnu") echo 24bd362ff484421cae8be8c4d326fde143a086782e59e21fc7f353a5d04cd630 ;;
    "rustc x86_64-apple-darwin") echo 814e1ed2d19952cf9771aeff5e0d4e0b77eefa76a689809f2c1bf769187ab051 ;;
    "cargo x86_64-apple-darwin") echo 128041aa757a6bbc60664079ff294281cdbabd51cc4b7c1f7d40cd1b1ea955f5 ;;
    "rust-std x86_64-apple-darwin") echo a094fc4d30985f48aff70629d7a6c1f16d314a63f3cb141927095b6d506edd35 ;;
    "rustc aarch64-apple-darwin") echo 9b548f0665f85f3c7fd45165611e3dea79f048c69d163be193986310d204fc2c ;;
    "cargo aarch64-apple-darwin") echo 2f43d75e9ad3febae5022c6f295cf93b74131cfdb1293a83e291f878ea9585a0 ;;
    "rust-std aarch64-apple-darwin") echo 0d433a74c303febc915f8fa1091ef166445706461d0c96984ecb7303aa8208f5 ;;
    *) return 1 ;;
  esac
}

herdr_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

herdr_fetch_verified() {
  local url="$1" expected="$2" out="$3" actual
  if ! curl -fsSL --retry 3 -o "$out" "$url"; then
    rm -f "$out"
    log_warn "download failed: $url"
    return 1
  fi
  actual=$(herdr_sha256 "$out")
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$out"
    log_warn "sha256 mismatch for $url (expected $expected, got $actual)"
    return 1
  fi
}

herdr_bin() {
  if [[ -x "$HOME/.local/bin/herdr" ]]; then
    printf '%s\n' "$HOME/.local/bin/herdr"
  else
    command -v herdr 2>/dev/null
  fi
}

herdr_server_version() {
  "$1" status 2>/dev/null | awk '/^server:/ { s = 1; next } /^[^ ]/ { s = 0 } s && $1 == "version:" { print $2; exit }'
}

herdr_warn_stale_server() {
  local running
  running=$(herdr_server_version "$1")
  if [[ -n "$running" && "$running" != "$HERDR_VERSION" ]]; then
    log_warn "the running herdr server is $running; restart it to use $HERDR_VERSION (the installer never stops it)"
  fi
}

herdr_ensure_binary() {
  local dest="$HOME/.local/bin/herdr" platform tmp label="herdr $HERDR_VERSION"
  if [[ -x "$dest" && "$("$dest" --version 2>/dev/null)" == "herdr $HERDR_VERSION" ]]; then
    log_skip "$label" "already installed"
    [[ "$DRY_RUN" == "true" ]] || herdr_warn_stale_server "$dest"
    return 0
  fi
  if ! platform=$(herdr_platform); then
    log_error "herdr: unsupported platform $(uname -s) $(uname -m)"
    return 1
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would install herdr $HERDR_VERSION ($platform) to ~/.local/bin"
    return 0
  fi

  local existed=false
  [[ -e "$dest" ]] && existed=true
  mkdir -p "$HOME/.local/bin"
  tmp=$(mktemp "$HOME/.local/bin/.herdr.XXXXXX")
  if ! herdr_fetch_verified "https://github.com/herdrdev/herdr/releases/download/v$HERDR_VERSION/herdr-$platform" \
    "$(herdr_asset_sha256 "$platform")" "$tmp"; then
    rm -f "$tmp"
    log_error "herdr $HERDR_VERSION was not installed"
    return 1
  fi
  chmod 755 "$tmp"
  mv -f "$tmp" "$dest"
  if [[ "$existed" == "true" ]]; then
    log_update "updated: $label"
  else
    log_success "installed: $label"
  fi
  local on_path
  on_path=$(command -v herdr 2>/dev/null)
  [[ -z "$on_path" || "$on_path" == "$dest" ]] || log_warn "$on_path shadows $dest on PATH"
  herdr_warn_stale_server "$dest"
}

herdr_go_root() {
  printf '%s\n' "$HOME/.local/share/harness/go"
}

# usagebar's build falls back to an unchecksummed binary download when it
# cannot run go build, so Go must be present before the plugin installs.
herdr_system_go_ok() {
  local version
  version=$(go env GOVERSION 2>/dev/null) || return 1
  herdr_version_at_least "$HERDR_GO_VERSION" "${version#go}"
}

herdr_version_at_least() {
  local min="$1" version="${2%%[!0-9.]*}"
  [[ -n "$version" && "$(printf '%s\n%s\n' "$min" "$version" | sort -V | head -1)" == "$min" ]]
}

herdr_system_rust_ok() {
  local version
  command -v cargo >/dev/null 2>&1 || return 1
  version=$(rustc --version 2>/dev/null) || return 1
  version="${version#rustc }"
  herdr_version_at_least "$HERDR_RUST_VERSION" "${version%% *}"
}

herdr_ensure_go() {
  local root label="go $HERDR_GO_VERSION" platform
  root=$(herdr_go_root)
  if herdr_system_go_ok; then
    log_skip "go" "go $HERDR_GO_VERSION or newer already on PATH"
    return 0
  fi
  if [[ "$("$root/bin/go" env GOVERSION 2>/dev/null)" == "go$HERDR_GO_VERSION" ]]; then
    log_skip "$label" "already installed"
    return 0
  fi
  if ! platform=$(herdr_go_platform); then
    log_error "go: unsupported platform $(uname -s) $(uname -m)"
    return 1
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would install $label ($platform) to ${root/#$HOME/\~}"
    return 0
  fi

  local stage
  mkdir -p "$(dirname "$root")"
  stage=$(mktemp -d "$(dirname "$root")/.go.XXXXXX")
  if ! herdr_fetch_verified "https://go.dev/dl/go$HERDR_GO_VERSION.$platform.tar.gz" \
    "$(herdr_go_sha256 "$platform")" "$stage/go.tar.gz" || ! tar -xzf "$stage/go.tar.gz" -C "$stage"; then
    rm -rf "$stage"
    log_error "$label was not installed"
    return 1
  fi
  herdr_replace_root "$stage" "$stage/go" "$root" "$label"
}

herdr_replace_root() {
  local stage="$1" built="$2" root="$3" label="$4"
  if [[ -e "$root" ]] && ! mv "$root" "$stage/previous"; then
    rm -rf "$stage"
    log_error "$label was not installed: could not move the old ${root/#$HOME/\~} aside"
    return 1
  fi
  if ! mv "$built" "$root"; then
    [[ -e "$stage/previous" ]] && mv "$stage/previous" "$root"
    rm -rf "$stage"
    log_error "$label was not installed: could not move it into ${root/#$HOME/\~}"
    return 1
  fi
  rm -rf "$stage"
  log_success "installed: $label"
}

herdr_rust_root() {
  printf '%s\n' "$HOME/.local/share/harness/rust"
}

herdr_ensure_rust() {
  local root label="rust $HERDR_RUST_VERSION" target
  root=$(herdr_rust_root)
  if herdr_system_rust_ok; then
    log_skip "rust" "rust $HERDR_RUST_VERSION or newer already on PATH"
    return 0
  fi
  if [[ -x "$root/bin/cargo" && "$("$root/bin/rustc" --version 2>/dev/null)" == "rustc $HERDR_RUST_VERSION "* ]]; then
    log_skip "$label" "already installed"
    return 0
  fi
  if ! target=$(herdr_rust_target); then
    log_error "rust: unsupported platform $(uname -s) $(uname -m)"
    return 1
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would install $label ($target) to ${root/#$HOME/\~}"
    return 0
  fi

  local stage
  mkdir -p "$(dirname "$root")"
  stage=$(mktemp -d "$(dirname "$root")/.rust.XXXXXX")
  if ! herdr_install_rust_components "$stage" "$target"; then
    rm -rf "$stage"
    log_error "$label was not installed"
    return 1
  fi
  herdr_replace_root "$stage" "$stage/rust" "$root" "$label"
}

herdr_install_rust_components() {
  local stage="$1" target="$2" component name out
  for component in rustc cargo rust-std; do
    name="$component-$HERDR_RUST_VERSION-$target"
    herdr_fetch_verified "https://static.rust-lang.org/dist/$name.tar.xz" \
      "$(herdr_rust_sha256 "$component" "$target")" "$stage/$name.tar.xz" || return 1
    tar -xJf "$stage/$name.tar.xz" -C "$stage" || return 1
    rm -f "$stage/$name.tar.xz"
    if ! out=$(bash "$stage/$name/install.sh" --prefix="$stage/rust" --disable-ldconfig 2>&1); then
      log_warn "$name install.sh failed: $(tail -5 <<<"$out")"
      return 1
    fi
    rm -rf "$stage/$name"
  done
}

herdr_with_toolchain() {
  local root path="$PATH"
  root=$(herdr_rust_root)
  if [[ -x "$root/bin/cargo" ]] && ! herdr_system_rust_ok; then
    path="$root/bin:$path"
  fi
  root=$(herdr_go_root)
  if [[ -x "$root/bin/go" ]] && ! herdr_system_go_ok; then
    PATH="$root/bin:$path" GOPATH="${GOPATH:-$HOME/.local/share/harness/gopath}" "$@"
  else
    PATH="$path" "$@"
  fi
}

herdr_missing_needs() {
  local tool missing=()
  local -a tools
  IFS=, read -ra tools <<<"$1"
  for tool in "${tools[@]}"; do
    [[ -z "$tool" || "$tool" == "-" ]] && continue
    herdr_with_toolchain command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  printf '%s' "${missing[*]:-}"
}

herdr_read_plugins() {
  grep -v -E '^[[:space:]]*(#|$)' "$1"
}

herdr_plugin_source() {
  local bin="$1" slug="$2" field="$3"
  [[ -n "$bin" ]] || return 0
  "$bin" plugin list --json 2>/dev/null | jq -r --arg slug "$slug" --arg f "$field" '
    .result.plugins[]?
    | select(.source.kind == "github" and ((.source.owner + "/" + .source.repo) | ascii_downcase) == ($slug | ascii_downcase))
    | .source[$f] // empty' | head -1
}

herdr_post_install() {
  case "$2" in
    "$WSM_SLUG") herdr_prebuild_wsm "$1" ;;
  esac
}

# The wsm shim compiles with cargo on first use, which would otherwise happen
# inside herdr's startup hook.
herdr_prebuild_wsm() {
  local root label="workspace-manager build"
  root=$(herdr_plugin_source "$1" "$WSM_SLUG" managed_path)
  if [[ -z "$root" ]]; then
    log_warn "$label: no managed checkout found"
    return 1
  fi
  if [[ -x "$root/target/release/herdr-workspace-manager" ]]; then
    log_skip "$label" "already built"
    return 0
  fi
  local missing
  missing=$(herdr_missing_needs cargo,cc)
  if [[ -n "$missing" ]]; then
    log_warn "$label skipped: it needs $missing"
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would build: $label"
    return 0
  fi
  local out
  if out=$(cd "$root" && herdr_with_toolchain sh bin/herdr-workspace-manager --help </dev/null 2>&1); then
    log_success "built: $label"
  else
    log_error "$label failed: $(tail -5 <<<"$out")"
    return 1
  fi
}

herdr_install_plugin() {
  local bin="$1" slug="$2" ref="$3" needs="$4" label="herdr plugin $2" current missing
  current=$(herdr_plugin_source "$bin" "$slug" resolved_commit)
  if [[ "$current" == "$ref" ]]; then
    log_skip "$label" "installed at ${ref:0:7}"
    herdr_post_install "$bin" "$slug"
    return
  fi
  missing=$(herdr_missing_needs "$needs")
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would install: $label at ${ref:0:7}${missing:+ (missing now: $missing)}"
    return 0
  fi
  if [[ -n "$missing" ]]; then
    log_warn "$label skipped: its build needs $missing"
    return 0
  fi
  if [[ -z "$bin" ]]; then
    log_error "$label: herdr not found"
    return 1
  fi

  local out
  if ! out=$(herdr_with_toolchain "$bin" plugin install "$slug" --ref "$ref" --yes </dev/null 2>&1); then
    log_error "$label failed: $(tail -5 <<<"$out")"
    return 1
  fi
  if [[ -n "$current" ]]; then
    log_update "updated: $label ${current:0:7} -> ${ref:0:7}"
  else
    log_success "installed: $label at ${ref:0:7}"
  fi
  herdr_post_install "$bin" "$slug"
}

herdr_install_plugins() {
  local bin slug ref needs rc=0
  if [[ "${NO_PLUGINS:-false}" == "true" ]]; then
    log_skip "herdr plugins" "--no-plugins flag"
    return 0
  fi
  bin=$(herdr_bin)
  while IFS=$'\t' read -r slug ref needs <&3; do
    herdr_install_plugin "$bin" "$slug" "$ref" "$needs" || rc=1
  done 3< <(herdr_read_plugins "$REPO_ROOT/configs/herdr/plugins.tsv")
  return $rc
}

herdr_deploy_plugin_configs() {
  local src rel base="$REPO_ROOT/configs/herdr/plugins" rc=0
  while IFS= read -r src; do
    rel="${src#"$base/"}"
    deploy_file "$src" "$HOME/.config/herdr/plugins/config/$rel" "configs/herdr/plugins/$rel" "false" \
      "herdr plugin config $rel" || rc=1
  done < <(find "$base" -type f | sort)
  return $rc
}

herdr_deploy_config() {
  local src="$REPO_ROOT/configs/herdr/config.toml" dest="$HOME/.config/herdr/config.toml" before="" bin check
  bin=$(herdr_bin)
  if [[ -n "$bin" ]] && ! check=$(HERDR_CONFIG_PATH="$src" "$bin" config check 2>&1); then
    log_error "herdr config.toml not deployed, herdr config check failed: $check"
    return 1
  fi
  [[ -f "$dest" ]] && before=$(herdr_sha256 "$dest")
  deploy_file "$src" "$dest" "configs/herdr/config.toml" "false" "herdr config.toml" || return 1
  [[ "$DRY_RUN" == "true" || -z "$bin" || "$(herdr_sha256 "$dest")" == "$before" ]] && return 0

  if [[ -n "$(herdr_server_version "$bin")" ]]; then
    "$bin" server reload-config >/dev/null 2>&1 && log_info "reloaded the running herdr server's config" ||
      log_warn "herdr server reload-config failed; reload from herdr's menu"
  fi
}

herdr_test() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local orig_home="$HOME" orig_dry="$DRY_RUN" orig_no_plugins="${NO_PLUGINS:-false}"

  mkdir -p "$tmp_dir/.local/bin"
  cat >"$tmp_dir/.local/bin/herdr" <<'EOF'
#!/bin/sh
case "$1" in
  --version) echo "herdr 0.0.0" ;;
  plugin) echo '{"result":{"plugins":[]}}' ;;
esac
EOF
  chmod +x "$tmp_dir/.local/bin/herdr"

  export HOME="$tmp_dir"
  DRY_RUN=true
  NO_PLUGINS=false
  local output rc=0
  output=$(herdr_install 2>&1) || rc=$?
  export HOME="$orig_home"
  DRY_RUN="$orig_dry"
  NO_PLUGINS="$orig_no_plugins"
  rm -rf "$tmp_dir"

  if [[ $rc -ne 0 ]]; then
    log_error "herdr_test: dry-run install failed: $output"
    return 1
  fi
  local expected slug line
  expected=("would install herdr $HERDR_VERSION" "would deploy: herdr config.toml")
  while IFS=$'\t' read -r slug _; do
    expected+=("would install: herdr plugin $slug")
  done < <(herdr_read_plugins "$REPO_ROOT/configs/herdr/plugins.tsv")
  for line in "${expected[@]}"; do
    if ! grep -qF "[dry-run] $line" <<<"$output"; then
      log_error "herdr_test: dry run did not report: $line"
      return 1
    fi
  done
}
