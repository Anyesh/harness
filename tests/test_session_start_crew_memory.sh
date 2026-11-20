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
export PATH="$TMP_DIR/bin:$PATH"
export CREW_MEMORY_DIR="$TMP_DIR/store"
export XDG_CONFIG_HOME="$CREW_MEMORY_DIR.xdg"
unset CREW_MEMORY_REMOTE

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
git -C "$APP" remote add origin git@example.com:acme/app.git

run_hook "$APP"
assert "a repo with no store entry prints nothing" '[[ $RC -eq 0 && -z "$OUT" ]]'

mkdir -p "$CREW_MEMORY_DIR/repos/app/runs/r1" "$CREW_MEMORY_DIR/repos/app/runs/r2"
printf 'example.com/acme/app\n' >"$CREW_MEMORY_DIR/repos/app/origin"
: >"$CREW_MEMORY_DIR/repos/app/runs/r2/summary.md"
run_hook "$APP"
assert "a repo with a store entry prints one CREW-MEMORY line" '[[ $(context) == "CREW-MEMORY: $CREW_MEMORY_DIR/repos/app, 2 runs" ]]'
assert "no CREW-PROPOSALS line outside the harness repo" '[[ $(context) != *CREW-PROPOSALS* ]]'

rmdir "$CREW_MEMORY_DIR/repos/app/runs/r1"
command rm -rf "$CREW_MEMORY_DIR/repos/app/runs/r2"
run_hook "$APP"
assert "an entry with no runs says 0 runs" '[[ $(context) == "CREW-MEMORY: $CREW_MEMORY_DIR/repos/app, 0 runs" ]]'

run_hook "$TMP_DIR"
assert "a directory outside a git repo prints nothing" '[[ $RC -eq 0 && -z "$OUT" ]]'

HARNESS="$TMP_DIR/harness"
new_repo "$HARNESS"
mkdir -p "$HARNESS/configs/shared/skills/crew"
: >"$HARNESS/install.sh"
: >"$HARNESS/configs/shared/skills/crew/SKILL.md"
mkdir -p "$CREW_MEMORY_DIR/rules"
run_hook "$HARNESS"
assert "no proposals file prints nothing" '[[ -z "$OUT" ]]'

printf '# Proposed\n\nnotes only\n' >"$CREW_MEMORY_DIR/rules/proposed.md"
run_hook "$HARNESS"
assert "a proposals file without rule lines prints nothing" '[[ -z "$OUT" ]]'

printf -- '- one (2026-11-20, app)\n- two (2026-11-20, app)\n' >>"$CREW_MEMORY_DIR/rules/proposed.md"
run_hook "$HARNESS"
assert "the harness repo prints CREW-PROPOSALS with the rule count" '[[ $(context) == "CREW-PROPOSALS: 2 pending" ]]'

mkdir -p "$CREW_MEMORY_DIR/repos/harness"
printf 'none\n' >"$CREW_MEMORY_DIR/repos/harness/origin"
run_hook "$HARNESS"
assert "the harness repo prints both lines when it has an entry" '[[ $(context) == *"CREW-MEMORY:"*"CREW-PROPOSALS: 2 pending" ]]'

run_hook "$APP"
assert "a project repo never prints CREW-PROPOSALS" '[[ $(context) != *CREW-PROPOSALS* ]]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
