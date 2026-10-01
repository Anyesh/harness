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

python3 - "$VAULT" <<'PY'
import sys
vault = sys.argv[1]
headers = ''.join(f'### proj{i}: ' + 'description words ' * 8 + '\n' for i in range(40))
detail_lines = ''.join(f'- [Page {i}](projects/myproj/plans/p{i}.md): ' + 'long hook text ' * 30 + '\n' for i in range(20))
open(f'{vault}/wiki/index.md', 'w').write(
    '## Projects\n\n' + headers + '### myproj: Big project\n' + detail_lines + '\n### zzz: Last\n')
entries = ''.join(f'## [2026-10-0{i}] Entry {i}\n\n' + 'devlog body line\n' * 120 for i in range(1, 6))
open(f'{vault}/wiki/projects/myproj/devlog.md', 'w').write('---\ntype: devlog\n---\n\n# Devlog\n\n' + entries)
PY
OUT=$(run_hook)
CHARS=$(printf '%s' "$OUT" | wc -m)
assert "oversized index and devlog stay under the 10000-char additionalContext cap" \
  '[ "$CHARS" -lt 9500 ]'
assert "oversized output keeps the project detail header" \
  'grep -q "## myproj detail:" <<<"$OUT"'
assert "oversized output keeps the newest devlog entry heading" \
  'grep -q "## \[2026-10-01\] Entry 1" <<<"$OUT"'
assert "oversized output says where the rest lives" \
  'grep -q "truncated" <<<"$OUT"'

printf '## Projects\n\n### myproj: Test project\n- [[devlog]]: dated entries\n' > "$VAULT/wiki/index.md"
printf '# Devlog\n\n## [2026-10-02] Small\n\nbody\n' > "$VAULT/wiki/projects/myproj/devlog.md"
OUT=$(run_hook)
assert "small vault output carries no truncation marker" \
  '! grep -q "truncated" <<<"$OUT"'

echo ""
echo "session-start-wiki: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
