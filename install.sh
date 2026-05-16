#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd 2>/dev/null)" || SCRIPT_DIR=""

if [[ -z "$SCRIPT_DIR" || ! -f "$SCRIPT_DIR/lib/common.sh" ]]; then
  HARNESS_DIR="${HARNESS_DIR:-$HOME/.harness}"
  if [[ ! -d "$HARNESS_DIR" ]]; then
    echo "[harness] Cloning repository..."
    git clone https://github.com/anyesh/harness.git "$HARNESS_DIR"
  else
    echo "[harness] Updating repository..."
    git -C "$HARNESS_DIR" pull --ff-only 2>/dev/null || true
  fi
  exec "$HARNESS_DIR/install.sh" "$@"
fi

REPO_ROOT="$SCRIPT_DIR"

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/template.sh"
source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/detect.sh"
source "$REPO_ROOT/lib/backup.sh"
source "$REPO_ROOT/modules/lib.sh"

COMMAND="${1:-install}"
FORCE=false
DRY_RUN=false
NO_PLUGINS=false
NO_BACKUP=false
ONLY_MODULE=""

if [[ "$COMMAND" == --* ]]; then
  COMMAND="install"
else
  shift || true
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true ;;
    --dry-run) DRY_RUN=true ;;
    --no-plugins) NO_PLUGINS=true ;;
    --no-backup) NO_BACKUP=true ;;
    --only) shift; ONLY_MODULE="${1:-}"; [[ -z "$ONLY_MODULE" ]] && die "--only requires a module name" ;;
    --claude-only) ONLY_MODULE="claude" ;;
    --cursor-only) ONLY_MODULE="cursor" ;;
    --codex-only) ONLY_MODULE="codex" ;;
    *) die "unknown flag: $1" ;;
  esac
  shift
done

MODULE_ORDER=(second-brain claude cursor codex rtk wiki)

deploy_shared_skills() {
  local dest_dir="$1"
  local skills_src="$REPO_ROOT/configs/shared/skills"

  if [[ ! -d "$skills_src" ]]; then
    log_warn "shared skills directory not found"
    return
  fi

  mkdir -p "$dest_dir"

  for skill_dir in "$skills_src"/*/; do
    [[ ! -d "$skill_dir" ]] && continue
    local skill_name
    skill_name=$(basename "$skill_dir")
    local dest="$dest_dir/$skill_name"

    if [[ "$FORCE" == "false" && -d "$dest" ]]; then
      log_skip "skill $skill_name" "exists"
      continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would deploy skill: $skill_name"
      continue
    fi

    rm -rf "$dest"
    cp -r "$skill_dir" "$dest"
    log_success "skill: $skill_name"
  done
}

deploy_tools() {
  local tools_src="$REPO_ROOT/tools"
  local tools_dest="$HOME/.harness/tools"

  if [[ ! -d "$tools_src" ]]; then
    return
  fi

  mkdir -p "$tools_dest"

  for tool_dir in "$tools_src"/*/; do
    [[ ! -d "$tool_dir" ]] && continue
    local tool_name
    tool_name=$(basename "$tool_dir")
    local dest="$tools_dest/$tool_name"

    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would deploy tool: $tool_name"
      continue
    fi

    mkdir -p "$dest"
    cp "$tool_dir"/*.js "$dest/" 2>/dev/null || true
    cp "$tool_dir"/*.json "$dest/" 2>/dev/null || true

    if [[ -f "$dest/package.json" && ! -d "$dest/node_modules" ]]; then
      if command -v npm &>/dev/null; then
        log_info "installing $tool_name dependencies..."
        (cd "$dest" && npm install --production --silent 2>/dev/null) || log_warn "$tool_name: npm install failed"
      else
        log_warn "$tool_name requires npm but npm not found"
      fi
    fi

    chmod +x "$dest/index.js" 2>/dev/null || true
    log_success "tool: $tool_name"
  done
}

setup_global_gitignore() {
  local git_ignore_dir="$HOME/.config/git"
  local git_ignore_file="$git_ignore_dir/ignore"

  mkdir -p "$git_ignore_dir"

  local harness_artifacts=(
    ".scope.md"
    ".scope-turn-count"
    ".wiki-sync-pending"
    "**/.claude/settings.local.json"
  )

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would update global gitignore at $git_ignore_file"
    return
  fi

  local changed=false
  for pattern in "${harness_artifacts[@]}"; do
    if ! grep -qxF "$pattern" "$git_ignore_file" 2>/dev/null; then
      echo "$pattern" >> "$git_ignore_file"
      changed=true
    fi
  done

  if [[ "$changed" == "true" ]]; then
    log_update "global gitignore: $git_ignore_file"
  else
    log_skip "global gitignore" "up to date"
  fi
}

