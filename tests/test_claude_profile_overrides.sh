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
unset CLAUDE_CONFIG_DIR CLAUDE_PROFILE

H="$TMP_DIR/home"
MAIN="$H/.claude"
SPECS="$H/.config/harness/profiles"
mkdir -p "$H/.cursor" "$H/.local/bin"
printf 'WIKI_VAULT=%s/vault\n' "$TMP_DIR" >"$H/.harness.env"
for tool in cursor codex opencode sb cargo systemctl claude; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\n' "$tool" "$H" >"$H/.local/bin/$tool"
  chmod +x "$H/.local/bin/$tool"
done
cat >"$H/.claude.json" <<'EOF'
{"mcpServers": {"web-strip": {"command": "node"}, "second-brain": {"command": "sb"}}}
EOF

harness() {
  HOME="$H" \
    XDG_CONFIG_HOME="$H/.config" \
    HARNESS_ENV="$H/.harness.env" \
    HARNESS_MANIFEST="$H/manifest.json" \
    HARNESS_BACKUP_DIR="$H/backups" \
    TMPDIR="$TMP_DIR/tmpdir" \
    PATH="$H/.local/bin:$PATH" \
    bash "$REPO_ROOT/install.sh" "$@" 2>&1
}

profile_tool() {
  HOME="$H" XDG_CONFIG_HOME="$H/.config" PATH="$H/.local/bin:$PATH" bash "$TOOL" "$@" 2>&1
}

main_snapshot() {
  (
    cd "$H"
    sha256sum .claude/settings.json .claude/CLAUDE.md manifest.json
    find .claude/skills .claude/commands .harness-merge-base -printf '%P %y %l\n' | sort
  )
}

tree_snapshot() {
  (
    cd "$1"
    find . -printf '%P %y %l\n' | sort
    find . -type f -exec sha256sum {} + | sort
  )
}

is_link_to_main() { [[ -L "$1/$2" && "$(readlink "$1/$2")" == "$MAIN/$2" ]]; }

echo "=== overlay merge ==="
overlay_out=$(jq -c --slurpfile overlay <(echo '{"a":{"c":[3],"e":{"x":null,"y":2}},"d":null}') \
  -f "$REPO_ROOT/lib/profile_overlay.jq" <<<'{"a":{"b":1,"c":[1,2]},"d":1}')
assert "objects merge, arrays replace, null deletes" \
  '[[ "$overlay_out" == "{\"a\":{\"b\":1,\"c\":[3],\"e\":{\"y\":2}}}" ]]'

echo "=== main install, then profiles ==="
harness --only claude --no-plugins >/dev/null
jq '.model = "main-model" | .fastMode = true' "$MAIN/settings.json" >"$TMP_DIR/s" && cat "$TMP_DIR/s" >"$MAIN/settings.json"
printf 'n\n' | profile_tool work >/dev/null
printf 'n\n' | profile_tool plain >/dev/null
printf 'n\n' | profile_tool lite >/dev/null
W="$H/.claude-work"
assert "precondition: main settings carry memory hooks" 'grep -q stop-wiki-enforce.sh "$MAIN/settings.json"'
assert "precondition: new profile links settings to main" 'is_link_to_main "$W" settings.json'

mkdir -p "$SPECS/work/rules" "$SPECS/work/skills/team-only" "$SPECS/work/commands"
cat >"$SPECS/work/profile.conf" <<'EOF'
# work account
skills_exclude = humanize, deslop
rules_exclude=python
EOF
echo '{"model": "profile-model", "fastMode": null, "permissions": {"allow": ["Read"]}}' >"$SPECS/work/settings.json"
printf -- '---\ndescription: team rule\n---\n\nPROFILE-RULE-MARKER\n' >"$SPECS/work/rules/team.mdc"
echo 'team skill' >"$SPECS/work/skills/team-only/SKILL.md"
echo 'hello' >"$SPECS/work/commands/hello.md"

before=$(main_snapshot)
out=$(harness --profile work) || true
assert "--profile leaves main settings, CLAUDE.md, skills, manifest and merge bases alone" '[[ "$(main_snapshot)" == "$before" ]]'

