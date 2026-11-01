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

TMP_DIR=$(mktemp -d)
trap 'command rm -rf "$TMP_DIR"' EXIT

# shellcheck source=../lib/deploy.sh
. "$REPO_ROOT/lib/deploy.sh"

FORCE=false
DRY_RUN=false
NO_BACKUP=true
log_skip() { :; }
log_info() { :; }
log_update() { :; }
log_success() { :; }
manifest_add() { :; }
manifest_record_unchanged() { :; }

echo "deploy_file replaces by rename"
printf 'old\n' >"$TMP_DIR/tool"
printf 'new\n' >"$TMP_DIR/candidate"
exec 3<"$TMP_DIR/tool"
deploy_file "$TMP_DIR/candidate" "$TMP_DIR/tool" src false tool executable
assert "the destination has the new content" '[[ $(cat "$TMP_DIR/tool") == new ]]'
assert "a reader holding the old file still sees the old bytes" '[[ $(cat <&3) == old ]]'
exec 3<&-
assert "the executable bit is set" '[[ -x $TMP_DIR/tool ]]'
assert "no temp file is left beside the destination" '[[ $(find "$TMP_DIR" -maxdepth 1 -name "tool.*" | wc -l) -eq 0 ]]'

echo "deploy_file writes through a symlinked destination"
mkdir -p "$TMP_DIR/real"
printf 'old\n' >"$TMP_DIR/real/conf"
ln -s "$TMP_DIR/real/conf" "$TMP_DIR/link"
printf 'newer\n' >"$TMP_DIR/candidate2"
deploy_file "$TMP_DIR/candidate2" "$TMP_DIR/link" src false conf
assert "the link is still a link" '[[ -L $TMP_DIR/link ]]'
assert "the link target has the new content" '[[ $(cat "$TMP_DIR/real/conf") == newer ]]'

echo "deploy_file installs a new file"
printf 'fresh\n' >"$TMP_DIR/candidate3"
deploy_file "$TMP_DIR/candidate3" "$TMP_DIR/sub/dir/new" src false new
assert "a new destination is created with its directory" '[[ $(cat "$TMP_DIR/sub/dir/new") == fresh ]]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