cmd_status() {
  manifest_init
  local dirty=0

  log_section "Harness Status"

  for dest in $(manifest_list_files); do
    if [[ ! -f "$dest" ]]; then
      printf "  ${RED}MISSING${RESET}  %s\n" "$dest"
      dirty=$((dirty + 1))
    elif manifest_check_changed "$dest"; then
      printf "  ${YELLOW}DIRTY${RESET}    %s\n" "$dest"
      dirty=$((dirty + 1))
    else
      printf "  ${GREEN}CLEAN${RESET}    %s\n" "$dest"
    fi
  done

  echo ""
  if [[ $dirty -eq 0 ]]; then
    log_info "all managed files are clean"
    return 0
  else
    log_warn "$dirty file(s) have local modifications"
    return 1
  fi
}

cmd_uninstall() {
  log_section "Harness Uninstall"
  log_info "restoring from latest backup..."
  restore_latest
  log_info "removing manifest..."
  rm -f "$HARNESS_MANIFEST"
  log_success "uninstall complete"
}

cmd_edit() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    die "usage: install.sh edit <path-relative-to-repo>"
  fi

  local full_path="$REPO_ROOT/$target"
  if [[ ! -f "$full_path" ]]; then
    die "file not found: $full_path"
  fi

  local checksum_before
  checksum_before=$(file_checksum "$full_path")

  "${EDITOR:-vim}" "$full_path"

  local checksum_after
  checksum_after=$(file_checksum "$full_path")

  if [[ "$checksum_before" != "$checksum_after" ]]; then
    log_info "file changed, re-deploying..."
    exec "$REPO_ROOT/install.sh" --force
  else
    log_info "no changes detected"
  fi
}

case "$COMMAND" in
  install) ;;
  status) cmd_status; exit $? ;;
  uninstall) cmd_uninstall; exit $? ;;
  edit) cmd_edit "${2:-}"; exit $? ;;
  watch) source "$REPO_ROOT/modules/watch.sh"; cmd_watch; exit $? ;;
  validate) source "$REPO_ROOT/lib/template.sh"; validate_all_templates; exit $? ;;
  *) die "unknown command: $COMMAND. Use: install, status, edit, uninstall, watch, validate" ;;
esac

log_section "Harness Bootstrap"
log_info "repo: $REPO_ROOT"

if [[ -f "$HARNESS_ENV" ]]; then
  log_info "using env overrides from $HARNESS_ENV"
else
  log_info "no $HARNESS_ENV found, using defaults (HOME_DIR=$HOME)"
fi

detect_tools

if [[ -n "$ONLY_MODULE" ]]; then
  case "$ONLY_MODULE" in
    claude)  HAS_CURSOR=false; HAS_CODEX=false ;;
    cursor)  HAS_CLAUDE=false; HAS_CODEX=false ;;
    codex)   HAS_CLAUDE=false; HAS_CURSOR=false ;;
  esac
fi

manifest_init

for mod in "${MODULE_ORDER[@]}"; do
  if [[ -n "$ONLY_MODULE" && "$mod" != "$ONLY_MODULE" ]]; then
    continue
  fi
  load_module "$mod"
  run_module "$mod" || true
done

log_section "System Hygiene"
setup_global_gitignore

log_section "Tools"
deploy_tools

manifest_finalize
report_summary

if [[ $FAILED -gt 0 && $INSTALLED -eq 0 && $UPDATED -eq 0 ]]; then
  exit 1
fi
exit 0
