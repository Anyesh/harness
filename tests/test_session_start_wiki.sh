#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/configs/shared/hooks/session-start-wiki.sh"

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
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT="$TMP_DIR/myproj"
VAULT="$TMP_DIR/vault"
mkdir -p "$PROJECT" "$VAULT/wiki/projects/myproj"

run_hook() {
  WIKI_VAULT="$VAULT" CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" \
    <<<'{"hook_event_name":"SessionStart"}' | jq -r '.hookSpecificOutput.additionalContext'
}

echo ""

printf '## Projects\n\n### myproj: Test project\n- [[devlog]]: dated entries\n\n### other: Other\n' \
  > "$VAULT/wiki/index.md"
OUT=$(run_hook)
assert "colon-style index header is found as the project entry" \
  'grep -q "## myproj detail:" <<<"$OUT"'
assert "found entry does not claim the index lacks one" \
  '! grep -q "no index entry yet" <<<"$OUT"'

printf '## Projects\n\n### other: Other\n' > "$VAULT/wiki/index.md"
OUT=$(run_hook)
assert "project without a header is reported as having no entry" \
  'grep -q "no index entry yet for myproj" <<<"$OUT"'

printf '## Projects\n\n### myproj-extra: Different project\n' > "$VAULT/wiki/index.md"
OUT=$(run_hook)
assert "slug prefix of another project does not count as an entry" \
  'grep -q "no index entry yet for myproj" <<<"$OUT"'

echo ""
echo "session-start-wiki: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
