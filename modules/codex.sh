#!/usr/bin/env bash

codex_check() {
    if [[ "$HAS_CODEX" != "true" ]]; then
        log_info "Codex not detected, skipping"
        log_info "  Install: npm install -g @openai/codex"
        return 1
    fi
    if [[ ! -d "$CODEX_CONFIG_DIR" ]]; then
        mkdir -p "$CODEX_CONFIG_DIR"
    fi
    return 0
}

codex_deploy_config() {
  local config_src="$REPO_ROOT/configs/codex/config.toml.tmpl"
  local instructions_src="$REPO_ROOT/configs/codex/instructions.md.tmpl"
  local hooks_src="$REPO_ROOT/configs/codex/hooks.json"

  if [[ -f "$config_src" ]] && ! head -1 "$config_src" | grep -q '^# harness does not manage'; then
    local dest="$CODEX_CONFIG_DIR/config.toml"
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would deploy codex config.toml"
    else
      [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"
      if deploy_template "$config_src" "$dest"; then
        manifest_add "$dest" "configs/codex/config.toml.tmpl" "true"
        log_success "codex config.toml deployed"
      else
        log_error "failed to deploy codex config.toml"
      fi
    fi
  fi

  if [[ -f "$instructions_src" ]]; then
    local dest="$CODEX_CONFIG_DIR/instructions.md"
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would deploy codex instructions.md"
    else
      [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"
      if deploy_template "$instructions_src" "$dest"; then
        manifest_add "$dest" "configs/codex/instructions.md.tmpl" "true"
        log_success "codex instructions.md deployed"
      else
        log_error "failed to deploy codex instructions.md"
      fi
    fi
  fi

  if [[ -f "$hooks_src" ]]; then
    local dest="$CODEX_CONFIG_DIR/hooks.json"
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] would deploy codex hooks.json"
    else
      [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"
      if deploy_template "$hooks_src" "$dest"; then
        manifest_add "$dest" "configs/codex/hooks.json" "true"
        log_success "codex hooks.json deployed"
      else
        log_error "failed to deploy codex hooks.json"
      fi
    fi
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would deploy codex hook scripts"
    return
  fi

  local codex_hooks_dir="$CODEX_CONFIG_DIR/hooks"
  mkdir -p "$codex_hooks_dir"

  local shared_hooks=("pre-bash-guard.sh" "format-on-save.sh" "pre-edit-comment-guard.py" "cost-guard.sh" "stop-sloppiness-guard.sh" \
    "session-start-wiki.sh" "session-end-ingest.sh" "load-harness-env.sh" "harness-project.sh" "detect-agent.sh")
  for hook in "${shared_hooks[@]}"; do
    local hook_src="$REPO_ROOT/configs/shared/hooks/$hook"
    local hook_dest="$codex_hooks_dir/$hook"
    if [[ -f "$hook_src" ]]; then
      cp "$hook_src" "$hook_dest"
      chmod +x "$hook_dest" 2>/dev/null || true
      manifest_add "$hook_dest" "configs/shared/hooks/$hook" "false"
      log_update "codex hook: $hook"
    fi
  done
}

# Merges harness-provided MCP servers (web-strip, markitdown, second-brain when
# installed) into ~/.codex/config.toml under [mcp_servers.*] without touching
# the rest of the file, which is machine-specific model/provider config the
# harness deliberately never manages as a whole. Only appends tables that
# aren't already present, so a user's own [mcp_servers.*] entries and any
# hand edits survive untouched. Deliberately not manifest-tracked, since the
# whole file isn't harness-owned: `install.sh uninstall` never touches
# config.toml at all, so these appended tables have no automatic cleanup path
# and must be removed by hand if a user wants them gone.
codex_mcp() {
  local dest="$CODEX_CONFIG_DIR/config.toml"

  declare -f second_brain_find_binaries >/dev/null 2>&1 || source "$REPO_ROOT/modules/second-brain.sh"
  second_brain_find_binaries
  local sb_mcp="$SB_MCP_BIN" sb_api="$SB_API_BIN"
  local web_strip_path="$HOME/.harness/tools/web-strip/index.js"

  local tmp_out
  tmp_out=$(mktemp)
  if ! python3 - "$dest" "$web_strip_path" "$sb_mcp" "$sb_api" "$tmp_out" <<'PYEOF'
import sys, tomllib

dest_path, web_strip_path, sb_mcp, sb_api, out_path = sys.argv[1:6]

def toml_str(s):
    # Minimal TOML basic-string escaper: backslash and double-quote are the
    # only characters that can appear in these values (filesystem paths) and
    # would otherwise break out of the quoted string.
    return s.replace("\\", "\\\\").replace('"', '\\"')

try:
    with open(dest_path, "rb") as f:
        raw = f.read()
except FileNotFoundError:
    raw = b""

try:
    data = tomllib.loads(raw.decode("utf-8")) if raw.strip() else {}
except tomllib.TOMLDecodeError as e:
    sys.stderr.write(f"{dest_path} is not valid TOML, refusing to merge MCP servers: {e}\n")
    sys.exit(1)

existing = set(data.get("mcp_servers", {}).keys())
blocks = []

if "web-strip" not in existing:
    blocks.append(
        '[mcp_servers.web-strip]\n'
        'command = "node"\n'
        f'args = ["{toml_str(web_strip_path)}"]\n'
    )

if "markitdown" not in existing:
    blocks.append(
        '[mcp_servers.markitdown]\n'
        'command = "uvx"\n'
        'args = ["markitdown-mcp"]\n'
    )

if sb_mcp and "second-brain" not in existing:
    env_line = 'env = { SECOND_BRAIN_API = "http://127.0.0.1:7200"'
    if sb_api:
        env_line += f', SECOND_BRAIN_DAEMON_BIN = "{toml_str(sb_api)}"'
    env_line += ' }\n'
    blocks.append(f'[mcp_servers.second-brain]\ncommand = "{toml_str(sb_mcp)}"\n{env_line}')

content = raw.decode("utf-8") if raw else ""
for block in blocks:
    if content and not content.endswith("\n"):
        content += "\n"
    if content:
        content += "\n"
    content += "# harness-managed MCP server (added by install.sh)\n" + block

if blocks:
    try:
        tomllib.loads(content)
    except tomllib.TOMLDecodeError as e:
        sys.stderr.write(f"generated MCP server TOML is invalid, refusing to write: {e}\n")
        sys.exit(1)

with open(out_path, "w") as f:
    f.write(content)
PYEOF
  then
    rm -f "$tmp_out"
    log_warn "codex MCP merge failed, config.toml left untouched"
    return
  fi

  if [[ -f "$dest" ]] && diff -q "$dest" "$tmp_out" >/dev/null 2>&1; then
    rm -f "$tmp_out"
    log_skip "codex MCP servers" "already registered"
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    rm -f "$tmp_out"
    log_info "[dry-run] would register MCP servers in $dest (web-strip, markitdown$( [[ -n "$sb_mcp" ]] && printf ', second-brain' ))"
    return
  fi

  mkdir -p "$(dirname "$dest")"
  [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"
  mv "$tmp_out" "$dest"
  log_success "codex MCP servers registered (web-strip, markitdown$( [[ -n "$sb_mcp" ]] && printf ', second-brain' ))"
}

codex_install() {
  codex_deploy_config
  codex_mcp
  # Codex reads user-level skills from ~/.agents/skills (per OpenAI docs), not ~/.codex/skills,
  # so shared skills and impeccable must land there to be discovered.
  deploy_shared_skills "$HOME/.agents/skills"
  deploy_impeccable_skill "codex" "$HOME/.agents/skills/impeccable"
}

codex_test() {
    local tmp_dir
    tmp_dir=$(mktemp -d)

    local orig_home="$HOME"
    local orig_config="${CODEX_CONFIG_DIR:-}"
    local orig_dry="$DRY_RUN"
    local orig_force="$FORCE"
    local orig_no_backup="$NO_BACKUP"

    export HOME="$tmp_dir"
    CODEX_CONFIG_DIR="$tmp_dir/.codex"
    DRY_RUN=true
    FORCE=true
    NO_BACKUP=true
    mkdir -p "$CODEX_CONFIG_DIR"

    local output
    output=$(codex_deploy_config 2>&1)
    output+=$'\n'
    output+=$(codex_mcp 2>&1)

    HOME="$orig_home"
    CODEX_CONFIG_DIR="$orig_config"
    DRY_RUN="$orig_dry"
    FORCE="$orig_force"
    NO_BACKUP="$orig_no_backup"
    rm -rf "$tmp_dir"

    if ! echo "$output" | grep -q '\[dry-run\]'; then
        log_error "codex_test: no dry-run output produced"
        return 1
    fi

    if ! echo "$output" | grep -q 'MCP servers'; then
        log_error "codex_test: codex_mcp produced no output"
        return 1
    fi

    return 0
}
