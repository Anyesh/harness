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

FAKE_HOME="$TMP_DIR/home"
# WHY: opencode resolves its config dir from XDG_CONFIG_HOME, so without this
# the install under test writes into the real ~/.config/opencode.
export XDG_CONFIG_HOME="$FAKE_HOME/.config"
MANIFEST="$TMP_DIR/manifest.json"
BACKUPS="$TMP_DIR/backups"
mkdir -p "$FAKE_HOME/.cursor" "$FAKE_HOME/.local/bin" "$BACKUPS"
printf 'WIKI_VAULT=%s/vault\n' "$TMP_DIR" > "$FAKE_HOME/.harness.env"
for tool in cursor claude codex opencode sb; do
    printf '#!/bin/sh\necho "mock %s"\n' "$tool" > "$FAKE_HOME/.local/bin/$tool"
    chmod +x "$FAKE_HOME/.local/bin/$tool"
done

harness() {
    HOME="$FAKE_HOME" \
    HARNESS_ENV="$FAKE_HOME/.harness.env" \
    HARNESS_MANIFEST="$MANIFEST" \
    HARNESS_BACKUP_DIR="$BACKUPS" \
    PATH="$FAKE_HOME/.local/bin:$PATH" \
    bash "$REPO_ROOT/install.sh" "$@" 2>&1
}

sha_of() { sha256sum "$1" | cut -d' ' -f1; }
entry() { jq -r --arg k "$1" --arg f "$2" '.files[$k][$f] // "absent"' "$MANIFEST"; }
set_entry() {
    local tmp
    tmp=$(mktemp)
    jq --arg k "$1" --arg sha "$2" --arg src "$3" \
        '.files[$k] = {"sha256": $sha, "source": $src, "templated": false}' "$MANIFEST" > "$tmp"
    mv "$tmp" "$MANIFEST"
}

STALE_SHA=0000000000000000000000000000000000000000000000000000000000000000
RULE="$FAKE_HOME/.cursor/rules/core.mdc"
HOOK="$FAKE_HOME/.cursor/hooks/format-on-save.sh"

harness --only cursor > /dev/null
[[ -f "$RULE" && -f "$HOOK" ]] || { echo "baseline cursor install did not deploy $RULE and $HOOK"; exit 1; }

echo ""
echo "=== unchanged files are re-recorded ==="
echo ""

set_entry "$RULE" "$STALE_SHA" "configs/old/core.mdc"
set_entry "$HOOK" "$STALE_SHA" "configs/claude-code/hooks/format-on-save.sh"
harness --only cursor --dry-run > /dev/null
assert "dry-run leaves a stale entry alone" '[[ "$(entry "$RULE" sha256)" == "$STALE_SHA" ]]'

harness --only cursor > /dev/null
assert "skipped rule gets its current sha" '[[ "$(entry "$RULE" sha256)" == "$(sha_of "$RULE")" ]]'
assert "skipped rule gets its current source" '[[ "$(entry "$RULE" source)" == "configs/shared/rules/core.mdc" ]]'
assert "skipped hook gets its moved source" '[[ "$(entry "$HOOK" source)" == "configs/shared/hooks/format-on-save.sh" ]]'
status_out=$(harness status) || true
assert "status is clean after re-recording" '! grep -qE "DIRTY|MISSING|ORPHAN" <<<"$status_out"'

echo ""
echo "=== entries for deleted files are pruned ==="
echo ""

GONE="$FAKE_HOME/.cursor/hooks/retired-hook.sh"
KEPT="$FAKE_HOME/.cursor/rules/user-original.mdc"
set_entry "$GONE" "$STALE_SHA" "configs/shared/hooks/retired-hook.sh"
set_entry "$KEPT" "$STALE_SHA" "configs/shared/rules/user-original.mdc"
printf 'present\t%s\n' "$KEPT" >> "$BACKUPS/.preexist"

harness --only cursor --dry-run > /dev/null
assert "dry-run does not prune" '[[ "$(entry "$GONE" source)" != "absent" ]]'

