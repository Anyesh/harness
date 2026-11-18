#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/modules/claude.sh"

# Args: dir, then the tools to stub. Each stub logs its argv to $dir/calls.log.
make_stubs() {
  local dir="$1" tool
  shift
  mkdir -p "$dir"
  : >"$dir/calls.log"
  for tool in "$@"; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\n' "$tool" "$dir" >"$dir/$tool"
    chmod +x "$dir/$tool"
  done
}

BASE_PATH="/usr/bin:/bin"
ALL="$TMP/all"
make_stubs "$ALL" uv rustup npm
DRY="$TMP/dry"
make_stubs "$DRY" uv rustup npm
NO_RUSTUP="$TMP/norustup"
make_stubs "$NO_RUSTUP" uv npm
NO_UV="$TMP/nouv"
make_stubs "$NO_UV" rustup npm
NO_NPM="$TMP/nonpm"
make_stubs "$NO_NPM" uv rustup
HAVE="$TMP/have"
make_stubs "$HAVE" uv rustup npm pyright pyright-langserver rust-analyzer typescript-language-server
# The real pyright-langserver exits 1 on --version because it requires --stdio.
printf '#!/bin/sh\nexit 1\n' >"$HAVE/pyright-langserver"

DRY_RUN=false PATH="$ALL:$BASE_PATH" claude_lsp_servers >/dev/null 2>&1
assert "installs pyright with uv tool" 'grep -qx "uv tool install pyright" "$ALL/calls.log"'
assert "adds the rust-analyzer component" 'grep -qx "rustup component add rust-analyzer" "$ALL/calls.log"'

DRY_RUN=true PATH="$DRY:$BASE_PATH" claude_lsp_servers >/dev/null 2>&1
assert "dry run installs nothing" '[[ ! -s "$DRY/calls.log" ]]'

DRY_RUN=false PATH="$NO_RUSTUP:$BASE_PATH" claude_lsp_servers >"$TMP/norustup.out" 2>&1
assert "without rustup still installs pyright" 'grep -qx "uv tool install pyright" "$NO_RUSTUP/calls.log"'
assert "without rustup warns" 'grep -qi "rustup" "$TMP/norustup.out"'

DRY_RUN=false PATH="$NO_UV:$BASE_PATH" claude_lsp_servers >"$TMP/nouv.out" 2>&1
assert "without uv warns and skips pyright" 'grep -qi "uv" "$TMP/nouv.out" && ! grep -q pyright "$NO_UV/calls.log"'
assert "without uv still adds rust-analyzer" 'grep -qx "rustup component add rust-analyzer" "$NO_UV/calls.log"'

DRY_RUN=false PATH="$HAVE:$BASE_PATH" claude_lsp_servers >/dev/null 2>&1
assert "present pyright is not reinstalled" '! grep -q "uv tool" "$HAVE/calls.log"'

assert "installs typescript-language-server from the public npm registry" 'grep -qx "npm install -g --registry https://registry.npmjs.org/ typescript typescript-language-server" "$ALL/calls.log"'
assert "dry run skips npm" '! grep -q npm "$DRY/calls.log"'
DRY_RUN=false PATH="$NO_NPM:$BASE_PATH" claude_lsp_servers >"$TMP/nonpm.out" 2>&1
assert "without npm warns about it" 'grep -qi "npm" "$TMP/nonpm.out"'
assert "present typescript server is not reinstalled" '! grep -q npm "$HAVE/calls.log"'

echo ""
echo "Claude LSP servers: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
