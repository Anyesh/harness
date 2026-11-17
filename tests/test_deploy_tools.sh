#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$HARNESS_ROOT/lib/common.sh"
eval "$(awk '/^deploy_tools\(\) \{/,/^}/' "$HARNESS_ROOT/install.sh")"

PASS=0
FAIL=0
assert() {
  if eval "$2"; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REPO_ROOT="$TMP/repo"
HOME="$TMP/home"
DRY_RUN=false
mkdir -p "$REPO_ROOT/tools/node-tool/node_modules" "$REPO_ROOT/tools/rust-tool/src" "$HOME"
printf '{}\n' >"$REPO_ROOT/tools/node-tool/package.json"
printf 'x\n' >"$REPO_ROOT/tools/node-tool/index.js"
printf '[package]\n' >"$REPO_ROOT/tools/rust-tool/Cargo.toml"
mkdir -p "$HOME/.harness/tools/node-tool/node_modules"

echo "=== deploy_tools ==="
out=$(deploy_tools 2>&1)
assert "deploys a node tool" '[[ -f "$HOME/.harness/tools/node-tool/index.js" ]]'
assert "skips a tool without package.json" '[[ ! -e "$HOME/.harness/tools/rust-tool" ]]'
assert "does not report the skipped tool as deployed" '! grep -q "tool: rust-tool" <<<"$out"'
out=$(DRY_RUN=true deploy_tools 2>&1)
assert "dry run lists only node tools" '! grep -q "rust-tool" <<<"$out" && grep -q "node-tool" <<<"$out"'

echo ""
echo "deploy_tools: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