harness --only cursor > /dev/null
assert "missing harness-created file is dropped" '[[ "$(entry "$GONE" source)" == "absent" ]]'
assert "missing file that pre-dated the harness is kept for uninstall" '[[ "$(entry "$KEPT" source)" != "absent" ]]'

echo ""
echo "=== status flags orphans ==="
echo ""

ORPHAN="$FAKE_HOME/.cursor/rules/retired-rule.mdc"
printf -- '---\nalwaysApply: true\n---\nretired\n' > "$ORPHAN"
set_entry "$ORPHAN" "$(sha_of "$ORPHAN")" "configs/shared/rules/retired-rule.mdc"
status_out=$(harness status) || true
orphan_lines=$(grep ORPHAN <<<"$status_out" || true)
assert "file whose source was deleted is ORPHAN" 'grep -qF "$ORPHAN" <<<"$orphan_lines"'
assert "live rule is not ORPHAN" '! grep -qF "$RULE" <<<"$orphan_lines"'

echo ""
echo "=== JSON configs compare by content ==="
echo ""

SETTINGS="$FAKE_HOME/.claude/settings.json"
mkdir -p "$FAKE_HOME/.claude"
harness --only claude > /dev/null
[[ -f "$SETTINGS" ]] || { echo "baseline claude install did not deploy $SETTINGS"; exit 1; }
# Claude Code rewrites settings.json in its own key order whenever a setting changes in its UI.
reordered=$(jq -S . "$SETTINGS")
printf '%s\n' "$reordered" > "$SETTINGS"
dry_out=$(harness --only claude --dry-run)
assert "reordered settings.json is not redeployed" '! grep -q "would deploy: settings.json.tmpl" <<<"$dry_out"'
harness --only claude > /dev/null
assert "reordered settings.json keeps its bytes" '[[ "$(cat "$SETTINGS")" == "$reordered" ]]'
assert "reordered settings.json is recorded as clean" '[[ "$(entry "$SETTINGS" sha256)" == "$(sha_of "$SETTINGS")" ]]'

echo ""
echo "=== codex and opencode skip unchanged files ==="
echo ""

CODEX_INSTRUCTIONS="$FAKE_HOME/.codex/instructions.md"
CODEX_HOOK="$FAKE_HOME/.codex/hooks/cost-guard.sh"
OPENCODE_AGENTS="$FAKE_HOME/.config/opencode/AGENTS.md"
for module in codex opencode; do harness --only "$module" > /dev/null; done
[[ -f "$CODEX_INSTRUCTIONS" && -f "$CODEX_HOOK" && -f "$OPENCODE_AGENTS" ]] || { echo "baseline codex/opencode install did not deploy their configs"; exit 1; }
rm -rf "$BACKUPS"/[0-9]*
dry_out=$(for module in codex opencode; do harness --only "$module" --dry-run; done)
assert "dry-run after install deploys nothing to codex" '! grep -qiE "would deploy.*codex" <<<"$dry_out"'
assert "dry-run after install deploys nothing to opencode" '! grep -qiE "would deploy.*opencode" <<<"$dry_out"'
for module in codex opencode; do harness --only "$module" > /dev/null; done
backed_up=$(find "$BACKUPS" -path '*/.codex/*' -o -path '*/.config/opencode/*' 2>/dev/null)
assert "re-install takes no backup of unchanged codex/opencode files" '[[ -z "$backed_up" ]]'
set_entry "$CODEX_INSTRUCTIONS" "$STALE_SHA" "configs/old/instructions.md.tmpl"
harness --only codex > /dev/null
assert "skipped codex instructions.md is re-recorded" '[[ "$(entry "$CODEX_INSTRUCTIONS" sha256)" == "$(sha_of "$CODEX_INSTRUCTIONS")" ]]'

echo ""
echo "Manifest sync: $TOTAL total, $PASS passed, $FAIL failed"

[[ $FAIL -eq 0 ]]
