#!/usr/bin/env bash

LEAKGUARD_GITLEAKS_VERSION="8.30.1"

leakguard_check() {
  local ok=0
  command -v git >/dev/null 2>&1 || { log_warn "git not found"; ok=1; }
  command -v curl >/dev/null 2>&1 || { log_warn "curl not found"; ok=1; }
  return $ok
}

leakguard_install() {
  leakguard_ensure_binary
  leakguard_deploy_config
  leakguard_deploy_scan_hook
  leakguard_deploy_dispatcher
}

leakguard_ensure_binary() {
  if command -v gitleaks >/dev/null 2>&1; then
    log_skip "gitleaks" "already installed ($(gitleaks version 2>/dev/null))"
    return
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would install gitleaks $LEAKGUARD_GITLEAKS_VERSION to ~/.local/bin"
    return
  fi
  local arch os url
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in
    x86_64) arch="x64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *)
      log_warn "unsupported arch $(uname -m); install gitleaks manually"
      return 1
      ;;
  esac
  url="https://github.com/gitleaks/gitleaks/releases/download/v${LEAKGUARD_GITLEAKS_VERSION}/gitleaks_${LEAKGUARD_GITLEAKS_VERSION}_${os}_${arch}.tar.gz"
  mkdir -p "$HOME/.local/bin"
  if curl -sL "$url" | tar -xz -C "$HOME/.local/bin" gitleaks; then
    log_info "installed gitleaks $LEAKGUARD_GITLEAKS_VERSION to ~/.local/bin"
  else
    log_warn "gitleaks download failed ($url); install manually"
    return 1
  fi
}

# Prints the repo's generic ruleset plus one rule for the comma-separated
# personal terms, which stay out of the public repo in ~/.harness.env.
leakguard_render_config() {
  local base="$1" terms="$2" term esc kw alts="" kws="" list=()
  cat "$base"
  IFS=',' read -ra list <<<"$terms"
  # The guarded expansion keeps macOS bash 3.2 from failing on an empty array under set -u.
  for term in ${list[@]+"${list[@]}"}; do
    term="${term#"${term%%[![:space:]]*}"}"
    term="${term%"${term##*[![:space:]]}"}"
    [[ -n "$term" ]] || continue
    esc="$(printf '%s' "$term" | sed 's/[][\.*^$()+?{}|]/\\&/g')"
    [[ "$term" =~ ^[[:alnum:]_] ]] && esc="\\b$esc"
    [[ "$term" =~ [[:alnum:]_]$ ]] && esc="$esc\\b"
    alts+="${alts:+|}$esc"
    kw="$(printf '%s' "$term" | tr '[:upper:]' '[:lower:]' | sed 's/[\"]/\\&/g')"
    kws+="${kws:+, }\"$kw\""
  done
  [[ -n "$alts" ]] || return 0
  printf '\n[[rules]]\nid = "personal-term"\n'
  printf 'description = "Personal machine, account or domain name from LEAKGUARD_PERSONAL"\n'
  printf "regex = '''(?i)(%s)'''\n" "$alts"
  printf 'keywords = [%s]\n' "$kws"
}

leakguard_deploy_config() {
  load_harness_var LEAKGUARD_PERSONAL
  if [[ -z "${LEAKGUARD_PERSONAL:-}" ]]; then
    log_warn "LEAKGUARD_PERSONAL is not set in ~/.harness.env; commits are not scanned for your machine, account or domain names"
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would deploy gitleaks.toml to ~/.config/leakguard/"
    return
  fi
  mkdir -p "$HOME/.config/leakguard"
  local out="$HOME/.config/leakguard/gitleaks.toml"
  rm -f "$out"
  (
    umask 077
    leakguard_render_config "$REPO_ROOT/configs/leakguard/gitleaks.toml" "${LEAKGUARD_PERSONAL:-}" >"$out"
  )
  log_info "deployed ~/.config/leakguard/gitleaks.toml"
}

leakguard_config_hooks_supported() {
  local dir supported=1
  dir="$(mktemp -d)" || return 1
  if git init -q "$dir/r" 2>/dev/null; then
    git -C "$dir/r" -c core.hooksPath=/dev/null -c hook.probe.event=pre-commit \
      -c "hook.probe.command=touch '$dir/ran'" -c user.name=probe -c user.email=probe@example.com \
      -c commit.gpgsign=false commit -q --allow-empty -m probe >/dev/null 2>&1 || true
    [[ -f "$dir/ran" ]] && supported=0
  fi
  rm -rf "$dir"
  return "$supported"
}

# A config hook runs alongside a repo's own core.hooksPath hook, which would
# otherwise replace the global core.hooksPath and skip the scan.
leakguard_deploy_scan_hook() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would deploy the scan and register hook.leakguard for pre-commit"
    return
  fi
  if ! leakguard_config_hooks_supported; then
    log_error "$(git --version) does not run config hooks (hook.<name>.event), so the leak scan would never run; install a newer git"
    return 1
  fi
  cp "$REPO_ROOT/configs/leakguard/scan" "$HOME/.config/leakguard/scan"
  chmod +x "$HOME/.config/leakguard/scan"
  git config --global --replace-all hook.leakguard.command "$HOME/.config/leakguard/scan"
  git config --global --replace-all hook.leakguard.event pre-commit
  log_info "global pre-commit leak scan active (hook.leakguard)"
}

leakguard_deploy_dispatcher() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would deploy pre-commit dispatcher and set core.hooksPath"
    return
  fi
  mkdir -p "$HOME/.config/git/hooks"
  cp "$REPO_ROOT/configs/leakguard/pre-commit" "$HOME/.config/git/hooks/pre-commit"
  chmod +x "$HOME/.config/git/hooks/pre-commit"
  git config --global core.hooksPath "$HOME/.config/git/hooks"
  log_info "pre-commit dispatcher chains repo-local hooks (core.hooksPath=~/.config/git/hooks)"
}

leakguard_test() {
  local tmp_dir
  tmp_dir=$(mktemp -d)

  local orig_home="$HOME"
  local orig_dry="$DRY_RUN"

  export HOME="$tmp_dir"
  DRY_RUN=true

  local output
  output=$(leakguard_install 2>&1)
  local rc=$?

  export HOME="$orig_home"
  DRY_RUN="$orig_dry"
  rm -rf "$tmp_dir"

  if [[ $rc -ne 0 ]]; then
    log_error "leakguard_test: dry-run install failed: $output"
    return 1
  fi
  return 0
}
