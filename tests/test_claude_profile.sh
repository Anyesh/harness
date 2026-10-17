#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$REPO_ROOT/configs/claude-code/bin/claude-profile"

PASS=0
FAIL=0

assert() {
  local name="$1"
  local cmd="$2"
  if eval "$cmd"; then
    printf '  PASS  %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$name"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

export HOME="$TMP_DIR/home"
unset CLAUDE_CONFIG_DIR CLAUDE_PROFILE
STUB_BIN="$TMP_DIR/stub"
export PATH="$STUB_BIN:$HOME/.local/bin:$PATH"
mkdir -p "$STUB_BIN" "$HOME/.claude/hooks" "$HOME/.claude/skills/wiki" "$HOME/.claude/projects/p1" "$HOME/.claude/handoffs"
echo '{}' >"$HOME/.claude/settings.json"
echo '# rules' >"$HOME/.claude/CLAUDE.md"
echo 'keep' >"$HOME/.claude/projects/p1/s.jsonl"
cat >"$HOME/.claude.json" <<'EOF'
{"mcpServers": {"web-strip": {"command": "node"}, "second-brain": {"command": "sb"}}, "oauthAccount": {"emailAddress": "main@example.com"}}
EOF

cat >"$STUB_BIN/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "auth status" ]]; then
  if [[ -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]]; then
    echo '{"loggedIn": true, "email": "work@example.com"}'
  else
    echo '{"loggedIn": false}'
    exit 1
  fi
  exit 0
fi
echo "cfg=$CLAUDE_CONFIG_DIR profile=$CLAUDE_PROFILE args=$*"
EOF
chmod +x "$STUB_BIN/claude"
mkdir -p "$HOME/.local/bin"
cp "$TOOL" "$HOME/.local/bin/claude-profile"

P="$HOME/.claude-work"
LAUNCHER="$HOME/.local/bin/claude-work"

echo "=== create: prompts for a name, declines sign-in ==="
out=$(printf 'work\nn\n' | bash "$TOOL" 2>&1)
assert "profile dir created" '[[ -d "$P" ]]'
assert "settings.json linked to main" '[[ "$(readlink "$P/settings.json")" == "$HOME/.claude/settings.json" ]]'
assert "CLAUDE.md linked" '[[ -L "$P/CLAUDE.md" ]]'
assert "hooks dir linked" '[[ -L "$P/hooks" && -d "$P/skills/wiki" ]]'
assert "projects shared" '[[ "$(cat "$P/projects/p1/s.jsonl")" == keep ]]'
assert "entries missing from main are not linked" '[[ ! -e "$P/agents" && ! -L "$P/agents" ]]'
assert "handoffs are not linked, they live outside every profile" '[[ ! -e "$P/handoffs" && ! -L "$P/handoffs" ]]'
assert "mcp servers copied" '[[ "$(jq -r ".mcpServers|keys|join(\",\")" "$P/.claude.json")" == "second-brain,web-strip" ]]'
assert "main account not copied" '[[ "$(jq -r ".oauthAccount // \"none\"" "$P/.claude.json")" == none ]]'
assert "launcher is executable" '[[ -x "$LAUNCHER" ]]'
assert "launcher sets config dir and profile" '[[ "$(claude-work --version)" == "cfg=$P profile=work args=--version" ]]'
assert "declined sign-in does not call login" '! grep -q "args=auth login" <<<"$out"'
assert "signed-out profile reported once" '! grep -q unknown <<<"$out"'

echo "=== create: name argument, accepts sign-in ==="
out=$(printf 'y\n' | bash "$TOOL" alt 2>&1)
assert "sign-in runs auth login in the profile" 'grep -q "cfg=$HOME/.claude-alt profile=alt args=auth login" <<<"$out"'

echo "=== idempotent rerun keeps profile state ==="
echo '{}' >"$P/.credentials.json"
jq '.mcpServers.local = {"command": "x"}' "$P/.claude.json" >"$TMP_DIR/j" && mv "$TMP_DIR/j" "$P/.claude.json"
printf 'n\n' | bash "$TOOL" work >/dev/null 2>&1
assert "credentials survive rerun" '[[ -f "$P/.credentials.json" ]]'
assert "profile-only mcp server survives" '[[ "$(jq -r ".mcpServers.local.command" "$P/.claude.json")" == x ]]'

echo "=== sync relinks and merges ==="
mkdir -p "$HOME/.claude/agents"
jq '.mcpServers.markitdown = {"command": "uvx"}' "$HOME/.claude.json" >"$TMP_DIR/j" && mv "$TMP_DIR/j" "$HOME/.claude.json"
rm "$P/settings.json" && echo '{"own": true}' >"$P/settings.json"
out=$(bash "$TOOL" sync 2>&1)
assert "new main entry linked on sync" '[[ -L "$P/agents" ]]'
assert "new main mcp server merged on sync" '[[ "$(jq -r ".mcpServers.markitdown.command" "$P/.claude.json")" == uvx ]]'
assert "real file in profile not clobbered" '[[ ! -L "$P/settings.json" && "$(jq -r .own "$P/settings.json")" == true ]]'
assert "real file reported" 'grep -q "settings.json" <<<"$out"'

echo "=== list ==="
out=$(bash "$TOOL" list 2>&1)
assert "list shows signed-in account" 'grep -E "work.*work@example.com" <<<"$out" >/dev/null'
assert "list shows signed-out profile" 'grep -E "alt.*not signed in" <<<"$out" >/dev/null'
assert "the tool itself is not a profile" '! grep -q "^profile " <<<"$out"'
out=$(bash "$TOOL" sync 2>&1)
assert "sync does not treat the tool as a profile" '! grep -q "profile profile" <<<"$out"'

echo "=== refusals ==="
assert "invalid name rejected" '! bash "$TOOL" "Bad Name" </dev/null >/dev/null 2>&1'
assert "reserved name rejected" '! bash "$TOOL" profile </dev/null >/dev/null 2>&1'
printf '#!/bin/sh\necho mine\n' >"$HOME/.local/bin/claude-other"
chmod +x "$HOME/.local/bin/claude-other"
assert "foreign launcher refused" '! bash "$TOOL" other </dev/null >/dev/null 2>&1'
assert "foreign launcher untouched" '[[ "$(claude-other)" == mine ]]'
assert "no dir left for refused name" '[[ ! -e "$HOME/.claude-other" ]]'

echo "=== remove ==="
printf 'nope\n' | bash "$TOOL" remove work >/dev/null 2>&1 || true
assert "wrong confirmation keeps profile" '[[ -d "$P" && -x "$LAUNCHER" ]]'
printf 'work\n' | bash "$TOOL" remove work >/dev/null 2>&1
assert "profile dir removed" '[[ ! -e "$P" ]]'
assert "launcher removed" '[[ ! -e "$LAUNCHER" ]]'
assert "shared projects untouched" '[[ "$(cat "$HOME/.claude/projects/p1/s.jsonl")" == keep ]]'
assert "main settings untouched" '[[ -f "$HOME/.claude/settings.json" ]]'

echo "=== remove --all ==="
printf 'n\n' | bash "$TOOL" third >/dev/null 2>&1
printf 'nope\n' | bash "$TOOL" remove --all >/dev/null 2>&1 || true
assert "wrong confirmation keeps every profile" '[[ -d "$HOME/.claude-alt" && -d "$HOME/.claude-third" ]]'
printf 'all\n' | bash "$TOOL" remove --all >/dev/null 2>&1
assert "confirmed remove --all deletes every profile" '[[ ! -e "$HOME/.claude-alt" && ! -e "$HOME/.claude-third" ]]'
assert "confirmed remove --all deletes launchers" '[[ ! -e "$HOME/.local/bin/claude-alt" && ! -e "$HOME/.local/bin/claude-third" ]]'
printf 'n\n' | bash "$TOOL" alt >/dev/null 2>&1
out=$(bash "$TOOL" remove --all --yes </dev/null 2>&1)
assert "--yes removes without a prompt" '[[ ! -e "$HOME/.claude-alt" && ! -e "$HOME/.local/bin/claude-alt" ]]'
assert "--yes reports each profile" 'grep -q "Removed profile alt" <<<"$out"'
assert "foreign launcher survives remove --all" '[[ "$(claude-other)" == mine ]]'
assert "the tool survives remove --all" '[[ -x "$HOME/.local/bin/claude-profile" ]]'
assert "shared projects survive remove --all" '[[ "$(cat "$HOME/.claude/projects/p1/s.jsonl")" == keep ]]'
assert "remove --all with no profiles succeeds" 'bash "$TOOL" remove --all --yes </dev/null >/dev/null 2>&1'
assert "--yes needs --all" '! bash "$TOOL" remove alt --yes </dev/null >/dev/null 2>&1'

echo "=== harness uninstall removes profiles ==="
printf 'n\n' | bash "$TOOL" alt >/dev/null 2>&1
out=$(HARNESS_MANIFEST="$TMP_DIR/manifest.json" HARNESS_BACKUP_DIR="$TMP_DIR/backups" bash "$REPO_ROOT/install.sh" uninstall </dev/null 2>&1)
assert "uninstall deletes the profile dir" '[[ ! -e "$HOME/.claude-alt" ]]'
assert "uninstall deletes the launcher" '[[ ! -e "$HOME/.local/bin/claude-alt" ]]'
assert "uninstall logs the removed profile" 'grep -q "Removed profile alt" <<<"$out"'
assert "uninstall leaves foreign launchers" '[[ "$(claude-other)" == mine ]]'
mv "$HOME/.local/bin/claude-profile" "$TMP_DIR/claude-profile.bak"
assert "uninstall without the tool succeeds" 'HARNESS_MANIFEST="$TMP_DIR/manifest.json" HARNESS_BACKUP_DIR="$TMP_DIR/backups" bash "$REPO_ROOT/install.sh" uninstall </dev/null >/dev/null 2>&1'
mv "$TMP_DIR/claude-profile.bak" "$HOME/.local/bin/claude-profile"

echo "=== install from inside a profile targets ~/.claude ==="
detected() { CLAUDE_PROFILE=work CLAUDE_CONFIG_DIR="$P" bash -c "source '$REPO_ROOT/lib/detect.sh'; $1"; }
assert "detect ignores the profile config dir" '[[ "$(detected "echo \$CLAUDE_CONFIG_DIR")" == "$HOME/.claude" ]]'
assert "detect stops exporting the config dir" '[[ -z "$(detected "printenv CLAUDE_CONFIG_DIR || true")" ]]'
assert "detect keeps an explicit dir outside profiles" '[[ "$(CLAUDE_CONFIG_DIR=/x bash -c "source $REPO_ROOT/lib/detect.sh; echo \$CLAUDE_CONFIG_DIR")" == /x ]]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
