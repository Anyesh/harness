#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HARNESS_ENV=$(mktemp)
export HARNESS_ENV
trap 'rm -f "$HARNESS_ENV"' EXIT
echo "WIKI_VAULT=/tmp/harness-test-vault" >"$HARNESS_ENV"

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/template.sh"

export HOME_DIR="${HOME:-/tmp/harness-test}"
export LC_ALL=C.UTF-8

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
trap 'rm -rf "$TMP_DIR" "$HARNESS_ENV"' EXIT

C="$TMP_DIR/CLAUDE.md"
X="$TMP_DIR/instructions.md"
render_template "$REPO_ROOT/configs/claude-code/CLAUDE.md.tmpl" "$C"
render_template "$REPO_ROOT/configs/codex/instructions.md.tmpl" "$X"

echo ""
echo "=== rendered global rules ==="
echo ""

for f in "$C" "$X"; do
    n=$(basename "$f")
    assert "$n: no U+2014 anywhere" '! grep -qP "\x{2014}" "$f"'
    assert "$n: no Fable section" '! grep -q "^## Fable" "$f"'
    for h in "## Code Design" "## Scope Gate" "## Second Brain (MCP)" "## Wiki Maintenance" "## Tooling Constraints" "## No AI Comments"; do
        assert "$n: has $h" 'grep -q "^$h" "$f"'
    done
    assert "$n: comment catalogue with examples" 'grep -q "Section banners" "$f" && grep -q "Change-history comments" "$f" && grep -q "paraphrase the signature" "$f"'
    assert "$n: long rationale comments banned" 'grep -q "Multi-line rationale" "$f"'
    assert "$n: code quality lines present" 'grep -q "No emoji characters in source code" "$f" && grep -q "No inline imports in Python" "$f"'
    assert "$n: conciseness rule present" 'grep -qi "keep responses concise" "$f"'
    assert "$n: scope gate exemption avoids banned phrasing" '! grep -qi "apply to quick fixes" "$f"'
done
assert "codex: fallback carries hook-only lists" 'grep -q "Standard directives are fine" "$X"'
assert "claude: hook-only lists stay out" '! grep -q "Standard directives are fine" "$C"'

echo ""
echo "Rules lint: $TOTAL total, $PASS passed, $FAIL failed"

[[ $FAIL -eq 0 ]]
