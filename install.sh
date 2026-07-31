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

# WHY: install.sh often runs from a non-interactive shell (ssh "cmd", cron)
# that never sources .bashrc/.profile, where per-user tool installs like
# claude (~/.local/bin) or cargo-installed binaries (~/.cargo/bin) would
# otherwise be invisible to `command -v` even though they're really there.
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

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
    --opencode-only) ONLY_MODULE="opencode" ;;
    *) die "unknown flag: $1" ;;
  esac
  shift
done

MODULE_ORDER=(second-brain verdant claude cursor codex opencode wiki leakguard)

HOOK_SKIP_FILES=()

deploy_hooks_from() {
  local src_dir="$1"
  local dest_dir="$2"
  local manifest_prefix="$3"

  if [[ ! -d "$src_dir" ]]; then
    return
  fi

  for hook_file in "$src_dir"/*; do
    [[ ! -f "$hook_file" ]] && continue
    local filename
    filename=$(basename "$hook_file")

    local skip=false
    for skipname in "${HOOK_SKIP_FILES[@]}"; do
      [[ "$filename" == "$skipname" ]] && skip=true && break
    done
    [[ "$skip" == "true" ]] && continue

    local dest="$dest_dir/$filename"

    if [[ "$FORCE" == "false" && -f "$dest" ]]; then
      local src_hash dest_hash
      src_hash=$(file_checksum "$hook_file")
      dest_hash=$(file_checksum "$dest")
      if [[ "$src_hash" == "$dest_hash" ]]; then
        log_skip "hook $filename" "unchanged"
        continue
      fi
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would deploy hook: $filename"
      continue
    fi

    [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"

    cp "$hook_file" "$dest"
    chmod +x "$dest" 2>/dev/null || true
    manifest_add "$dest" "$manifest_prefix/$filename" "false"
    log_update "hook: $filename"
  done
}

deploy_shared_commands() {
  local dest_dir="$1"
  local cmds_src="$REPO_ROOT/configs/shared/commands"

  if [[ ! -d "$cmds_src" ]]; then
    return
  fi

  mkdir -p "$dest_dir"

  for cmd_file in "$cmds_src"/*.md; do
    [[ ! -f "$cmd_file" ]] && continue
    local filename
    filename=$(basename "$cmd_file")
    local dest="$dest_dir/$filename"

    if [[ "$FORCE" == "false" && -f "$dest" ]]; then
      local src_hash dest_hash
      src_hash=$(file_checksum "$cmd_file")
      dest_hash=$(file_checksum "$dest")
      if [[ "$src_hash" == "$dest_hash" ]]; then
        log_skip "command $filename" "unchanged"
        continue
      fi
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would deploy command: $filename"
      continue
    fi

    [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"
    cp "$cmd_file" "$dest"
    manifest_add "$dest" "configs/shared/commands/$filename" "false"
    log_update "command: $filename"
  done
}

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

    if [[ "$FORCE" == "false" && -d "$dest" ]] && diff -rq "$skill_dir" "$dest" >/dev/null 2>&1; then
      log_skip "skill $skill_name" "unchanged"
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

deploy_impeccable_skill() {
  local variant="$1" dest_dir="$2"
  local src="$REPO_ROOT/configs/impeccable"
  local skill_md="$src/SKILL.$variant.md"

  if [[ ! -f "$skill_md" ]]; then
    log_warn "impeccable SKILL.$variant.md not found, skipping"
    return
  fi

  local src_hash hash_file
  src_hash=$(
    {
      sha256sum "$skill_md"
      find "$src/reference" "$src/scripts" -type f -exec sha256sum {} +
      if [[ "$variant" == "codex" && -d "$src/agents" ]]; then
        find "$src/agents" -type f -exec sha256sum {} +
      fi
    } 2>/dev/null | sort | sha256sum | cut -d' ' -f1
  )
  hash_file="$dest_dir/.src-hash"
  if [[ "$FORCE" == "false" && -d "$dest_dir" && "$(cat "$hash_file" 2>/dev/null)" == "$src_hash" ]]; then
    log_skip "impeccable ($variant)" "unchanged"
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would deploy impeccable ($variant) -> $dest_dir"
    return
  fi

  # dest_rel is the path under $HOME; the deployed files reference scripts by an
  # absolute $HOME path so they resolve from any project CWD (the skill is installed
  # globally, not project-local, so the upstream CWD-relative paths cannot resolve).
  local dest_rel="${dest_dir#"$HOME"/}"

  rm -rf "$dest_dir"
  mkdir -p "$dest_dir"
  cp "$skill_md" "$dest_dir/SKILL.md"
  cp -r "$src/reference" "$dest_dir/reference"
  cp -r "$src/scripts" "$dest_dir/scripts"
  [[ "$variant" == "codex" && -d "$src/agents" ]] && cp -r "$src/agents" "$dest_dir/agents"

  local repl="\$HOME/$dest_rel/"
  local f
  while IFS= read -r f; do
    sed -E -i "s#\\.[a-z]+/skills/impeccable/#${repl}#g" "$f"
  done < <(find "$dest_dir" -maxdepth 2 -name '*.md')

  printf '%s\n' "$src_hash" > "$dest_dir/.src-hash"
  log_success "impeccable ($variant): $dest_dir"
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
  log_info "reverting managed files to pre-harness state..."
  restore_originals
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
    claude)   HAS_CURSOR=false; HAS_CODEX=false; HAS_OPENCODE=false ;;
    cursor)   HAS_CLAUDE=false; HAS_CODEX=false; HAS_OPENCODE=false ;;
    codex)    HAS_CLAUDE=false; HAS_CURSOR=false; HAS_OPENCODE=false ;;
    opencode) HAS_CLAUDE=false; HAS_CURSOR=false; HAS_CODEX=false ;;
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
