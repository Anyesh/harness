#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/configs/shared/hooks/session-start-wiki.sh"
unset HARNESS_WORK WIKI_VAULT

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
export HARNESS_ENV="$TMP_DIR/harness.env" XDG_STATE_HOME="$TMP_DIR/xdg"
export HOME="$TMP_DIR/home"
mkdir -p "$HOME"
: >"$HARNESS_ENV"

PROJECT="$TMP_DIR/myproj"
VAULT="$TMP_DIR/vault"
PDIR="$VAULT/wiki/projects/myproj"
mkdir -p "$PROJECT" "$PDIR" "$VAULT/wiki/projects/other" "$VAULT/wiki/projects/myproj-extra"

run_hook() {
  WIKI_VAULT="$VAULT" CLAUDE_PROJECT_DIR="${1:-$PROJECT}" bash "$HOOK" \
    <<<'{"hook_event_name":"SessionStart"}' | jq -r '.hookSpecificOutput.additionalContext // empty'
}

echo ""

printf -- '---\ntype: project-index\nproject: myproj\ntitle: Test project\n---\n\n- [Devlog](devlog.md): dated entries\n' >"$PDIR/index.md"
OUT=$(run_hook)
assert "the project's own index is injected" 'grep -q "## myproj detail:" <<<"$OUT" && grep -qF "[Devlog](devlog.md)" <<<"$OUT"'
assert "the index frontmatter is not injected" '! grep -q "type: project-index" <<<"$OUT"'
assert "the WIKI line names the resolved vault" 'grep -qF "WIKI: project=myproj vault=$VAULT" <<<"$OUT"'
assert "agents are told to write under the vault on the WIKI line" 'grep -q "vault named on this WIKI line" <<<"$OUT"'
assert "project names come from folders" 'grep -q "other" <<<"$OUT" && grep -q "myproj-extra" <<<"$OUT"'
assert "the top index is generated at session start" 'grep -q "^generated: true" "$VAULT/wiki/index.md"'

rm "$PDIR/index.md"
OUT=$(run_hook)
assert "a project without an index is told where to create it" 'grep -qF "no project index yet" <<<"$OUT" && grep -qF "$PDIR/index.md" <<<"$OUT"'

python3 - "$VAULT" <<'PY'
import sys
vault = sys.argv[1]
detail = ''.join(f'- [Page {i}](plans/p{i}.md): ' + 'long hook text ' * 30 + '\n' for i in range(20))
open(f'{vault}/wiki/projects/myproj/index.md', 'w').write('---\ntitle: Big\n---\n\n' + detail)
entries = ''.join(f'## [2026-10-0{i}] Entry {i}\n\n' + 'devlog body line\n' * 120 for i in range(1, 6))
open(f'{vault}/wiki/projects/myproj/devlog.md', 'w').write('---\ntype: devlog\n---\n\n# Devlog\n\n' + entries)
import os
for i in range(200):
    os.makedirs(f'{vault}/wiki/projects/proj{i:03d}-with-a-long-name', exist_ok=True)
PY
OUT=$(run_hook)
CHARS=$(printf '%s' "$OUT" | wc -m)
assert "oversized index and devlog stay under the 10000-char additionalContext cap" '[ "$CHARS" -lt 9500 ]'
assert "oversized output keeps the project detail header" 'grep -q "## myproj detail:" <<<"$OUT"'
assert "oversized output keeps the newest devlog entry heading" 'grep -q "## \[2026-10-01\] Entry 1" <<<"$OUT"'
assert "oversized output says where the rest lives" 'grep -q "truncated" <<<"$OUT"'

rm -rf "$VAULT/wiki/projects/proj"*
printf -- '- [Devlog](devlog.md): dated entries\n' >"$PDIR/index.md"
printf '# Devlog\n\n## [2026-10-02] Small\n\nbody\n' >"$PDIR/devlog.md"
OUT=$(run_hook)
assert "small vault output carries no truncation marker" '! grep -q "truncated" <<<"$OUT"'

git -C "$TMP_DIR" init -q myproj-main
git -C "$TMP_DIR/myproj-main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$TMP_DIR/myproj-main" worktree add -q "$TMP_DIR/w-t8-seed" -b wt
OUT=$(run_hook "$TMP_DIR/w-t8-seed")
assert "a worktree session reports its main checkout's project" 'grep -q "WIKI: project=myproj-main " <<<"$OUT"'

mkdir -p "$VAULT/Work/agent-wiki/wiki/projects/myproj"
printf -- '- [Work devlog](devlog.md): work log\n' >"$VAULT/Work/agent-wiki/wiki/projects/myproj/index.md"
printf 'WIKI_WORK_PROJECTS=myproj\n' >"$HARNESS_ENV"
OUT=$(run_hook)
assert "a personal session in a once-listed work project stays in the personal vault" \
  'grep -qF "vault=$VAULT" <<<"$OUT" && ! grep -qF "vault=$VAULT/Work" <<<"$OUT" && ! grep -qF "[Work devlog]" <<<"$OUT"'

printf 'HARNESS_WORK=1\n' >"$HARNESS_ENV"
OUT=$(run_hook "$TMP_DIR/myproj-main")
assert "a work machine lists only work projects" 'grep -q "myproj" <<<"$OUT" && ! grep -q "other" <<<"$OUT"'
: >"$HARNESS_ENV"

