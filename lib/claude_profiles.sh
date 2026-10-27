#!/bin/bash

declare -F spec_load >/dev/null 2>&1 || source "$(dirname "${BASH_SOURCE[0]}")/claude_profile_spec.sh"

CLAUDE_PROFILE_ENTRIES=(settings.json CLAUDE.md skills commands)

claude_profile_tool_path() {
  printf '%s\n' "$REPO_ROOT/configs/claude-code/bin/claude-profile"
}

# Main counts as memory-off when this run says so or when an earlier
# --no-memory install left main without the memory hooks, because a profile
# must not wire hooks that main never deployed.
claude_main_memory_off() {
  profile_no_memory || [[ ! -e "$CLAUDE_CONFIG_DIR/hooks/${MEMORY_HOOKS[0]}" ]]
}

claude_profile_owned_list() {
  awk '$1 == "owned" { print $2 }' "$1/.harness-owned" 2>/dev/null || true
}

claude_profile_has() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# An entry still linked to ~/.claude must lose the link before anything writes
# it, because every deploy helper follows symlinks and would write into main.
claude_profile_take() {
  local path="$1"
  [[ -L "$path" ]] || return 0
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would replace the link $path with the profile's own copy"
    return 0
  fi
  rm -- "$path"
}

# A link left in place can only be a dry run's (claude_profile_take removes it
# otherwise); comparing or merging through it would preview against main's file
# instead of the fresh deploy the real run does.
claude_profile_preview_fresh() {
  local dest="$1" label="$2"
  [[ -L "$dest" ]] || return 1
  log_info "[dry-run] would deploy: $label"
}

claude_profile_release() {
  local name="$1" path="$2"
  [[ -e "$path" && ! -L "$path" ]] || return 0
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would return $path to the shared ~/.claude copy"
    return 0
  fi
  local backup="$HARNESS_BACKUP_DIR/$HARNESS_RUN_TS/${path##*/}"
  mkdir -p "$(dirname "$backup")"
  cp -a "$path" "$backup"
  rm -rf -- "$path"
  manifest_drop "$path"
  rm -f "$(merge_base_path "$path")"
  log_warn "profile $name: ${path##*/} is no longer overridden and links to ~/.claude again; the profile's copy, with any edits made in it, is in the backup $backup"
}

claude_profile_settings() {
  local dest="$1" label="$2" cand overlay="$SPEC_DIR/settings.json" rc=0
  cand=$(mktemp)
  if ! render_candidate "$REPO_ROOT/configs/claude-code/settings.json.tmpl" "$cand" "$dest" "$label"; then
    rm -f "$cand"
    return 1
  fi
  if [[ -f "$overlay" ]]; then
    if ! jq --slurpfile overlay "$overlay" -f "$REPO_ROOT/lib/profile_overlay.jq" "$cand" >"$cand.overlay"; then
      rm -f "$cand" "$cand.overlay"
      log_error "failed to deploy $label (overlay $overlay did not apply)"
      return 1
    fi
    mv "$cand.overlay" "$cand"
  fi
  if ! claude_profile_preview_fresh "$dest" "$label"; then
    deploy_reconciled_candidate "$cand" "$dest" "configs/claude-code/settings.json.tmpl" "$label" || rc=$?
  fi
  rm -f "$cand"
  return $rc
}

claude_profile_claude_md() {
  local dest="$1" label="$2" cand rule
  cand=$(mktemp)
  if ! render_candidate "$REPO_ROOT/configs/claude-code/CLAUDE.md.tmpl" "$cand" "$dest" "$label"; then
    rm -f "$cand"
    return 1
  fi
  for rule in "$SPEC_DIR"/rules/*.mdc; do
    [[ -f "$rule" ]] || continue
    {
      printf '\n'
      strip_frontmatter "$rule"
    } >>"$cand"
  done
  claude_profile_preview_fresh "$dest" "$label" ||
    deploy_file "$cand" "$dest" "configs/claude-code/CLAUDE.md.tmpl" "true" "$label"
  rm -f "$cand"
}

claude_profile_selects() {
  local kind="$1" name="$2"
  case "$kind" in
    skills)
      profile_skips_skill "$name" && return 1
      spec_selects skills "$name"
      ;;
    commands)
      profile_skips_command "$name" && return 1
      spec_selects commands "${name%.md}"
      ;;
  esac
}

# Rebuilt from scratch every run: a link per selected entry of main's dir, read
# at run time so skills deployed outside configs/ (impeccable, the user's own)
# count, then the spec's own entries, which replace a main entry of that name.
claude_profile_dir() {
  local dest="$1" kind="$2" label="$3" stage src name
  stage=$(mktemp -d)
  for src in "$CLAUDE_CONFIG_DIR/$kind"/*; do
    [[ -e "$src" ]] || continue
    name="${src##*/}"
    claude_profile_selects "$kind" "$name" || continue
    [[ -e "$SPEC_DIR/$kind/$name" ]] && continue
    ln -s "$CLAUDE_CONFIG_DIR/$kind/$name" "$stage/$name"
  done
  [[ -d "$SPEC_DIR/$kind" ]] && cp -R "$SPEC_DIR/$kind/." "$stage/"

  if [[ -d "$dest" && ! -L "$dest" ]] && diff -rq --no-dereference "$stage" "$dest" >/dev/null 2>&1; then
    rm -rf "$stage"
    log_skip "$label" "unchanged"
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    rm -rf "$stage"
    log_info "[dry-run] would rebuild: $label"
    return 0
  fi
  rm -rf -- "$dest"
  chmod 755 "$stage"
  mv "$stage" "$dest"
  log_update "rebuilt: $label"
}

