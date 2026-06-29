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
mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/.cursor" "$FAKE_HOME/.codex" "$FAKE_HOME/.local/bin"

cat > "$FAKE_HOME/.harness.env" <<EOF
WIKI_VAULT=$FAKE_HOME/test-vault
EOF

for tool in claude codex cursor sb; do
    printf '#!/bin/sh\necho "mock %s"\n' "$tool" > "$FAKE_HOME/.local/bin/$tool"
    chmod +x "$FAKE_HOME/.local/bin/$tool"
done

MOCK_PATH="$FAKE_HOME/.local/bin:$PATH"

echo ""
echo "=== Integration: full dry-run ==="
echo ""

full_output=$(
    HOME="$FAKE_HOME" \
    HARNESS_ENV="$FAKE_HOME/.harness.env" \
    HARNESS_MANIFEST="$TMP_DIR/manifest.json" \
    HARNESS_BACKUP_DIR="$TMP_DIR/backups" \
    PATH="$MOCK_PATH" \
    bash "$REPO_ROOT/install.sh" --dry-run 2>&1
) || true

assert "full dry-run produces output" '[[ -n "$full_output" ]]'
assert "full dry-run loads modules" 'echo "$full_output" | grep -q "Module:"'
assert "full dry-run mentions claude" 'echo "$full_output" | grep -qi "claude"'
assert "full dry-run contains dry-run markers" 'echo "$full_output" | grep -q "\[dry-run\]"'
assert "full dry-run mentions tools detection" 'echo "$full_output" | grep -q "Detected tools"'

echo ""
echo "=== Integration: --only claude --dry-run ==="
echo ""

claude_output=$(
    HOME="$FAKE_HOME" \
    HARNESS_ENV="$FAKE_HOME/.harness.env" \
    HARNESS_MANIFEST="$TMP_DIR/manifest-claude.json" \
    HARNESS_BACKUP_DIR="$TMP_DIR/backups" \
    PATH="$MOCK_PATH" \
    bash "$REPO_ROOT/install.sh" --only claude --dry-run 2>&1
) || true

assert "claude-only produces output" '[[ -n "$claude_output" ]]'
assert "claude-only mentions claude module" 'echo "$claude_output" | grep -q "Module: claude"'
assert "claude-only skips cursor module" '! echo "$claude_output" | grep -q "Module: cursor"'
assert "claude-only skips codex module" '! echo "$claude_output" | grep -q "Module: codex"'

echo ""
echo "=== Integration: --only cursor --dry-run ==="
echo ""

cursor_output=$(
    HOME="$FAKE_HOME" \
    HARNESS_ENV="$FAKE_HOME/.harness.env" \
    HARNESS_MANIFEST="$TMP_DIR/manifest-cursor.json" \
    HARNESS_BACKUP_DIR="$TMP_DIR/backups" \
    PATH="$MOCK_PATH" \
    bash "$REPO_ROOT/install.sh" --only cursor --dry-run 2>&1
) || true

assert "cursor-only produces output" '[[ -n "$cursor_output" ]]'
assert "cursor-only mentions cursor module" 'echo "$cursor_output" | grep -q "Module: cursor"'
assert "cursor-only skips claude module" '! echo "$cursor_output" | grep -q "Module: claude"'
assert "cursor-only mentions hooks.json" 'echo "$cursor_output" | grep -qi "hooks.json"'

echo ""
echo "=== Integration: template validation ==="
echo ""

tmpl_output=$(
    REPO_ROOT="$REPO_ROOT" \
    HOME="$FAKE_HOME" \
    HARNESS_ENV="$FAKE_HOME/.harness.env" \
    bash -c '
        source "'"$REPO_ROOT"'/lib/common.sh"
        source "'"$REPO_ROOT"'/lib/template.sh"
        validate_all_templates
    ' 2>&1
) || true

assert "template validation runs" '[[ -n "$tmpl_output" ]]'
assert "template validation reports count" 'echo "$tmpl_output" | grep -q "validated"'

echo ""
echo "=== Integration: per-module tests ==="
echo ""

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/template.sh"
source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/detect.sh"
source "$REPO_ROOT/lib/backup.sh"
source "$REPO_ROOT/modules/lib.sh"

DRY_RUN=true
FORCE=true
NO_BACKUP=true
NO_PLUGINS=true

for mod_file in "$REPO_ROOT"/modules/*.sh; do
    name=$(basename "$mod_file" .sh)
    [[ "$name" == "lib" || "$name" == "watch" ]] && continue
    source "$mod_file"
    prefix="${name//-/_}"
    test_fn="${prefix}_test"
    if declare -f "$test_fn" >/dev/null 2>&1; then
        assert "module test: $name" "$test_fn 2>/dev/null"
    else
        assert "module test: $name (function exists)" 'false'
    fi
done

echo ""
echo "==========================================="
printf "  Total: %d  |  Pass: %d  |  Fail: %d\n" "$TOTAL" "$PASS" "$FAIL"
echo "==========================================="
echo ""

[[ $FAIL -eq 0 ]]