OUT=$(WIKI_VAULT="$TMP_DIR/missing" CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" <<<'{"hook_event_name":"SessionStart"}')
assert "a missing vault gives empty context" '[ "$OUT" = "{}" ]'
assert "a missing vault is not created" '[ ! -e "$TMP_DIR/missing" ]'

echo ""
echo "=== wiki-sync status line ==="
WS="$HOME/.local/share/harness/wiki-sync"
NOW_MS=$(($(date +%s) * 1000))
ws_health() {
  mkdir -p "$WS/state"
  printf '{"ts":%d,"remote":"ok","feedTs":%d,"root":"ok","locked":false,"paused":false,"failing":[],"failedCount":0,"heldDeletions":0,"collisions":0,"noRemote":0,"regressed":0,"caughtUp":true}' \
    "$NOW_MS" "$NOW_MS" | jq -c "$1" >"$WS/state/health.json"
}
OUT=$(run_hook)
assert "no wiki-sync install: no status line" '! grep -q "WIKI-SYNC" <<<"$OUT"'
mkdir -p "$WS/state" "$TMP_DIR/syncwiki"
touch "$WS/stamp"
printf 'WIKI_SYNC_VAULT=%q\nWIKI_SYNC_DIR=%q\n' "$TMP_DIR" "$TMP_DIR/syncwiki" >"$WS/env"
OUT=$(run_hook)
assert "installed without health.json: not running" 'grep -q "WIKI-SYNC: not running (no health.json)" <<<"$OUT" && grep -q "journalctl --user -u wiki-sync" <<<"$OUT"'
ws_health .
OUT=$(run_hook)
assert "healthy service: no status line" '! grep -q "WIKI-SYNC" <<<"$OUT"'
ws_health ".ts -= 600000"
OUT=$(run_hook)
assert "stale health: not running" 'grep -q "not running (health is 10 min old)" <<<"$OUT"'
ws_health '.remote = "auth"'
OUT=$(run_hook)
assert "remote state is named" 'grep -q "CouchDB is auth" <<<"$OUT"'
ws_health ".locked = true"
OUT=$(run_hook)
assert "locked names reset.sh" 'grep -q "run reset.sh" <<<"$OUT"'
ws_health '.root = "missing"'
OUT=$(run_hook)
assert "missing root is reported" 'grep -q "wiki folder is missing" <<<"$OUT"'
ws_health ".heldDeletions = 23 | .collisions = 1 | .noRemote = 2 | .regressed = 3"
OUT=$(run_hook)
assert "held counts are reported" 'grep -q "23 local deletions held" <<<"$OUT" && grep -q "1 case collisions held" <<<"$OUT" && grep -q "2 paths held with no remote doc" <<<"$OUT" && grep -q "3 paths held because the remote went backwards" <<<"$OUT"'
ws_health "[.failing = ([range(6)] | map({path: \"wiki/f\\(.).md\", since: ($NOW_MS - 120000)}))][0] | .failedCount = 7"
OUT=$(run_hook)
assert "paths failing past one retry are named, five at most" 'grep -q "failing: wiki/f0.md, wiki/f1.md, wiki/f2.md, wiki/f3.md, wiki/f4.md (+2 more)" <<<"$OUT"'
ws_health ".failing = [{path: \"wiki/new.md\", since: $NOW_MS}] | .failedCount = 1"
OUT=$(run_hook)
assert "a path that just failed is not named yet" '! grep -q "WIKI-SYNC" <<<"$OUT"'
ws_health .
touch "$TMP_DIR/syncwiki/n.conflict-20261030T000000-abcdef01.md"
mkdir -p "$WS/recovered/wiki"
touch "$WS/recovered/wiki/a.md" "$WS/recovered/wiki/b.md"
OUT=$(run_hook)
assert "conflict copies and kept versions are counted" 'grep -q "1 \*.conflict-\* copies in $TMP_DIR/syncwiki" <<<"$OUT" && grep -q "2 kept versions in $WS/recovered" <<<"$OUT"'
assert "the status line comes before the wiki context" '[[ "$(head -1 <<<"$OUT")" == WIKI-SYNC:* ]] && grep -q "WIKI: project=myproj" <<<"$OUT"'
CUR=$(WIKI_VAULT="$VAULT" CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" <<<'{"hook_event_name":"sessionStart","cursor_version":"1.0"}' | jq -r '.additional_context // empty')
assert "cursor shape carries the status line" 'grep -q "WIKI-SYNC" <<<"$CUR"'
EARLY=$(WIKI_VAULT="$TMP_DIR/missing" CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" <<<'{"hook_event_name":"SessionStart"}')
assert "an early exit still carries the status line (claude shape)" 'jq -e ".hookSpecificOutput.additionalContext | startswith(\"WIKI-SYNC\")" <<<"$EARLY" >/dev/null'
EARLY=$(WIKI_VAULT="" CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" <<<'{"hook_event_name":"sessionStart","cursor_version":"1.0"}')
assert "an early exit still carries the status line (cursor shape)" 'jq -e ".additional_context | startswith(\"WIKI-SYNC\")" <<<"$EARLY" >/dev/null'
rm -rf "$WS"

echo ""
echo "session-start-wiki: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