# Besides the owned entries, records the MCP servers sync must drop from the
# profile, which a work machine needs even when nothing is owned.
claude_profile_write_owned() {
  local dir="$1" entry server
  shift
  [[ "$DRY_RUN" == "true" ]] && return 0
  if [[ $# -eq 0 ]] && ! profile_work; then
    rm -f "$dir/.harness-owned"
    return 0
  fi
  {
    for entry in "$@"; do
      printf 'owned %s\n' "$entry"
    done
    for server in "${MEMORY_MCP_SERVERS[@]}" "${WORK_MCP_SERVERS[@]}"; do
      profile_skips_mcp_server "$server" && printf 'drop-mcp %s\n' "$server"
    done | sort -u
  } >"$dir/.harness-owned"
}

# Runs in a subshell so the spec, NO_MEMORY and the profile's own manifest,
# backup and merge-base locations never leak into main's install or into the
# modules that run after claude.
claude_profile_render() (
  local name="$1" dir spec_rc=0 entry rc=0
  dir="$HOME/.claude-$name"
  if [[ ! -d "$dir" ]]; then
    log_error "no profile $name at $dir; create it first with: claude-profile $name"
    exit 1
  fi
  spec_load "$name" || spec_rc=$?
  [[ $spec_rc -eq 2 ]] && exit 1

  local memory_off=false
  if [[ "$SPEC_MEMORY" == off ]] || claude_main_memory_off; then memory_off=true; fi
  NO_MEMORY=""
  [[ "$memory_off" == true ]] && NO_MEMORY=1

  local -a owned previous
  mapfile -t owned < <(spec_owned_entries)
  mapfile -t previous < <(claude_profile_owned_list "$dir")
  if [[ ${#owned[@]} -eq 0 && ${#previous[@]} -eq 0 ]] && ! profile_work &&
    ! grep -qE '^(work|drop-mcp) ' "$dir/.harness-owned" 2>/dev/null; then
    exit 0
  fi

  local state="$dir/.harness"
  export HARNESS_MANIFEST="$state/manifest.json"
  export HARNESS_BACKUP_DIR="$state/backups"
  export HARNESS_MERGE_BASE_DIR="$state/merge-base"
  HARNESS_RUN_TS=$(date +%Y%m%d_%H%M%S)
  export HARNESS_RUN_TS
  log_info "profile $name: overrides ${owned[*]:-nothing}"
  if [[ "$DRY_RUN" != "true" ]]; then
    mkdir -p "$state"
    manifest_init
  fi

  for entry in "${CLAUDE_PROFILE_ENTRIES[@]}"; do
    local path="$dir/$entry" label="profile $name $entry"
    if ! claude_profile_has "$entry" ${owned[@]+"${owned[@]}"}; then
      if claude_profile_has "$entry" ${previous[@]+"${previous[@]}"}; then
        claude_profile_release "$name" "$path"
      fi
      continue
    fi
    claude_profile_take "$path"
    case "$entry" in
      settings.json) claude_profile_settings "$path" "$label" || rc=1 ;;
      CLAUDE.md) claude_profile_claude_md "$path" "$label" || rc=1 ;;
      skills | commands) claude_profile_dir "$path" "$entry" "$label" || rc=1 ;;
    esac
  done

  claude_profile_write_owned "$dir" ${owned[@]+"${owned[@]}"}
  if [[ "$DRY_RUN" != "true" ]]; then
    bash "$(claude_profile_tool_path)" sync "$name" >/dev/null || rc=1
  fi
  exit $rc
)

claude_profiles_render_all() {
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    claude_profile_render "$name" || log_error "profile $name was not rebuilt"
  done < <(bash "$(claude_profile_tool_path)" names 2>/dev/null || true)
}
