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
    deploy_rendered_template "$rules_src" "$OPENCODE_CONFIG_DIR/AGENTS.md" "configs/opencode/AGENTS.md.tmpl" "opencode AGENTS.md" || true
  fi

  if [[ -f "$config_src" ]] && ! head -1 "$config_src" | grep -q '^// harness does not manage'; then
    deploy_rendered_template "$config_src" "$OPENCODE_CONFIG_DIR/opencode.jsonc" "configs/opencode/opencode.jsonc.tmpl" "opencode.jsonc" || true
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
  local dest="$OPENCODE_CONFIG_DIR/plugins/harness-second-brain.js"
  local src="$REPO_ROOT/configs/opencode/plugins/harness-second-brain.js"

  [[ -f "$src" ]] || return 0

  deploy_file "$src" "$dest" "configs/opencode/plugins/harness-second-brain.js" "false" "opencode second-brain plugin"
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