echo "=== owned settings.json ==="
assert "settings.json is the profile's own file" '[[ -f "$W/settings.json" && ! -L "$W/settings.json" ]]'
assert "overlay value wins over main's /config edit" '[[ "$(jq -r .model "$W/settings.json")" == profile-model ]]'
assert "null in overlay deletes the key" '! jq -e "has(\"fastMode\")" "$W/settings.json" >/dev/null'
assert "overlay array replaces main's" '[[ "$(jq -c .permissions.allow "$W/settings.json")" == "[\"Read\"]" ]]'
assert "main hooks are still wired" 'grep -q "$MAIN/hooks/cost-guard.sh" "$W/settings.json"'

echo "=== owned CLAUDE.md ==="
assert "CLAUDE.md is the profile's own file" '[[ -f "$W/CLAUDE.md" && ! -L "$W/CLAUDE.md" ]]'
assert "excluded rule is gone" '! grep -qx "## Tooling Constraints" "$W/CLAUDE.md"'
assert "main still has the excluded rule" 'grep -qx "## Tooling Constraints" "$MAIN/CLAUDE.md"'
assert "profile rule appended without frontmatter" 'grep -qx PROFILE-RULE-MARKER "$W/CLAUDE.md" && ! grep -q "description: team rule" "$W/CLAUDE.md"'

echo "=== owned skills and commands ==="
assert "skills is a real dir" '[[ -d "$W/skills" && ! -L "$W/skills" ]]'
assert "excluded skills are absent" '[[ ! -e "$W/skills/humanize" && ! -e "$W/skills/deslop" ]]'
assert "selected main skill links to main" 'is_link_to_main "$W" skills/converge'
assert "impeccable (deployed outside shared skills) is selected" 'is_link_to_main "$W" skills/impeccable'
assert "profile-only skill is copied in" '[[ -f "$W/skills/team-only/SKILL.md" && ! -L "$W/skills/team-only" ]]'
assert "commands keeps main's and adds the profile's" 'is_link_to_main "$W" commands/commit.md && [[ -f "$W/commands/hello.md" ]]'
assert "entries without overrides stay linked" 'is_link_to_main "$W" hooks && is_link_to_main "$W" .mcp.json'
assert ".harness-owned lists the owned entries" \
  'grep -qx "owned settings.json" "$W/.harness-owned" && grep -qx "owned CLAUDE.md" "$W/.harness-owned" && grep -qx "owned skills" "$W/.harness-owned" && grep -qx "owned commands" "$W/.harness-owned"'

echo "=== reinstall keeps profile edits ==="
jq '.profileOnly = 1' "$W/settings.json" >"$TMP_DIR/s" && cat "$TMP_DIR/s" >"$W/settings.json"
harness --profile work >/dev/null || true
assert "a key added inside the profile survives" '[[ "$(jq -r .profileOnly "$W/settings.json")" == 1 ]]'
assert "overlay still applied" '[[ "$(jq -r .model "$W/settings.json")" == profile-model ]]'

echo "=== full install ==="
before=$(main_snapshot)
harness --only claude --no-plugins >/dev/null
assert "full install leaves main as it was" '[[ "$(main_snapshot | grep -v manifest.json)" == "$(grep -v manifest.json <<<"$before")" ]]'
assert "full install keeps the work profile's overrides" '[[ "$(jq -r .model "$W/settings.json")" == profile-model && -f "$W/commands/hello.md" ]]'
assert "profile without a spec stays fully linked" \
  'is_link_to_main "$H/.claude-plain" settings.json && is_link_to_main "$H/.claude-plain" skills && is_link_to_main "$H/.claude-plain" CLAUDE.md'
sync_out=$(profile_tool sync)
assert "claude-profile sync leaves owned entries alone" \
  '[[ -f "$W/settings.json" && ! -L "$W/settings.json" ]] && ! grep -q "separate copy" <<<"$sync_out"'

echo "=== dry run ==="
echo 'commands_exclude=commit' >>"$SPECS/work/profile.conf"
before=$(tree_snapshot "$W")
harness --dry-run --profile work >/dev/null || true
assert "--dry-run --profile writes nothing" '[[ "$(tree_snapshot "$W")" == "$before" ]]'
harness --profile work >/dev/null || true
assert "commands_exclude drops the command" '[[ ! -e "$W/commands/commit.md" ]]'

