#!/usr/bin/env bash

opencode_check() {
    if [[ "$HAS_OPENCODE" != "true" ]]; then
        log_info "opencode not detected, skipping"
        log_info "  Install: npm install -g opencode-ai"
        return 1
    fi
    if [[ ! -d "$OPENCODE_CONFIG_DIR" ]]; then
        mkdir -p "$OPENCODE_CONFIG_DIR"
    fi
    return 0
}

opencode_deploy_config() {
  local rules_src="$REPO_ROOT/configs/opencode/AGENTS.md.tmpl"
  local config_src="$REPO_ROOT/configs/opencode/opencode.jsonc.tmpl"

  if [[ -f "$rules_src" ]]; then
    local dest="$OPENCODE_CONFIG_DIR/AGENTS.md"
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would deploy opencode AGENTS.md"
    else
      [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"
      if deploy_template "$rules_src" "$dest"; then
        manifest_add "$dest" "configs/opencode/AGENTS.md.tmpl" "true"
        log_success "opencode AGENTS.md deployed"
      else
        log_error "failed to deploy opencode AGENTS.md"
      fi
    fi
  fi

  if [[ -f "$config_src" ]] && ! head -1 "$config_src" | grep -q '^// harness does not manage'; then
    local dest="$OPENCODE_CONFIG_DIR/opencode.jsonc"
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would deploy opencode.jsonc"
    else
      [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"
      if deploy_template "$config_src" "$dest"; then
        manifest_add "$dest" "configs/opencode/opencode.jsonc.tmpl" "true"
        log_success "opencode.jsonc deployed"
      else
        log_error "failed to deploy opencode.jsonc"
      fi
    fi
  fi
}

# Merges harness-provided MCP servers (web-strip, markitdown, second-brain when
# installed) into opencode's "mcp" config key. Targets opencode.json unless
# only an opencode.jsonc exists (the file the user's own reference template
# points them at for machine-specific settings), in which case it targets
# that file instead so there's a single source of truth. deploy_merged_json
# refuses to touch a file that isn't strict JSON (e.g. a hand-commented
# .jsonc) rather than risk dropping the user's content on a parse/re-dump.
opencode_mcp() {
  local dest="$OPENCODE_CONFIG_DIR/opencode.json"
  if [[ ! -f "$dest" && -f "$OPENCODE_CONFIG_DIR/opencode.jsonc" ]]; then
    dest="$OPENCODE_CONFIG_DIR/opencode.jsonc"
  fi

  declare -f second_brain_find_binaries >/dev/null 2>&1 || source "$REPO_ROOT/modules/second-brain.sh"
  second_brain_find_binaries
  local sb_mcp="$SB_MCP_BIN" sb_api="$SB_API_BIN"
  local web_strip_path="$HOME/.harness/tools/web-strip/index.js"

  local fragment
  fragment=$(mktemp)
  {
    printf '{"mcp":{'
    printf '"web-strip":{"type":"local","command":["node","%s"],"enabled":true},' "$web_strip_path"
    printf '"markitdown":{"type":"local","command":["uvx","markitdown-mcp"],"enabled":true}'
    if [[ -n "$sb_mcp" ]]; then
      printf ',"second-brain":{"type":"local","command":["%s"],"environment":{"SECOND_BRAIN_API":"http://127.0.0.1:7200"' "$sb_mcp"
      [[ -n "$sb_api" ]] && printf ',"SECOND_BRAIN_DAEMON_BIN":"%s"' "$sb_api"
      printf '},"enabled":true}'
    fi
    printf '}}'
  } > "$fragment"

  deploy_merged_json "$fragment" "$dest" "runtime:opencode-mcp" "opencode MCP servers" "mcp" || true
}

# Deploys a plugin, opencode's only lifecycle-hook mechanism (there is no
# shell-command hook config like Claude Code/Codex have), that mirrors
# session-end-ingest.sh: on session.idle, it kicks off a non-blocking
# second-brain ingest if the daemon is healthy. opencode's plugin API
# (checked against https://opencode.ai/docs/plugins as of this writing) has
# no SessionStart equivalent that can inject additional context into the
# model's turn the way Claude Code's and Codex's
# hookSpecificOutput.additionalContext can. That leaves the
# wiki-context-at-session-start half of wiki-maintenance.mdc without an
# opencode implementation for now, a real platform gap rather than something
# skipped here.
opencode_wiki_plugin() {
  local dest_dir="$OPENCODE_CONFIG_DIR/plugins"
  local dest="$dest_dir/harness-second-brain.js"
  local src="$REPO_ROOT/configs/opencode/plugins/harness-second-brain.js"

  [[ -f "$src" ]] || return 0

  if [[ "$FORCE" == "false" && -f "$dest" ]]; then
    local src_hash dest_hash
    src_hash=$(file_checksum "$src")
    dest_hash=$(file_checksum "$dest")
    if [[ "$src_hash" == "$dest_hash" ]]; then
      log_skip "opencode second-brain plugin" "unchanged"
      return
    fi
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would deploy opencode second-brain plugin"
    return
  fi

  mkdir -p "$dest_dir"
  [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"
  cp "$src" "$dest"
  manifest_add "$dest" "configs/opencode/plugins/harness-second-brain.js" "false"
  log_success "opencode second-brain plugin deployed"
}

opencode_install() {
  opencode_deploy_config
  opencode_mcp
  opencode_wiki_plugin
  deploy_shared_commands "$OPENCODE_CONFIG_DIR/commands"
  # opencode auto-scans ~/.claude/skills and ~/.agents/skills for SKILL.md files,
  # so shared skills land in ~/.agents/skills (same target as the codex module;
  # both calls are checksum-idempotent) rather than a private opencode dir.
  deploy_shared_skills "$HOME/.agents/skills"
  deploy_impeccable_skill "codex" "$HOME/.agents/skills/impeccable"
}

opencode_test() {
    local tmp_dir
    tmp_dir=$(mktemp -d)

    local orig_home="$HOME"
    local orig_config="${OPENCODE_CONFIG_DIR:-}"
    local orig_dry="$DRY_RUN"
    local orig_force="$FORCE"
    local orig_no_backup="$NO_BACKUP"

    export HOME="$tmp_dir"
    OPENCODE_CONFIG_DIR="$tmp_dir/.config/opencode"
    DRY_RUN=true
    FORCE=true
    NO_BACKUP=true
    mkdir -p "$OPENCODE_CONFIG_DIR"

    local output
    output=$(opencode_deploy_config 2>&1)
    output+=$'\n'
    output+=$(opencode_mcp 2>&1)
    output+=$'\n'
    output+=$(opencode_wiki_plugin 2>&1)

    HOME="$orig_home"
    OPENCODE_CONFIG_DIR="$orig_config"
    DRY_RUN="$orig_dry"
    FORCE="$orig_force"
    NO_BACKUP="$orig_no_backup"
    rm -rf "$tmp_dir"

    if ! echo "$output" | grep -q '\[dry-run\]'; then
        log_error "opencode_test: no dry-run output produced"
        return 1
    fi

    if ! echo "$output" | grep -q 'MCP servers'; then
        log_error "opencode_test: opencode_mcp produced no output"
        return 1
    fi

    if ! echo "$output" | grep -qi 'second-brain plugin'; then
        log_error "opencode_test: opencode_wiki_plugin produced no output"
        return 1
    fi

    return 0
}
