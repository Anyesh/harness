#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/template.sh"

export HOME_DIR="${HOME:-/tmp/harness-test}"
export HARNESS_ENV="${HARNESS_ENV:-$HOME/.harness.env}"

PASS=0
FAIL=0
TOTAL=0

while IFS= read -r tmpl; do
  [[ -z "$tmpl" ]] && continue
  TOTAL=$((TOTAL + 1))
  name="${tmpl#$REPO_ROOT/}"
  tmp=$(mktemp)

  render_template "$tmpl" "$tmp"

  if validate_rendered "$tmp"; then
    printf "  PASS  %s\n" "$name"
    PASS=$((PASS + 1))
  else
    printf "  FAIL  %s\n" "$name"
    FAIL=$((FAIL + 1))
  fi

  rm -f "$tmp"
done < <(find "$REPO_ROOT/configs" -name '*.tmpl' -type f 2>/dev/null | sort)

echo ""
echo "Templates: $TOTAL total, $PASS passed, $FAIL failed"

[[ $FAIL -eq 0 ]]