echo "=== memory=off ==="
L="$H/.claude-lite"
mkdir -p "$SPECS/lite"
echo 'memory=off' >"$SPECS/lite/profile.conf"
assert "precondition: lite got second-brain from main" 'jq -e ".mcpServers[\"second-brain\"]" "$L/.claude.json" >/dev/null'
harness --profile lite >/dev/null || true
assert "no memory hooks in lite settings" '! grep -q stop-wiki-enforce.sh "$L/settings.json" && grep -q cost-guard.sh "$L/settings.json"'
assert "no wiki skill or memory commands" '[[ ! -e "$L/skills/wiki" && ! -e "$L/commands/devlog.md" ]] && is_link_to_main "$L" skills/converge'
assert "no memory rule in CLAUDE.md" '! grep -qi "wiki maintenance" "$L/CLAUDE.md" && grep -qi "wiki maintenance" "$MAIN/CLAUDE.md"'
assert "second-brain dropped from lite's .claude.json, others kept" \
  '! jq -e ".mcpServers[\"second-brain\"]" "$L/.claude.json" >/dev/null && jq -e ".mcpServers[\"web-strip\"]" "$L/.claude.json" >/dev/null'
profile_tool sync >/dev/null
assert "sync does not bring second-brain back" '! jq -e ".mcpServers[\"second-brain\"]" "$L/.claude.json" >/dev/null'
HARNESS_NO_MEMORY=1 harness --profile work >/dev/null || true
assert "no-memory main forces memory off in a profile" '! grep -q stop-wiki-enforce.sh "$W/settings.json"'
harness --profile work >/dev/null || true

echo "=== a memory-off profile does not leak into later modules ==="
harness --no-plugins >/dev/null || true
assert "cursor still gets the memory rules" '[[ -f "$H/.cursor/rules/wiki-maintenance.mdc" ]]'

echo "=== bad specs and missing profiles ==="
printf 'n\n' | profile_tool bad >/dev/null
B="$H/.claude-bad"
mkdir -p "$SPECS/bad"
printf 'skills_only=a\nskills_exclude=b\n' >"$SPECS/bad/profile.conf"
rc=0
out=$(harness --profile bad) || rc=$?
assert "only + exclude for one kind fails" '[[ $rc -ne 0 ]] && grep -q "skills_only" <<<"$out"'
assert "failed spec writes nothing" 'is_link_to_main "$B" skills && [[ ! -e "$B/.harness" ]]'
echo 'colour=blue' >"$SPECS/bad/profile.conf"
rc=0
out=$(harness --profile bad) || rc=$?
assert "unknown key fails and names it" '[[ $rc -ne 0 ]] && grep -q "colour" <<<"$out"'
rc=0
out=$(harness --profile ghost </dev/null) || rc=$?
assert "missing profile fails without creating it" '[[ $rc -ne 0 && ! -e "$H/.claude-ghost" ]] && grep -q "claude-profile ghost" <<<"$out"'
rc=0
out=$(harness --profile work --only cursor) || rc=$?
assert "--profile with --only is rejected" '[[ $rc -ne 0 ]]'

echo "=== removing overrides ==="
rm "$SPECS/work/settings.json"
out=$(harness --profile work) || true
assert "removed overlay relinks settings.json" 'is_link_to_main "$W" settings.json'
assert "the dropped settings were backed up" 'compgen -G "$W/.harness/backups/*/settings.json" >/dev/null'
assert "the user is told what was dropped" 'grep -q "settings.json" <<<"$out" && grep -qi "backup" <<<"$out"'
rm -rf "$SPECS/work"
harness --only claude --no-plugins >/dev/null
assert "deleted spec reverts every entry on a full install" \
  'is_link_to_main "$W" CLAUDE.md && is_link_to_main "$W" skills && is_link_to_main "$W" commands && [[ ! -e "$W/.harness-owned" ]]'

echo "=== uninstall ==="
harness uninstall >/dev/null || true
assert "uninstall removes profiles and does not recreate them" '[[ ! -e "$W" && ! -e "$L" ]]'

echo ""
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
