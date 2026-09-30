#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

assert() {
    local name="$1"
    TOTAL=$((TOTAL + 1))
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

MEMORY_HOOK_NAMES=(session-start-wiki.sh wiki-nudge.sh stop-wiki-enforce.sh session-end-ingest.sh)
MEMORY_COMMAND_NAMES=(devlog plan decision)

# Args: fake home, "vault" to write WIKI_VAULT to ~/.harness.env. Every mock
# appends its argv to $home/calls.log so tests can assert what never ran.
new_home() {
    local home="$1" with_vault="${2:-}"
    mkdir -p "$home/.cursor" "$home/.local/bin"
    : > "$home/.harness.env"
    [[ "$with_vault" == "vault" ]] && printf 'WIKI_VAULT=%s/vault\n' "$TMP_DIR" > "$home/.harness.env"
    local tool
    for tool in cursor codex opencode sb cargo systemctl claude; do
        printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\n' "$tool" "$home" > "$home/.local/bin/$tool"
        chmod +x "$home/.local/bin/$tool"
    done
}

add_fake_second_brain() {
    local home="$1" tool
    for tool in second-brain-mcp second-brain-api; do
        printf '#!/bin/sh\nexit 0\n' > "$home/.local/bin/$tool"
        chmod +x "$home/.local/bin/$tool"
    done
}

harness() {
    local home="$1"
    shift
    HOME="$home" \
    XDG_CONFIG_HOME="$home/.config" \
    HARNESS_ENV="$home/.harness.env" \
    HARNESS_MANIFEST="$home/manifest.json" \
    HARNESS_BACKUP_DIR="$home/backups" \
    TMPDIR="$TMP_DIR/tmpdir" \
    PATH="$home/.local/bin:$PATH" \
    bash "$REPO_ROOT/install.sh" "$@" 2>&1
}

install_all() {
    local home="$1"
    shift
    local module
    for module in claude cursor codex opencode; do
        harness "$home" --only "$module" --no-plugins "$@" > /dev/null
    done
}

calls() { cat "$1/calls.log" 2>/dev/null || true; }

echo ""
echo "=== lite install via --no-memory flag (full module run) ==="
echo ""

LH="$TMP_DIR/lite"
new_home "$LH"
add_fake_second_brain "$LH"
lite_out=$(harness "$LH" --no-plugins --no-memory) || true

assert "lite: cargo never called" '! grep -q "^cargo" <<<"$(calls "$LH")"'
assert "lite: systemctl never called" '! grep -q "^systemctl" <<<"$(calls "$LH")"'
assert "lite: claude mcp add never registers second-brain" '! grep -q "mcp add.*second-brain" <<<"$(calls "$LH")"'
assert "lite: no second-brain service file" '[[ ! -e "$LH/.config/systemd/user/second-brain.service" ]]'
assert "lite: no vault created" '[[ ! -e "$LH/Obsidian" && ! -e "$TMP_DIR/vault" ]]'
assert "lite: output has no second-brain or wiki module sections" '! grep -qE "Module: (second-brain|wiki)" <<<"$lite_out"'
assert "lite: harness env gained no WIKI_VAULT" '! grep -q WIKI_VAULT "$LH/.harness.env"'

hooks_ok=true
for h in "${MEMORY_HOOK_NAMES[@]}"; do
    [[ -e "$LH/.claude/hooks/$h" || -e "$LH/.cursor/hooks/$h" || -e "$LH/.codex/hooks/$h" ]] && hooks_ok=false
done
assert "lite: none of the four memory hooks deployed to claude, cursor or codex" '[[ "$hooks_ok" == true ]]'
assert "lite: session-start-handoff.sh still deployed" '[[ -x "$LH/.claude/hooks/session-start-handoff.sh" ]]'
assert "lite: pre-bash-interactive-alias.sh still deployed" '[[ -x "$LH/.claude/hooks/pre-bash-interactive-alias.sh" ]]'

S="$LH/.claude/settings.json"
assert "lite: settings.json is valid JSON" 'jq -e . "$S" > /dev/null'
assert "lite: settings.json names no memory hook" '! grep -qE "session-start-wiki|wiki-nudge|stop-wiki-enforce|session-end-ingest" "$S"'
assert "lite: settings.json has no WIKI_VAULT" '! grep -q WIKI_VAULT "$S"'
assert "lite: enabledMcpjsonServers lacks second-brain but keeps web-strip" 'jq -e "(.enabledMcpjsonServers | index(\"second-brain\")) == null and (.enabledMcpjsonServers | index(\"web-strip\")) != null" "$S" > /dev/null'
assert "lite: handoff and alias hooks still registered" 'grep -q session-start-handoff "$S" && grep -q pre-bash-interactive-alias "$S"'
assert "lite: no emptied hook groups or events" 'jq -e "([.hooks[] | select(length == 0)] | length) == 0 and ([.hooks[][] | select((.hooks | length) == 0)] | length) == 0" "$S" > /dev/null'
assert "lite: SessionEnd event dropped entirely" 'jq -e ".hooks | has(\"SessionEnd\") | not" "$S" > /dev/null'
assert "lite: permissions arrays survive" 'jq -e ".permissions.allow == [] and .permissions.deny == []" "$S" > /dev/null'
assert "lite: .mcp.json valid and lacks second-brain" 'jq -e "(.mcpServers | has(\"second-brain\") | not) and (.mcpServers | has(\"web-strip\"))" "$LH/.claude/.mcp.json" > /dev/null'

CM="$LH/.claude/CLAUDE.md"
assert "lite: CLAUDE.md has no wiki skill block" '! grep -q "^# wiki" "$CM" && ! grep -q "skills/wiki/SKILL.md" "$CM"'
assert "lite: CLAUDE.md has no marker left" '! grep -q "MEMORY_" "$CM"'
assert "lite: CLAUDE.md lacks the second-brain rule" '! grep -q "^## Second Brain (MCP)" "$CM"'
assert "lite: CLAUDE.md lacks the wiki-maintenance rule" '! grep -q "^## Wiki Maintenance" "$CM"'
assert "lite: CLAUDE.md keeps other rules and skills" 'grep -q "^# ownit" "$CM" && grep -q "^## Scope Gate" "$CM"'
assert "lite: no wiki skill in claude or agents dirs" '[[ ! -e "$LH/.claude/skills/wiki" && ! -e "$LH/.agents/skills/wiki" && ! -e "$LH/.cursor/skills/wiki" ]]'

cmds_ok=true
for c in "${MEMORY_COMMAND_NAMES[@]}"; do
    for d in "$LH/.claude/commands" "$LH/.cursor/commands" "$LH/.config/opencode/commands"; do
        [[ -e "$d/$c.md" ]] && cmds_ok=false
    done
done
assert "lite: devlog, plan and decision commands absent everywhere" '[[ "$cmds_ok" == true ]]'
assert "lite: scope, orchestrate and commit commands present" '[[ -f "$LH/.claude/commands/scope.md" && -f "$LH/.claude/commands/orchestrate.md" && -f "$LH/.claude/commands/commit.md" ]]'

rules_ok=true
for r in second-brain wiki-maintenance; do
    [[ -e "$LH/.cursor/rules/$r.mdc" ]] && rules_ok=false
done
assert "lite: cursor rules lack the two memory rules" '[[ "$rules_ok" == true && -f "$LH/.cursor/rules/core.mdc" ]]'

H="$LH/.cursor/hooks.json"
assert "lite: cursor hooks.json valid, no memory hooks, no empty events" 'jq -e . "$H" > /dev/null && ! grep -qE "session-start-wiki|wiki-nudge|stop-wiki-enforce|session-end-ingest" "$H" && jq -e "[.hooks[] | select(length == 0)] | length == 0" "$H" > /dev/null'
assert "lite: cursor hooks.json keeps non-memory hooks" 'grep -q cleanup-nudge "$H" && grep -q "session-start.sh" "$H"'
assert "lite: cursor mcp.json lacks second-brain" 'jq -e "(.mcpServers | has(\"second-brain\") | not) and (.mcpServers | has(\"web-strip\"))" "$LH/.cursor/mcp.json" > /dev/null'

CH="$LH/.codex/hooks.json"
assert "lite: codex hooks.json valid, no memory hooks, no empty groups" 'jq -e . "$CH" > /dev/null && ! grep -qE "session-start-wiki|session-end-ingest" "$CH" && jq -e "([.hooks[][] | select((.hooks | length) == 0)] | length) == 0 and ([.hooks[] | select(length == 0)] | length) == 0" "$CH" > /dev/null'
assert "lite: codex hooks.json keeps pre-bash-guard" 'grep -q pre-bash-guard "$CH"'
assert "lite: codex config.toml has no second-brain block despite binaries" '! grep -q "second-brain" "$LH/.codex/config.toml" && grep -q "mcp_servers.web-strip" "$LH/.codex/config.toml"'
assert "lite: opencode has no second-brain plugin" '[[ ! -e "$LH/.config/opencode/plugins/harness-second-brain.js" ]]'
assert "lite: opencode MCP fragment has no second-brain despite binaries" '! grep -q "second-brain" "$LH/.config/opencode/opencode.json" && grep -q web-strip "$LH/.config/opencode/opencode.json"'

lite_status=$(harness "$LH" status) || true
assert "lite: status is clean" '! grep -qE "DIRTY|MISSING|ORPHAN" <<<"$lite_status"'
lite_again=$(harness "$LH" --no-plugins --no-memory) || true
assert "lite: second run redeploys nothing" '! grep -qE "installed:|updated:" <<<"$lite_again"'

echo ""
echo "=== control: full install keeps every memory piece ==="
echo ""

FH="$TMP_DIR/full"
new_home "$FH" vault
add_fake_second_brain "$FH"
harness "$FH" --no-plugins > /dev/null || true

assert "control: memory hooks deployed" '[[ -x "$FH/.claude/hooks/wiki-nudge.sh" && -x "$FH/.claude/hooks/stop-wiki-enforce.sh" && -x "$FH/.claude/hooks/session-end-ingest.sh" && -x "$FH/.claude/hooks/session-start-wiki.sh" ]]'
assert "control: settings.json registers memory hooks and WIKI_VAULT" 'grep -q wiki-nudge "$FH/.claude/settings.json" && grep -q "WIKI_VAULT\": \"$TMP_DIR/vault\"" "$FH/.claude/settings.json"'
assert "control: enabledMcpjsonServers has second-brain" 'jq -e ".enabledMcpjsonServers | index(\"second-brain\") != null" "$FH/.claude/settings.json" > /dev/null'
assert "control: .mcp.json, cursor mcp.json have second-brain" 'jq -e ".mcpServers | has(\"second-brain\")" "$FH/.claude/.mcp.json" > /dev/null && jq -e ".mcpServers | has(\"second-brain\")" "$FH/.cursor/mcp.json" > /dev/null'
assert "control: CLAUDE.md has wiki block and both rules" 'grep -q "^# wiki" "$FH/.claude/CLAUDE.md" && grep -q "^## Second Brain (MCP)" "$FH/.claude/CLAUDE.md" && grep -q "^## Wiki Maintenance" "$FH/.claude/CLAUDE.md"'
assert "control: wiki skill and memory commands deployed" '[[ -d "$FH/.claude/skills/wiki" && -f "$FH/.claude/commands/devlog.md" && -f "$FH/.claude/commands/plan.md" && -f "$FH/.claude/commands/decision.md" ]]'
assert "control: cursor rules and hooks carry memory" '[[ -f "$FH/.cursor/rules/second-brain.mdc" && -f "$FH/.cursor/rules/wiki-maintenance.mdc" ]] && grep -q wiki-nudge "$FH/.cursor/hooks.json"'
assert "control: codex hooks and scripts carry memory" 'grep -q session-start-wiki "$FH/.codex/hooks.json" && [[ -x "$FH/.codex/hooks/session-start-wiki.sh" ]]'
assert "control: codex and opencode register second-brain" 'grep -q "mcp_servers.second-brain" "$FH/.codex/config.toml" && grep -q second-brain "$FH/.config/opencode/opencode.json" && [[ -f "$FH/.config/opencode/plugins/harness-second-brain.js" ]]'
assert "control: second-brain daemon path ran" 'grep -q "^systemctl" <<<"$(calls "$FH")"'

echo ""
echo "=== default output identity ==="
echo ""

assert "identity: CLAUDE.md has no blank line opening the ownit-to-wiki block seam" '! grep -B1 "^# wiki" "$FH/.claude/CLAUDE.md" | head -1 | grep -q "^$"'
assert "identity: CLAUDE.md has no marker text" '! grep -q "MEMORY_" "$FH/.claude/CLAUDE.md"'
ident_ok=true
for pair in "claude-code/settings.json.tmpl:$FH/.claude/settings.json" "claude-code/.mcp.json.tmpl:$FH/.claude/.mcp.json" "codex/hooks.json:$FH/.codex/hooks.json"; do
    tmpl="$REPO_ROOT/configs/${pair%%:*}" out="${pair#*:}"
    want=$(sed -e "s#{{HOME_DIR}}#$FH#g" -e "s#{{WIKI_VAULT}}#$TMP_DIR/vault#g" "$tmpl" | jq -S -c .)
    got=$(jq -S -c . "$out")
    [[ "$want" == "$got" ]] || { echo "    differs: $out"; ident_ok=false; }
done
cmp -s "$REPO_ROOT/configs/cursor/hooks.json" "$FH/.cursor/hooks.json" || ident_ok=false
assert "identity: default JSON equals its template with placeholders substituted" '[[ "$ident_ok" == true ]]'

echo ""
echo "=== env form, dry run, validate, misuse ==="
echo ""

EH="$TMP_DIR/envhome"
new_home "$EH"
HARNESS_NO_MEMORY=1 harness "$EH" --no-plugins > /dev/null || true
assert "env: HARNESS_NO_MEMORY=1 behaves like the flag" '[[ ! -e "$EH/.claude/hooks/wiki-nudge.sh" && ! -e "$EH/.claude/skills/wiki" ]] && ! grep -q "^cargo" <<<"$(calls "$EH")" && jq -e "(.enabledMcpjsonServers | index(\"second-brain\")) == null" "$EH/.claude/settings.json" > /dev/null'

DH="$TMP_DIR/dryhome"
new_home "$DH"
dry_rc=0
dry_out=$(harness "$DH" --no-plugins --dry-run --no-memory) || dry_rc=$?
assert "dry-run: --dry-run --no-memory succeeds and writes no claude config" '[[ $dry_rc -eq 0 && ! -e "$DH/.claude/settings.json" ]]'
assert "dry-run: output mentions no second-brain install" '! grep -qE "would install second-brain|second-brain daemon" <<<"$dry_out"'

val_rc=0
harness "$LH" validate --no-memory > /dev/null || val_rc=$?
assert "validate: succeeds with --no-memory" '[[ $val_rc -eq 0 ]]'

for mod in second-brain wiki; do
    misuse_rc=0
    misuse=$(harness "$LH" --only "$mod" --no-memory) || misuse_rc=$?
    assert "misuse: --only $mod --no-memory dies with a message" '[[ $misuse_rc -ne 0 ]] && grep -qi "no-memory" <<<"$misuse"'
done

echo ""
echo "=== switching profiles in one HOME ==="
echo ""

UH="$TMP_DIR/switchup"
new_home "$UH" vault
add_fake_second_brain "$UH"
install_all "$UH" --no-memory
assert "switch: lite first has no wiki skill or memory hook" '[[ ! -e "$UH/.claude/skills/wiki" && ! -e "$UH/.claude/hooks/wiki-nudge.sh" ]]'
install_all "$UH"
assert "switch: lite then full gains the memory pieces" '[[ -d "$UH/.claude/skills/wiki" && -x "$UH/.claude/hooks/wiki-nudge.sh" && -f "$UH/.claude/commands/devlog.md" ]] && grep -q wiki-nudge "$UH/.claude/settings.json" && grep -q "^# wiki" "$UH/.claude/CLAUDE.md"'

DNH="$TMP_DIR/switchdown"
new_home "$DNH" vault
install_all "$DNH"
install_all "$DNH" --no-memory
down_status=$(harness "$DNH" status) || true
assert "switch: full then lite leaves status clean" '! grep -qE "DIRTY|MISSING|ORPHAN" <<<"$down_status"'

echo ""
echo "No-memory: $TOTAL total, $PASS passed, $FAIL failed"

[[ $FAIL -eq 0 ]]
