#!/usr/bin/env bash

source "$REPO_ROOT/lib/verified_download.sh"

WIKI_SYNC_SRC="${WIKI_SYNC_SRC:-$REPO_ROOT/configs/wiki-sync}"
WIKI_SYNC_UNITS=(wiki-sync.service wiki-sync-watchdog.service wiki-sync-watchdog.timer wiki-sync-watchdog.path)
WIKI_SYNC_AGENTS=(com.harness.wiki-sync com.harness.wiki-sync-watchdog)

wiki_sync_home() {
  printf '%s\n' "$HOME/.local/share/harness/wiki-sync"
}

wiki_sync_plugin_json() {
  printf '%s/.obsidian/plugins/obsidian-livesync/data.json\n' "$1"
}

# A work machine's WIKI_VAULT may already end in /Work/agent-wiki, so the vault
# is found by walking up from the wiki dir rather than taken from the setting.
wiki_sync_resolve() {
  local vault dir
  vault=$(profile_wiki_vault)
  [[ -n "$vault" ]] || return 1
  WS_WIKI_DIR="${vault%/}/wiki"
  dir="$WS_WIKI_DIR"
  while [[ -n "$dir" && "$dir" != / ]]; do
    if [[ -f "$(wiki_sync_plugin_json "$dir")" ]]; then
      WS_VAULT="$dir"
      WS_DATA_JSON="$(wiki_sync_plugin_json "$dir")"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

wiki_sync_target() {
  local os arch
  case "$(uname -s)" in
    Linux) os=unknown-linux-gnu ;;
    Darwin) os=apple-darwin ;;
    *) return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) return 1 ;;
  esac
  printf '%s-%s\n' "$arch" "$os"
}

wiki_sync_pin() {
  local name="$1"
  sed -n "s/^${name}=//p" "$WIKI_SYNC_SRC/pins.env"
}

wiki_sync_check() {
  local ok=0 tool
  local proc="${WIKI_SYNC_PROC_VERSION:-/proc/version}"
  if [[ -r "$proc" ]] && grep -qi microsoft "$proc"; then
    log_warn "wiki-sync: WSL keeps Obsidian's own sync"
    return 1
  fi
  if ! wiki_sync_resolve; then
    log_warn "wiki-sync: no LiveSync plugin settings at or above $(profile_wiki_vault)/wiki"
    return 1
  fi
  wiki_sync_target >/dev/null || {
    log_warn "wiki-sync: unsupported platform $(uname -s) $(uname -m)"
    return 1
  }
  for tool in curl unzip jq tar; do
    command -v "$tool" >/dev/null 2>&1 || { log_warn "wiki-sync: $tool not found"; ok=1; }
  done
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    log_warn "wiki-sync: sha256sum or shasum not found"
    ok=1
  fi
  return $ok
}

wiki_sync_ensure_deno() {
  local home="$1" version target sha tmp
  version=$(wiki_sync_pin WIKI_SYNC_DENO_VERSION)
  if [[ -x "$home/deno/deno" && "$("$home/deno/deno" --version 2>/dev/null | head -1)" == "deno $version "* ]]; then
    return 0
  fi
  target=$(wiki_sync_target) || return 1
  sha=$(wiki_sync_pin "WIKI_SYNC_DENO_SHA256_${target//-/_}")
  mkdir -p "$home/deno"
  tmp=$(mktemp -d)
  if ! fetch_verified "https://github.com/denoland/deno/releases/download/v$version/deno-$target.zip" "$sha" "$tmp/deno.zip"; then
    rm -rf "$tmp"
    log_error "wiki-sync: Deno $version was not installed"
    return 1
  fi
  unzip -q -o "$tmp/deno.zip" -d "$tmp" && chmod 755 "$tmp/deno" && mv -f "$tmp/deno" "$home/deno/deno"
  rm -rf "$tmp"
  log_success "wiki-sync: installed Deno $version"
}

