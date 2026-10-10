#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODS_SRC="$REPO_ROOT/configs/claude-code/mods"

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

REAL_CLAUDE=$(command -v claude || true)

# The mock claude records whether the marketplace folder already existed when
# it was called, because `marketplace add` must run after the files deploy.
new_home() {
    local home="$1"
    mkdir -p "$home/.local/bin"
    printf 'WIKI_VAULT=%s/vault\n' "$TMP_DIR" > "$home/.harness.env"
    local tool
    for tool in cursor codex opencode sb cargo systemctl; do
        printf '#!/bin/sh\nexit 0\n' > "$home/.local/bin/$tool"
        chmod +x "$home/.local/bin/$tool"
    done
    cat > "$home/.local/bin/claude" <<EOF
#!/bin/sh
state=absent
[ -f "$home/.claude/harness-mods/.claude-plugin/marketplace.json" ] && state=present
echo "claude \$* [marketplace \$state]" >> "$home/calls.log"
EOF
    chmod +x "$home/.local/bin/claude"
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

echo ""
echo "=== mod source ==="
echo ""

if [[ -n "$REAL_CLAUDE" ]]; then
    assert "marketplace and mod validate in strict mode" \
        '"$REAL_CLAUDE" plugin validate --strict "$MODS_SRC" >/dev/null 2>&1 && "$REAL_CLAUDE" plugin validate --strict "$MODS_SRC/nudge-band" >/dev/null 2>&1'
    assert "mod tests pass" '"$REAL_CLAUDE" plugin test "$MODS_SRC/nudge-band" >/dev/null 2>&1'
    assert "mod registers no tool.call hook (issue #92533)" \
        '! "$REAL_CLAUDE" plugin validate "$MODS_SRC/nudge-band" 2>&1 | grep -E "hooks:" | grep -q "tool.call"'
else
    printf "  SKIP  claude CLI not found, mod validate and test not run\n"
fi

echo ""
echo "=== deploy ==="
echo ""

H="$TMP_DIR/home"
new_home "$H"
first=$(harness "$H" --only claude --no-plugins)
DEST="$H/.claude/harness-mods"
S="$H/.claude/settings.json"

assert "marketplace manifest deployed" '[[ -f "$DEST/.claude-plugin/marketplace.json" ]]'
assert "mod files deployed byte-identical" \
    '(for f in .claude-plugin/plugin.json hooks/hooks.json hooks/register.tsx hooks/rules.ts hooks/probe.ts types/index.d.ts; do cmp -s "$MODS_SRC/nudge-band/$f" "$DEST/nudge-band/$f" || exit 1; done)'
assert "mod tests are not deployed" '[[ ! -e "$DEST/nudge-band/tests" ]]'
assert "settings register the harness-mods marketplace at the deployed folder" \
    '[[ "$(jq -r ".extraKnownMarketplaces[\"harness-mods\"].source.path" "$S")" == "$DEST" ]]'
assert "settings enable nudge-band" '[[ "$(jq -r ".enabledPlugins[\"nudge-band@harness-mods\"]" "$S")" == "true" ]]'
assert "claude settings no longer wire the shell nudges" \
    '! jq -r ".hooks.UserPromptSubmit[].hooks[].command" "$S" | grep -qE "scope-drift-detector|wiki-nudge|cleanup-nudge"'
assert "claude settings keep the humanize and ownit trackers" \
    'jq -r ".hooks.UserPromptSubmit[].hooks[].command" "$S" | grep -q humanize-mode-tracker && jq -r ".hooks.UserPromptSubmit[].hooks[].command" "$S" | grep -q ownit-mode-tracker'
assert "cursor keeps the shell nudges" \
    'grep -q scope-drift-detector "$REPO_ROOT/configs/cursor/hooks.json" && grep -q cleanup-nudge "$REPO_ROOT/configs/cursor/hooks.json"'

status_out=$(harness "$H" status) || true
assert "status is clean after deploy" '! grep -qE "DIRTY|MISSING|ORPHAN" <<<"$status_out"'
again=$(harness "$H" --only claude --no-plugins)
assert "second run redeploys no mod file" '! grep -E "installed:|updated:" <<<"$again" | grep -q "mod "'

echo ""
echo "=== plugin registration ==="
echo ""

P="$TMP_DIR/plugins"
new_home "$P"
harness "$P" --only claude >/dev/null
assert "registers the local marketplace after its files deploy" \
    'grep -qF "claude plugin marketplace add $P/.claude/harness-mods [marketplace present]" "$P/calls.log"'
assert "installs nudge-band from the local marketplace" \
    'grep -qF "claude plugin install nudge-band@harness-mods" "$P/calls.log"'

echo ""
echo "=== uninstall ==="
echo ""

harness "$H" uninstall >/dev/null || true
assert "uninstall removes deployed mod files" '[[ ! -f "$DEST/nudge-band/hooks/register.tsx" ]]'

echo ""
echo "nudge-band: $PASS/$TOTAL passed"
[[ "$FAIL" -eq 0 ]]
