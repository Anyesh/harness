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

HEADING="^## Rules Without a Guard Hook Here"

H="$TMP_DIR/home"
mkdir -p "$H/.cursor" "$H/.local/bin"
: > "$H/.harness.env"
for tool in cursor codex opencode sb cargo systemctl claude; do
    printf '#!/bin/sh\nexit 0\n' > "$H/.local/bin/$tool"
    chmod +x "$H/.local/bin/$tool"
done

for module in claude cursor codex opencode; do
    HOME="$H" \
    XDG_CONFIG_HOME="$H/.config" \
    HARNESS_ENV="$H/.harness.env" \
    HARNESS_MANIFEST="$H/manifest.json" \
    HARNESS_BACKUP_DIR="$H/backups" \
    TMPDIR="$TMP_DIR/tmpdir" \
    PATH="$H/.local/bin:$PATH" \
    bash "$REPO_ROOT/install.sh" --only "$module" --no-plugins --no-memory > /dev/null 2>&1 || true
done

echo ""
echo "=== hook-fallback rule reaches only agents without guard hooks ==="
echo ""

assert "claude CLAUDE.md rendered" '[[ -f "$H/.claude/CLAUDE.md" ]]'
assert "claude CLAUDE.md lacks the fallback" '! grep -q "$HEADING" "$H/.claude/CLAUDE.md"'
assert "cursor rules rendered" '[[ -f "$H/.cursor/rules/core.mdc" ]]'
assert "cursor rules lack the fallback" '! grep -rq "$HEADING" "$H/.cursor/rules"'
assert "codex instructions carry the fallback" 'grep -q "$HEADING" "$H/.codex/instructions.md"'
assert "opencode AGENTS.md carries the fallback" 'grep -q "$HEADING" "$H/.config/opencode/AGENTS.md"'
assert "codex instructions keep the shared rules" 'grep -q "^## Scope Gate" "$H/.codex/instructions.md"'

echo ""
echo "Hook fallback: $TOTAL total, $PASS passed, $FAIL failed"

[[ $FAIL -eq 0 ]]
