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
assert "a base URL leaves the profile personal: its vault is the personal vault" \
  '[ "$(jq -r .env.WIKI_VAULT "$A/settings.json")" = "$VAULT" ]'
assert "the base-URL profile's settings say HARNESS_WORK=0" '[ "$(jq -r .env.HARNESS_WORK "$A/settings.json")" = "0" ]'
assert "the base URL survives the overlay" '[ "$(jq -r .env.ANTHROPIC_BASE_URL "$A/settings.json")" = "https://gateway.example" ]'
assert "the base-URL profile keeps the me skill" '[ -e "$A/skills/me/SKILL.md" ]'
assert "the base-URL profile keeps second-brain" 'has_server "$A" second-brain && has_server "$A" web-strip'
assert "a profile without a spec stays linked to main" '[ -L "$H/.claude-mine/settings.json" ]'

printf '{"env": {"HARNESS_WORK": "1", "WIKI_VAULT": "/elsewhere"}}\n' >"$H/.config/harness/profiles/acme/settings.json"
harness "$H" --profile acme >/dev/null || true
assert "a spec cannot set HARNESS_WORK" '[ "$(jq -r .env.HARNESS_WORK "$A/settings.json")" = "0" ]'
assert "a spec cannot set WIKI_VAULT" '[ "$(jq -r .env.WIKI_VAULT "$A/settings.json")" = "$VAULT" ]'

printf 'work=on\n' >"$H/.config/harness/profiles/acme/profile.conf"
rc=0
out=$(harness "$H" --profile acme) || rc=$?
assert "work= in profile.conf stops the install" '[ "$rc" -ne 0 ]'
assert "work= in profile.conf names its replacement" 'grep -qF "work= was removed; HARNESS_WORK in ~/.harness.env decides for every profile" <<<"$out"'
rm -f "$H/.config/harness/profiles/acme/profile.conf"

echo ""
echo "=== profiles on a work machine ==="

W="$TMP_DIR/workmachine"
setup_home "$W"
printf 'HARNESS_WORK=1\n' >>"$W/.harness.env"
printf '{"mcpServers": {"web-strip": {"command": "node"}}}\n' >"$W/.claude.json"
harness "$W" --only claude >/dev/null
printf 'n\n' | profile_tool "$W" home >/dev/null
printf 'n\n' | profile_tool "$W" plain >/dev/null
printf 'n\n' | profile_tool "$W" sneaky >/dev/null
for p in home plain sneaky; do
  printf '{"mcpServers": {"web-strip": {"command": "node"}, "second-brain": {"command": "sb"}}}\n' >"$W/.claude-$p/.claude.json"
done
mkdir -p "$W/.config/harness/profiles/home" "$W/.config/harness/profiles/sneaky"
printf '{"env": {"ANTHROPIC_BASE_URL": "https://gateway.example"}}\n' >"$W/.config/harness/profiles/home/settings.json"
printf '{"env": {"HARNESS_WORK": "0", "WIKI_VAULT": "%s"}}\n' "$VAULT" >"$W/.config/harness/profiles/sneaky/settings.json"
harness "$W" --only claude >/dev/null || true
P="$W/.claude-home"
S="$W/.claude-sneaky"
assert "main on a work machine is work" '[ "$(jq -r .env.WIKI_VAULT "$W/.claude/settings.json")" = "$WORK_VAULT" ]'
assert "main on a work machine has no me skill" '[ ! -e "$W/.claude/skills/me" ]'
assert "a profile with a spec on a work machine gets the work vault" '[ "$(jq -r .env.WIKI_VAULT "$P/settings.json")" = "$WORK_VAULT" ]'
assert "a profile with a spec on a work machine says HARNESS_WORK=1" '[ "$(jq -r .env.HARNESS_WORK "$P/settings.json")" = "1" ]'
assert "a profile with a spec on a work machine has no me skill" '[ ! -e "$P/skills/me" ]'
assert "a profile with a spec on a work machine has no second-brain rule" '! grep -q "^## Second Brain (MCP)" "$P/CLAUDE.md"'
assert "a profile with a spec on a work machine loses second-brain" '! has_server "$P" second-brain && has_server "$P" web-strip'
assert "a spec cannot switch a work machine's profile back to HARNESS_WORK=0" '[ "$(jq -r .env.HARNESS_WORK "$S/settings.json")" = "1" ]'
assert "a spec cannot point a work machine's profile at the personal vault" '[ "$(jq -r .env.WIKI_VAULT "$S/settings.json")" = "$WORK_VAULT" ]'
assert "a profile without a spec on a work machine loses a second-brain it had" '! has_server "$W/.claude-plain" second-brain'
mv "$W/.claude.json" "$TMP_DIR/main-state.json"
printf '{"mcpServers": {"second-brain": {"command": "sb"}}}\n' >"$W/.claude-plain/.claude.json"
harness "$W" --profile plain >/dev/null || true
assert "a profile's MCP drop applies even when main has no .claude.json" '! has_server "$W/.claude-plain" second-brain'
mv "$TMP_DIR/main-state.json" "$W/.claude.json"

rm -rf "$W/.config/harness/profiles/home"
printf 'HARNESS_WORK=0\n' >>"$W/.harness.env"
harness "$W" --only claude >/dev/null || true
assert "switching the machine back to personal cleans the spec-less profile's drop" \
  '! grep -q "^drop-mcp second-brain" "$W/.claude-plain/.harness-owned" 2>/dev/null'

echo ""
printf 'profile-work: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
