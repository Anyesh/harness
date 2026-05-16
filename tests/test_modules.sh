#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/template.sh"
source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/detect.sh"
source "$REPO_ROOT/lib/backup.sh"
source "$REPO_ROOT/modules/lib.sh"

PASS=0
FAIL=0
TOTAL=0

for mod_file in "$REPO_ROOT"/modules/*.sh; do
  name=$(basename "$mod_file" .sh)
  [[ "$name" == "lib" || "$name" == "watch" ]] && continue

  TOTAL=$((TOTAL + 1))
  source "$mod_file"

  prefix="${name//-/_}"
  check_fn="${prefix}_check"

  if declare -f "$check_fn" >/dev/null 2>&1; then
    if "$check_fn" 2>/dev/null; then
      printf "  PASS  %s (%s)\n" "$name" "$check_fn"
      PASS=$((PASS + 1))
    else
      printf "  SKIP  %s (%s returned false)\n" "$name" "$check_fn"
      PASS=$((PASS + 1))
    fi
  else
    printf "  FAIL  %s (missing %s)\n" "$name" "$check_fn"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "Modules: $TOTAL total, $PASS passed, $FAIL failed"

[[ $FAIL -eq 0 ]]