wiki_sync_render() {
  local src="$1" dest="$2" home="$3"
  sed -e "s|@INSTALL@|$home|g" -e "s|@HOME@|$HOME|g" -e "s|@DATA_JSON@|$WS_DATA_JSON|g" "$src" >"$dest"
}

# Renders the service files for this platform into $1, one file per unit or agent.
wiki_sync_render_services() {
  local out="$1" home="$2" f
  mkdir -p "$out"
  if [[ "$(uname -s)" == Darwin ]]; then
    for f in "${WIKI_SYNC_AGENTS[@]}"; do
      wiki_sync_render "$WIKI_SYNC_SRC/launchd/$f.plist" "$out/$f.plist" "$home"
    done
  else
    for f in "${WIKI_SYNC_UNITS[@]}"; do
      wiki_sync_render "$WIKI_SYNC_SRC/systemd/$f" "$out/$f" "$home"
    done
  fi
}

wiki_sync_stamp() {
  local rendered="$1"
  {
    printf '%s\n%s\n%s\n' "$WS_VAULT" "$WS_WIKI_DIR" "$(uname -s)"
    (cd "$WIKI_SYNC_SRC" && find pins.env run.sh watchdog.sh reset.sh service.sh src -type f | LC_ALL=C sort | while read -r f; do
      printf '%s %s\n' "$f" "$(sha256_file "$f")"
    done)
    (cd "$rendered" && for f in *; do printf '%s %s\n' "$f" "$(sha256_file "$f")"; done)
  }
}

wiki_sync_stamp_value() {
  local tmp
  tmp=$(mktemp)
  cat >"$tmp"
  sha256_file "$tmp"
  rm -f "$tmp"
}

# Copies the daemon into $1 and caches its dependencies there, so the service
# needs no network for them at start. Also used to stage integration installs.
wiki_sync_stage() {
  local home="$1" f
  mkdir -p "$home/state" "$home/recovered" "$home/snapshots"
  rm -rf "$home/src.new"
  cp -R "$WIKI_SYNC_SRC/src" "$home/src.new"
  rm -f "$home/src.new/"*.test.ts "$home/src.new/memory_remote.ts"
  rm -rf "$home/src"
  mv "$home/src.new" "$home/src"
  for f in run.sh watchdog.sh reset.sh service.sh; do
    install -m 755 "$WIKI_SYNC_SRC/$f" "$home/$f"
  done
  printf 'WIKI_SYNC_VAULT=%q\nWIKI_SYNC_DIR=%q\n' "$WS_VAULT" "$WS_WIKI_DIR" >"$home/env"
  (cd "$home/src" && DENO_DIR="$home/state/deno" DENO_NO_UPDATE_CHECK=1 "$home/deno/deno" install --frozen \
    --entrypoint main.ts >/dev/null 2>&1) || {
    log_error "wiki-sync: caching dependencies failed (run: cd $home/src && DENO_DIR=$home/state/deno $home/deno/deno install --frozen --entrypoint main.ts)"
    return 1
  }
}

wiki_sync_snapshot_first_start() {
  local home="$1" snap
  [[ -e "$home/state/first-start-done" ]] && return 0
  snap="$home/snapshots/first-start-$(date -u +%Y%m%dT%H%M%S).tar.gz"
  if [[ -e "$snap" ]]; then
    log_error "wiki-sync: $snap already exists"
    return 1
  fi
  mkdir -p "$home/snapshots"
  [[ -d "$WS_WIKI_DIR" ]] || return 0
  if tar -czf "$snap" -C "$(dirname "$WS_WIKI_DIR")" "$(basename "$WS_WIKI_DIR")"; then
    log_info "wiki-sync: snapshot of the wiki before the first start: $snap"
  else
    rm -f "$snap"
    log_error "wiki-sync: could not snapshot $WS_WIKI_DIR"
    return 1
  fi
}

