#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/template.sh"
source "$REPO_ROOT/lib/deploy.sh"
source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/backup.sh"
source "$REPO_ROOT/modules/herdr.sh"

missing=$(herdr_missing_needs cargo,cc)
if [[ -n "$missing" ]]; then
  echo "SKIP  workview: needs $missing"
  exit 0
fi

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
cd "$REPO_ROOT/tools/workview"

run_step() {
  local name="$1"
  shift
  if herdr_with_toolchain "$@" >"$LOG" 2>&1; then
    printf '  PASS  %s\n' "$name"
  else
    printf '  FAIL  %s\n' "$name"
    tail -30 "$LOG"
    return 1
  fi
}

rc=0
run_step "cargo test" cargo test --locked || rc=1
run_step "cargo clippy" cargo clippy --locked --all-targets -- -D warnings || rc=1
exit $rc
