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

export LOGOUT_LOG="$TMP_DIR/logouts"
: >"$LOGOUT_LOG"
cat >"$STUB_BIN/claude" <<'EOF'
#!/usr/bin/env bash
creds="$CLAUDE_CONFIG_DIR/.credentials.json"
if [[ "$1 $2" == "auth status" ]]; then
  [[ ! -f "$CLAUDE_CONFIG_DIR/.status-crashes" ]] || exit 3
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    echo '{"loggedIn": true, "authMethod": "api_key", "apiKeySource": "ANTHROPIC_API_KEY"}'
  elif [[ -f "$creds" ]]; then
    jq -c '{loggedIn: true, email: "work@example.com", authMethod: "claude.ai"} + .' "$creds"
  else
    echo '{"loggedIn": false, "authMethod": "none"}'
    exit 1
  fi
  exit 0
fi
if [[ "$1 $2" == "auth logout" ]]; then
  echo "$CLAUDE_CONFIG_DIR" >>"$LOGOUT_LOG"
  [[ ! -f "$CLAUDE_CONFIG_DIR/.logout-fails" ]] || exit 1
  rm -f "$creds"
  echo "Successfully logged out from your Anthropic account."
  exit 0
fi
echo "cfg=$CLAUDE_CONFIG_DIR profile=$CLAUDE_PROFILE args=$*"
EOF
chmod +x "$STUB_BIN/claude"
logged_out() { grep -qxF "$HOME/.claude-$1" "$LOGOUT_LOG"; }
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

echo "=== env: the variables a session needs to run as a profile ==="
assert "env prints the profile and its config dir" '[[ "$(bash "$TOOL" env work)" == "CLAUDE_PROFILE=work"$'"'"'\n'"'"'"CLAUDE_CONFIG_DIR=$P" ]]'
assert "env refuses a name that is not a profile" '! bash "$TOOL" env nosuch >/dev/null 2>&1'
assert "env refuses a missing name" '! bash "$TOOL" env >/dev/null 2>&1'

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
assert "wrong confirmation does not sign out" '! logged_out work'
out=$(printf 'work\n' | ANTHROPIC_API_KEY=sk-shell bash "$TOOL" remove work 2>&1)
assert "claude.ai sign-in is signed out before removal" 'logged_out work'
assert "removal reports the sign-out" 'grep -q "Signed out of profile work" <<<"$out"'
assert "logout output is not passed through" '! grep -q "Successfully logged out" <<<"$out"'
assert "profile dir removed" '[[ ! -e "$P" ]]'
assert "launcher removed" '[[ ! -e "$LAUNCHER" ]]'
assert "shared projects untouched" '[[ "$(cat "$HOME/.claude/projects/p1/s.jsonl")" == keep ]]'
assert "main settings untouched" '[[ -f "$HOME/.claude/settings.json" ]]'

echo "=== remove signs out only sign-ins stored in the profile ==="
signed_in() {
  printf 'n\n' | bash "$TOOL" "$1" >/dev/null 2>&1
  printf '%s\n' "$2" >"$HOME/.claude-$1/.credentials.json"
}
signed_in ownkey '{"authMethod": "api_key", "apiKeySource": "/login managed key"}'
out=$(printf 'ownkey\n' | bash "$TOOL" remove ownkey 2>&1)
assert "a key created by /login is signed out" 'logged_out ownkey'
assert "profile with its own key removed" '[[ ! -e "$HOME/.claude-ownkey" ]]'
signed_in shared '{"authMethod": "oauth_token"}'
out=$(printf 'shared\n' | bash "$TOOL" remove shared 2>&1)
assert "a sign-in shared outside the profile is left alone" '! logged_out shared'
assert "skipped sign-out is reported with its method" 'grep -q "shared.*oauth_token" <<<"$out"'
assert "profile with a shared sign-in still removed" '[[ ! -e "$HOME/.claude-shared" ]]'
printf 'n\n' | bash "$TOOL" nologin >/dev/null 2>&1
out=$(printf 'nologin\n' | bash "$TOOL" remove nologin 2>&1)
assert "signed-out profile needs no sign-out" '! logged_out nologin'
assert "signed-out profile removed without a warning" '[[ "$out" == *"Removed profile nologin"* && "$out" != *"claude-profile:"* ]]'
signed_in stuck '{}'
touch "$HOME/.claude-stuck/.logout-fails"
out=$(printf 'stuck\n' | bash "$TOOL" remove stuck 2>&1)
assert "failed sign-out is reported" 'grep -q "could not sign out of profile stuck" <<<"$out"'
assert "failed sign-out still removes the profile" '[[ ! -e "$HOME/.claude-stuck" && ! -e "$HOME/.local/bin/claude-stuck" ]]'
signed_in crashy '{}'
touch "$HOME/.claude-crashy/.status-crashes"
out=$(printf 'crashy\n' | bash "$TOOL" remove crashy 2>&1)
assert "unreadable sign-in is not signed out" '! logged_out crashy'
assert "unreadable sign-in is reported" 'grep -q "could not read how profile crashy signs in" <<<"$out"'
assert "unreadable sign-in still removes the profile" '[[ ! -e "$HOME/.claude-crashy" ]]'
printf 'n\n' | bash "$TOOL" nodir >/dev/null 2>&1
rm -rf "$HOME/.claude-nodir"
out=$(printf 'nodir\n' | bash "$TOOL" remove nodir 2>&1)
assert "launcher-only profile removed without calling claude" '! logged_out nodir && [[ ! -e "$HOME/.local/bin/claude-nodir" && ! -e "$HOME/.claude-nodir" ]]'
signed_in noclaude '{}'
mkdir -p "$TMP_DIR/jq-only"
ln -s "$(command -v jq)" "$TMP_DIR/jq-only/jq"
out=$(printf 'noclaude\n' | PATH="$TMP_DIR/jq-only:$HOME/.local/bin:/usr/bin:/bin" bash "$TOOL" remove noclaude 2>&1)
assert "missing claude is reported" 'grep -q "claude not found" <<<"$out"'
assert "missing claude still removes the profile" '[[ ! -e "$HOME/.claude-noclaude" ]]'

echo "=== remove --all ==="
printf 'n\n' | bash "$TOOL" third >/dev/null 2>&1
printf 'nope\n' | bash "$TOOL" remove --all >/dev/null 2>&1 || true
assert "wrong confirmation keeps every profile" '[[ -d "$HOME/.claude-alt" && -d "$HOME/.claude-third" ]]'
printf 'all\n' | bash "$TOOL" remove --all >/dev/null 2>&1
assert "confirmed remove --all deletes every profile" '[[ ! -e "$HOME/.claude-alt" && ! -e "$HOME/.claude-third" ]]'
assert "confirmed remove --all deletes launchers" '[[ ! -e "$HOME/.local/bin/claude-alt" && ! -e "$HOME/.local/bin/claude-third" ]]'
signed_in alt '{}'
out=$(bash "$TOOL" remove --all --yes </dev/null 2>&1)
assert "--yes signs out each profile" 'logged_out alt'
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
