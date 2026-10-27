#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

assert() {
    local name="$1"
    if eval "$2"; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s\n" "$name"
        FAIL=$((FAIL + 1))
    fi
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/tmpdir"
VAULT="$TMP_DIR/vault"
WORK_VAULT="$VAULT/Work/agent-wiki"

new_home() {
    local home="$1" tool
    mkdir -p "$home/.cursor" "$home/.local/bin"
    printf 'WIKI_VAULT=%s\n' "$VAULT" > "$home/.harness.env"
    for tool in cursor codex opencode sb cargo systemctl claude second-brain-mcp second-brain-api; do
        printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\n' "$tool" "$home" > "$home/.local/bin/$tool"
        chmod +x "$home/.local/bin/$tool"
    done
}

install_all() {
    local home="$1" module
    shift
    for module in claude cursor codex opencode; do
        harness "$home" "$@" --only "$module" > /dev/null || true
    done
}

harness() {
    local home="$1"
    shift
    local -a vars=()
    while [[ $# -gt 0 && "$1" == *=* && "$1" != --* ]]; do vars+=("$1"); shift; done
    env -u CLAUDE_PROFILE -u CLAUDE_CONFIG_DIR \
        HOME="$home" \
        XDG_CONFIG_HOME="$home/.config" \
        XDG_STATE_HOME="$home/.local/state" \
        HARNESS_ENV="$home/.harness.env" \
        HARNESS_MANIFEST="$home/manifest.json" \
        HARNESS_BACKUP_DIR="$home/backups" \
        TMPDIR="$TMP_DIR/tmpdir" \
        PATH="$home/.local/bin:$PATH" \
        "${vars[@]}" \
        bash "$REPO_ROOT/install.sh" --no-plugins "$@" 2>&1
}

echo ""
echo "=== a work install checks that no Claude config keeps second-brain ==="

C="$TMP_DIR/check"
mkdir -p "$C/.local/bin" "$C/.claude-x"
printf 'HARNESS_WORK=1\n' > "$C/.harness.env"
printf '#!/bin/sh\nexport CLAUDE_PROFILE=x\n' > "$C/.local/bin/claude-x"
printf '{"mcpServers": {"second-brain": {"command": "sb"}}}\n' > "$C/.claude-x/.claude.json"
check_work_mcp() {
    env -i HOME="$C" PATH="$PATH" HARNESS_ENV="$C/.harness.env" REPO_ROOT="$REPO_ROOT" DRY_RUN=false bash -c '
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/profile.sh"
        source "$REPO_ROOT/lib/claude_profiles.sh"
        claude_profiles_check_work_mcp' 2>&1
}
rc=0
out=$(check_work_mcp) || rc=$?
assert "a profile that still lists second-brain fails the check" '[ "$rc" -ne 0 ] && grep -qF "$C/.claude-x/.claude.json" <<<"$out"'
printf '{"mcpServers": {"web-strip": {"command": "node"}}}\n' > "$C/.claude-x/.claude.json"
printf '{"mcpServers": {"second-brain": {"command": "sb"}}}\n' > "$C/.claude.json"
rc=0
out=$(check_work_mcp) || rc=$?
assert "main's state that still lists second-brain fails the check" '[ "$rc" -ne 0 ] && grep -qF "$C/.claude.json" <<<"$out"'
printf '{"projects": {"/r": {"mcpServers": {"second-brain": {}}}}}\n' > "$C/.claude.json"
rc=0
check_work_mcp > /dev/null || rc=$?
assert "a project-scoped second-brain fails the check" '[ "$rc" -ne 0 ]'
printf '{not json\n' > "$C/.claude.json"
rc=0
out=$(check_work_mcp) || rc=$?
assert "an unreadable state file fails the check" '[ "$rc" -ne 0 ] && grep -q "could not read" <<<"$out"'
printf '{}\n' > "$C/.claude.json"
rc=0
check_work_mcp > /dev/null || rc=$?
assert "the check passes once every config is clean" '[ "$rc" -eq 0 ]'

echo ""
echo "=== personal install, then the machine switches to work ==="

H="$TMP_DIR/switch"
new_home "$H"
install_all "$H"
assert "personal install deploys the me skill" '[ -d "$H/.claude/skills/me" ]'
assert "personal install deploys the second-brain Cursor rule" '[ -f "$H/.cursor/rules/second-brain.mdc" ]'
assert "personal settings carry HARNESS_WORK=0" '[ "$(jq -r .env.HARNESS_WORK "$H/.claude/settings.json")" = "0" ]'
assert "personal settings carry the personal vault" '[ "$(jq -r .env.WIKI_VAULT "$H/.claude/settings.json")" = "$VAULT" ]'
assert "personal CLAUDE.md names the personal vault in the wiki rule" 'grep -qF "fall back to \`$VAULT\` only when" "$H/.claude/CLAUDE.md"'

MARK="# harness-managed MCP server (added by install.sh)"
printf '%s\n[mcp_servers.second-brain]\ncommand = "sb"\n\n[mcp_servers.second-brain.env]\nEXTRA = "1"\n%s\n[mcp_servers.web-strip]\ncommand = "ws"\n' \
  "$MARK" "$MARK" >"$H/.codex/config.toml"

printf 'HARNESS_WORK=1\n' >> "$H/.harness.env"
: > "$H/calls.log"
install_all "$H" HARNESS_WORK=0 WIKI_VAULT=/wrong
assert "work removes the me skill from Claude" '[ ! -e "$H/.claude/skills/me" ]'
assert "work removes the me skill from Cursor" '[ ! -e "$H/.cursor/skills/me" ]'
assert "work removes the me skill from ~/.agents" '[ ! -e "$H/.agents/skills/me" ]'
assert "work removes the second-brain Cursor rule" '[ ! -e "$H/.cursor/rules/second-brain.mdc" ]'
assert "work removes the llm-preference Cursor rule" '[ ! -e "$H/.cursor/rules/llm-preference.mdc" ]'
assert "work keeps other Cursor rules" '[ -f "$H/.cursor/rules/wiki-maintenance.mdc" ]'
assert "work CLAUDE.md drops the second-brain rule" '! grep -q "^## Second Brain (MCP)" "$H/.claude/CLAUDE.md"'
assert "work CLAUDE.md drops the LLM preference rule" '! grep -q "^## LLM Preference" "$H/.claude/CLAUDE.md"'
assert "work CLAUDE.md names the work vault" 'grep -qF "to \`$WORK_VAULT\` only when" "$H/.claude/CLAUDE.md"'
assert "work Cursor wiki rule names the work vault" 'grep -qF "$WORK_VAULT" "$H/.cursor/rules/wiki-maintenance.mdc"'
assert "work Codex instructions name the work vault" 'grep -qF "$WORK_VAULT" "$H/.codex/instructions.md"'
assert "work settings point WIKI_VAULT at the work vault, ignoring the exported value" \
  '[ "$(jq -r .env.WIKI_VAULT "$H/.claude/settings.json")" = "$WORK_VAULT" ]'
assert "work settings carry HARNESS_WORK=1, ignoring the exported value" \
  '[ "$(jq -r .env.HARNESS_WORK "$H/.claude/settings.json")" = "1" ]'
assert "work Claude .mcp.json has no second-brain" \
  '! jq -e ".mcpServers[\"second-brain\"]" "$H/.claude/.mcp.json" >/dev/null 2>&1'
assert "work settings enable no second-brain mcpjson server" \
  '! jq -e "(.enabledMcpjsonServers // []) | index(\"second-brain\")" "$H/.claude/settings.json" >/dev/null'
assert "work Cursor mcp.json has no second-brain" \
  '! jq -e ".mcpServers[\"second-brain\"]" "$H/.cursor/mcp.json" >/dev/null 2>&1'
assert "work Codex config has no second-brain server" '! grep -q "mcp_servers.second-brain" "$H/.codex/config.toml"'
assert "removing second-brain keeps the next block's marker" \
  'grep -B1 -xF "[mcp_servers.web-strip]" "$H/.codex/config.toml" | grep -qxF "$MARK"'
OC_CONFIG=$(ls "$H/.config/opencode/opencode.json"* 2>/dev/null | head -1)
assert "work opencode config has no second-brain server" '! grep -q "\"second-brain\"" "$OC_CONFIG"'
assert "work keeps the opencode capture plugin" '[ -f "$H/.config/opencode/plugins/harness-second-brain.js" ]'
assert "work removes the user-scope second-brain MCP from Claude" 'grep -q "claude mcp remove -s user second-brain" "$H/calls.log"'
assert "work never registers second-brain with Claude" '! grep -q "claude mcp add.*second-brain" "$H/calls.log"'

echo ""
echo "=== an exported HARNESS_WORK never makes a personal machine work ==="

P="$TMP_DIR/personal"
new_home "$P"
install_all "$P" HARNESS_WORK=1 WIKI_VAULT=/wrong
assert "exported HARNESS_WORK=1 leaves the me skill" '[ -d "$P/.claude/skills/me" ]'
assert "exported WIKI_VAULT is not baked into settings" '[ "$(jq -r .env.WIKI_VAULT "$P/.claude/settings.json")" = "$VAULT" ]'

echo ""
echo "=== no vault configured ==="

N="$TMP_DIR/novault"
new_home "$N"
: > "$N/.harness.env"
harness "$N" --only claude > "$TMP_DIR/novault.log" || true
assert "settings deploy without a vault and stay valid JSON" 'jq -e . "$N/.claude/settings.json" >/dev/null'
assert "settings without a vault carry no WIKI_VAULT key" '[ "$(jq -r ".env | has(\"WIKI_VAULT\")" "$N/.claude/settings.json")" = "false" ]'
assert "CLAUDE.md without a vault falls back to the variable name" 'grep -qF "to \`\$WIKI_VAULT\` only when" "$N/.claude/CLAUDE.md"'

echo ""
echo "work-mode: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
