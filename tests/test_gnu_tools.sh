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

# Args: dir, tool, first line of its --version output.
fake_tool() {
  mkdir -p "$1"
  printf '#!/bin/sh\necho "%s"\n' "$3" >"$1/$2"
  chmod +x "$1/$2"
}

for t in sed grep date; do
  fake_tool "$TMP/gnu" "$t" "$t (GNU coreutils) 9.5"
done
fake_tool "$TMP/mixed" sed "sed: illegal option -- -"
fake_tool "$TMP/mixed" grep "grep (BSD grep, GNU compatible) 2.6.0-FreeBSD"
fake_tool "$TMP/mixed" date "date (GNU coreutils) 9.5"

# Args: PATH for the call, OS name.
require() {
  PATH="$1" REPO_ROOT="$REPO_ROOT" /bin/bash -c '
    set -euo pipefail
    source "$REPO_ROOT/lib/gnu_tools.sh"
    harness_require_gnu_tools "$1"
    echo "returned"' _ "$2" 2>"$TMP/err"
}

echo ""
echo "=== harness_require_gnu_tools ==="

assert "Darwin with GNU tools first on PATH returns" '[[ $(require "$TMP/gnu" Darwin) == returned ]]'
assert "Darwin with BSD sed and grep exits 1" '! require "$TMP/mixed" Darwin >/dev/null'
assert "names the BSD tools" 'grep -q "sed grep" "$TMP/err"'
assert "names the gnubin fix" 'grep -q "gnubin" "$TMP/err"'
assert "Linux is not checked" '[[ $(require "$TMP/mixed" Linux) == returned ]]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
