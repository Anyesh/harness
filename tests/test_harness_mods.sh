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

MODS=()
for dir in "$MODS_SRC"/*/; do
    [[ -f "$dir/.claude-plugin/plugin.json" ]] && MODS+=("$(basename "$dir")")
done

mod_files() {
    (cd "$MODS_SRC/$1" && find . -type f -not -path './tests/*' -not -path './.claude-plugin/types/*' -not -name tsconfig.json | sort)
}

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
if [ "\$1 \$2" = "plugin list" ] && [ -f "$home/installed" ]; then cat "$home/installed"; fi
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

assert "marketplace lists every mod folder" \
    '[[ "$(jq -r ".plugins[].name" "$MODS_SRC/.claude-plugin/marketplace.json" | sort | tr "\n" " ")" == "$(printf "%s\n" "${MODS[@]}" | sort | tr "\n" " ")" ]]'

if [[ -n "$REAL_CLAUDE" ]]; then
    assert "marketplace validates in strict mode" '"$REAL_CLAUDE" plugin validate --strict "$MODS_SRC" >/dev/null 2>&1'
    for mod in "${MODS[@]}"; do
        assert "$mod validates in strict mode" '"$REAL_CLAUDE" plugin validate --strict "$MODS_SRC/$mod" >/dev/null 2>&1'
        assert "$mod tests pass" '"$REAL_CLAUDE" plugin test "$MODS_SRC/$mod" >/dev/null 2>&1'
        assert "$mod registers no tool.call hook (issue #92533)" \
            '! "$REAL_CLAUDE" plugin validate "$MODS_SRC/$mod" 2>&1 | grep -E "hooks:" | grep -q "tool.call"'
    done
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
for mod in "${MODS[@]}"; do
    assert "$mod files deployed byte-identical" \
        '(while read -r f; do cmp -s "$MODS_SRC/$mod/$f" "$DEST/$mod/$f" || exit 1; done < <(mod_files "$mod"))'
    assert "$mod tests are not deployed" '[[ ! -e "$DEST/$mod/tests" ]]'
    assert "settings enable $mod" '[[ "$(jq -r ".enabledPlugins[\"$mod@harness-mods\"]" "$S")" == "true" ]]'
done
assert "settings register the harness-mods marketplace at the deployed folder" \
    '[[ "$(jq -r ".extraKnownMarketplaces[\"harness-mods\"].source.path" "$S")" == "$DEST" ]]'
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
for mod in "${MODS[@]}"; do
    assert "installs $mod from the local marketplace" 'grep -qF "claude plugin install $mod@harness-mods" "$P/calls.log"'
done
assert "does not uninstall a retired mod that is not installed" '! grep -qF "plugin uninstall" "$P/calls.log"'

R="$TMP_DIR/retired"
new_home "$R"
printf '  ❯ handoff@harness-mods\n    Status: ✔ enabled\n' > "$R/installed"
harness "$R" --only claude >/dev/null
assert "uninstalls the retired handoff mod when it is still installed" \
    'grep -qF "claude plugin uninstall handoff@harness-mods" "$R/calls.log"'

echo ""
echo "=== uninstall ==="
echo ""

harness "$H" uninstall >/dev/null || true
assert "uninstall removes deployed mod files" '[[ -z "$(find "$DEST" -path "*/hooks/*" -type f 2>/dev/null)" ]]'

echo ""
echo "harness mods: $PASS/$TOTAL passed"
[[ "$FAIL" -eq 0 ]]
