#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$REPO_ROOT/configs/claude-code/bin/claude-profile"

PASS=0
FAIL=0

assert() {
  local name="$1"
  if eval "$2"; then
    printf '  PASS  %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$name"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/tmpdir"
unset CLAUDE_CONFIG_DIR CLAUDE_PROFILE HARNESS_WORK WIKI_VAULT
VAULT="$TMP_DIR/vault"
WORK_VAULT="$VAULT/Work/agent-wiki"

setup_home() {
  local h="$1" tool
  mkdir -p "$h/.cursor" "$h/.local/bin"
  printf 'WIKI_VAULT=%s\n' "$VAULT" >"$h/.harness.env"
  for tool in cursor codex opencode sb cargo systemctl claude; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\n' "$tool" "$h" >"$h/.local/bin/$tool"
    chmod +x "$h/.local/bin/$tool"
  done
  printf '#!/bin/sh\nexit 0\n' >"$h/.local/bin/second-brain-mcp"
  printf '#!/bin/sh\nexit 0\n' >"$h/.local/bin/second-brain-api"
  chmod +x "$h/.local/bin/second-brain-mcp" "$h/.local/bin/second-brain-api"
}

harness() {
  local h="$1"
  shift
  HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_STATE_HOME="$h/.local/state" \
    HARNESS_ENV="$h/.harness.env" HARNESS_MANIFEST="$h/manifest.json" HARNESS_BACKUP_DIR="$h/backups" \
    TMPDIR="$TMP_DIR/tmpdir" PATH="$h/.local/bin:$PATH" \
    bash "$REPO_ROOT/install.sh" --no-plugins "$@" 2>&1
}

profile_tool() {
  local h="$1"
  shift
  HOME="$h" XDG_CONFIG_HOME="$h/.config" PATH="$h/.local/bin:$PATH" bash "$TOOL" "$@" 2>&1
}

has_server() { jq -e --arg s "$2" '.mcpServers[$s]' "$1/.claude.json" >/dev/null 2>&1; }

echo ""
echo "=== base-URL profile on a personal machine ==="

H="$TMP_DIR/personal"
setup_home "$H"
printf '{"mcpServers": {"web-strip": {"command": "node"}, "second-brain": {"command": "sb"}}}\n' >"$H/.claude.json"
harness "$H" --only claude >/dev/null
printf 'n\n' | profile_tool "$H" acme >/dev/null
printf 'n\n' | profile_tool "$H" mine >/dev/null
mkdir -p "$H/.config/harness/profiles/acme"
printf '{"env": {"ANTHROPIC_BASE_URL": "https://gateway.example"}}\n' >"$H/.config/harness/profiles/acme/settings.json"
harness "$H" --profile acme >/dev/null || true
A="$H/.claude-acme"
assert "a base URL makes the profile work: its vault is the work vault" \
  '[ "$(jq -r .env.WIKI_VAULT "$A/settings.json")" = "$WORK_VAULT" ]'
assert "the work profile's settings say HARNESS_WORK=1" '[ "$(jq -r .env.HARNESS_WORK "$A/settings.json")" = "1" ]'
assert "the base URL survives the overlay" '[ "$(jq -r .env.ANTHROPIC_BASE_URL "$A/settings.json")" = "https://gateway.example" ]'
assert "the work profile owns its CLAUDE.md, without the second-brain rule" \
  '[ ! -L "$A/CLAUDE.md" ] && ! grep -q "^## Second Brain (MCP)" "$A/CLAUDE.md"'
assert "the work profile's CLAUDE.md names the work vault" 'grep -qF "$WORK_VAULT" "$A/CLAUDE.md"'
assert "the work profile's skills have no me" '[ -d "$A/skills" ] && [ ! -L "$A/skills" ] && [ ! -e "$A/skills/me" ]'
assert "the work profile keeps other skills" '[ -e "$A/skills/wiki" ]'
assert "the work profile drops second-brain from its MCP servers" '! has_server "$A" second-brain && has_server "$A" web-strip'
assert "main is untouched by the work profile" \
  '[ "$(jq -r .env.WIKI_VAULT "$H/.claude/settings.json")" = "$VAULT" ] && [ -e "$H/.claude/skills/me" ]'
assert "a profile without a spec stays linked to main" '[ -L "$H/.claude-mine/settings.json" ]'
assert "names --work on lists the base-URL profile" '[ "$(profile_tool "$H" names --work on)" = "acme" ]'
assert "names --work off lists the personal profile" '[ "$(profile_tool "$H" names --work off)" = "mine" ]'

cp "$H/.harness.env" "$TMP_DIR/personal.env"
printf 'HARNESS_WORK=1\n' >>"$H/.harness.env"
harness "$H" --profile mine >/dev/null || true
assert "a profile-only install follows main's deployed state, not a flag main has not picked up" \
  '! grep -qx "work on" "$H/.claude-mine/.harness-owned" 2>/dev/null && has_server "$H/.claude-mine" second-brain'
cp "$TMP_DIR/personal.env" "$H/.harness.env"

printf 'work=off\n' >"$H/.config/harness/profiles/acme/profile.conf"
harness "$H" --profile acme >/dev/null || true
assert "work=off overrides the base URL" '[ "$(jq -r .env.WIKI_VAULT "$A/settings.json")" = "$VAULT" ]'

echo ""
echo "=== personal profile on a work machine ==="

W="$TMP_DIR/workmachine"
setup_home "$W"
printf 'HARNESS_WORK=1\n' >>"$W/.harness.env"
printf '{"mcpServers": {"web-strip": {"command": "node"}}}\n' >"$W/.claude.json"
harness "$W" --only claude >/dev/null
printf 'n\n' | profile_tool "$W" home >/dev/null
printf 'n\n' | profile_tool "$W" plain >/dev/null
printf '{"mcpServers": {"web-strip": {"command": "node"}, "second-brain": {"command": "sb"}}}\n' >"$W/.claude-plain/.claude.json"
mkdir -p "$W/.config/harness/profiles/home"
printf 'work=off\n' >"$W/.config/harness/profiles/home/profile.conf"
harness "$W" --only claude >/dev/null || true
P="$W/.claude-home"
assert "main on a work machine is work" '[ "$(jq -r .env.WIKI_VAULT "$W/.claude/settings.json")" = "$WORK_VAULT" ]'
assert "the work=off profile gets the personal vault" '[ "$(jq -r .env.WIKI_VAULT "$P/settings.json")" = "$VAULT" ]'
assert "the work=off profile says HARNESS_WORK=0" '[ "$(jq -r .env.HARNESS_WORK "$P/settings.json")" = "0" ]'
assert "the work=off profile gets the second-brain rule back" 'grep -q "^## Second Brain (MCP)" "$P/CLAUDE.md"'
assert "the work=off profile gets the me skill back" '[ -e "$P/skills/me/SKILL.md" ]'
assert "the work=off profile gets second-brain in its own MCP servers" 'has_server "$P" second-brain'
assert "main on a work machine has no me skill" '[ ! -e "$W/.claude/skills/me" ]'
assert "a profile without a spec on a work machine loses a second-brain it had" '! has_server "$W/.claude-plain" second-brain'
assert "names --work on lists the spec-less profile on a work machine" '[ "$(profile_tool "$W" names --work on)" = "plain" ]'

rm -rf "$W/.config/harness/profiles/home"
printf 'HARNESS_WORK=0\n' >>"$W/.harness.env"
harness "$W" --only claude >/dev/null || true
assert "switching the machine back to personal cleans the spec-less profile's drop" \
  '! grep -q "^drop-mcp second-brain" "$W/.claude-plain/.harness-owned" 2>/dev/null'

echo ""
printf 'profile-work: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