wiki_sync_activate_linux() {
  local rendered="$1" dir="$HOME/.config/systemd/user" f
  mkdir -p "$dir"
  for f in "${WIKI_SYNC_UNITS[@]}"; do
    install -m 644 "$rendered/$f" "$dir/$f"
  done
  if command -v loginctl >/dev/null 2>&1; then
    loginctl enable-linger "$(whoami)" 2>/dev/null || true
  fi
  systemctl --user daemon-reload
  systemctl --user enable wiki-sync.service wiki-sync-watchdog.timer wiki-sync-watchdog.path >/dev/null 2>&1 || true
  systemctl --user restart wiki-sync.service
  systemctl --user restart wiki-sync-watchdog.timer wiki-sync-watchdog.path
}

wiki_sync_activate_darwin() {
  local rendered="$1" dir="$HOME/Library/LaunchAgents" f domain
  domain="gui/$(id -u)"
  mkdir -p "$dir" "$HOME/Library/Logs"
  for f in "${WIKI_SYNC_AGENTS[@]}"; do
    launchctl bootout "$domain/$f" 2>/dev/null || true
    install -m 644 "$rendered/$f.plist" "$dir/$f.plist"
    launchctl bootstrap "$domain" "$dir/$f.plist"
  done
}

wiki_sync_stop_service() {
  if [[ "$(uname -s)" == Darwin ]]; then
    launchctl bootout "gui/$(id -u)/com.harness.wiki-sync" 2>/dev/null || true
  elif systemctl --user is-active --quiet wiki-sync.service 2>/dev/null; then
    systemctl --user stop wiki-sync.service
  fi
}

wiki_sync_install() {
  local home rendered stamp
  home=$(wiki_sync_home)
  wiki_sync_resolve || return 1
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would install wiki-sync for $WS_WIKI_DIR (vault $WS_VAULT) into $home"
    return 0
  fi
  rendered=$(mktemp -d)
  wiki_sync_render_services "$rendered" "$home"
  stamp=$(wiki_sync_stamp "$rendered" | wiki_sync_stamp_value)
  if [[ -e "$home/state/first-start-done" && -f "$home/stamp" && "$(cat "$home/stamp")" == "$stamp" ]]; then
    rm -rf "$rendered"
    log_skip "wiki-sync" "already installed"
    return 0
  fi
  if ! wiki_sync_ensure_deno "$home"; then
    rm -rf "$rendered"
    return 1
  fi
  if [[ ! -e "$home/state/first-start-done" ]]; then
    wiki_sync_stop_service
    wiki_sync_snapshot_first_start "$home" || { rm -rf "$rendered"; return 1; }
  fi
  if ! wiki_sync_stage "$home"; then
    rm -rf "$rendered"
    return 1
  fi
  if [[ "$(uname -s)" == Darwin ]]; then
    wiki_sync_activate_darwin "$rendered"
  else
    wiki_sync_activate_linux "$rendered"
  fi
  rm -rf "$rendered"
  printf '%s\n' "$stamp" >"$home/stamp"
  log_success "wiki-sync: syncing $WS_WIKI_DIR"
}

wiki_sync_test() {
  local tmp orig_home="$HOME" orig_dry="$DRY_RUN" orig_env="${HARNESS_ENV:-}" rc=0 out
  tmp=$(mktemp -d)
  export HOME="$tmp"
  DRY_RUN=true
  HARNESS_ENV="$tmp/.harness.env"
  mkdir -p "$tmp/vault/wiki" "$(dirname "$(wiki_sync_plugin_json "$tmp/vault")")"
  echo '{}' >"$(wiki_sync_plugin_json "$tmp/vault")"
  echo "WIKI_VAULT=$tmp/vault" >"$HARNESS_ENV"
  out=$(wiki_sync_install 2>&1) || rc=1
  grep -q "would install wiki-sync" <<<"$out" || rc=1
  export HOME="$orig_home"
  DRY_RUN="$orig_dry"
  HARNESS_ENV="$orig_env"
  rm -rf "$tmp"
  return $rc
}
