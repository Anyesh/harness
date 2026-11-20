#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

unset HARNESS_UNATTENDED HARNESS_NOTIFY HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH
while read -r v; do unset "$v"; done < <(compgen -e | grep '^GIT_CONFIG' || true)

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
HOOK="$REPO_ROOT/configs/claude-code/hooks/session-start-crew-memory.sh"
mkdir -p "$TMP_DIR/bin"
command cp "$REPO_ROOT/configs/claude-code/bin/crew-lib.sh" "$TMP_DIR/bin/"
chmod +x "$TMP_DIR/bin/crew-lib.sh"
export PATH="$TMP_DIR/bin:$PATH"
export HOME="$TMP_DIR/home"
mkdir -p "$HOME"
export CREW_HOOKS_DIR="$REPO_ROOT/configs/shared/hooks"
export WIKI_VAULT="$TMP_DIR/vault"
unset HARNESS_WORK
WIKI="$WIKI_VAULT/wiki/projects"

new_repo() {
  git init -q "$1"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

RC=0
OUT=""
run_hook() {
  RC=0
  OUT=$(jq -cn --arg c "$1" '{hook_event_name:"SessionStart",cwd:$c}' | bash "$HOOK" 2>&1) || RC=$?
}
context() {
  jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$OUT"
}

echo "=== session-start-crew-memory ==="

APP="$TMP_DIR/app"
new_repo "$APP"

run_hook "$APP"
assert "a repo with no crew folder prints nothing" '[[ $RC -eq 0 && -z "$OUT" ]]'

mkdir -p "$WIKI/app/crew/runs/r1" "$WIKI/app/crew/runs/r2"
: >"$WIKI/app/crew/runs/r2/summary.md"
run_hook "$APP"
assert "a repo with a crew folder prints one CREW-MEMORY line" '[[ $(context) == "CREW-MEMORY: $WIKI/app/crew, 2 runs" ]]'
assert "no CREW-PROPOSALS line outside the harness repo" '[[ $(context) != *CREW-PROPOSALS* ]]'

rmdir "$WIKI/app/crew/runs/r1"
command rm -rf "$WIKI/app/crew/runs/r2"
run_hook "$APP"
assert "a crew folder with no runs says 0 runs" '[[ $(context) == "CREW-MEMORY: $WIKI/app/crew, 0 runs" ]]'

run_hook "$TMP_DIR"
assert "a directory outside a git repo prints nothing" '[[ $RC -eq 0 && -z "$OUT" ]]'

HARNESS="$TMP_DIR/harness"
new_repo "$HARNESS"
mkdir -p "$HARNESS/configs/shared/skills/crew"
: >"$HARNESS/install.sh"
: >"$HARNESS/configs/shared/skills/crew/SKILL.md"
run_hook "$HARNESS"
assert "no proposals file prints nothing" '[[ -z "$OUT" ]]'

mkdir -p "$WIKI/harness/crew-proposals"
printf '# Proposed\n\nnotes only\n' >"$WIKI/harness/crew-proposals/proposed.md"
run_hook "$HARNESS"
assert "a proposals file without rule lines prints no CREW-PROPOSALS line" '[[ $(context) != *CREW-PROPOSALS* ]]'

printf -- '- one (2026-11-20, app)\n- two (2026-11-20, app)\n' >>"$WIKI/harness/crew-proposals/proposed.md"
run_hook "$HARNESS"
assert "the harness repo prints only CREW-PROPOSALS with the rule count" '[[ $(context) == "CREW-PROPOSALS: 2 pending" ]]'

run_hook "$APP"
assert "a project repo never prints CREW-PROPOSALS" '[[ $(context) != *CREW-PROPOSALS* ]]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
