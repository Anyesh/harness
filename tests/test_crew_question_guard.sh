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
export CREW_RUNS_DIR="$TMP_DIR/runs"
export HARNESS_BLOCK_LOG="$TMP_DIR/blocks.jsonl"

HOOK_STAGE="$TMP_DIR/hooks"
mkdir -p "$HOOK_STAGE"
command cp "$REPO_ROOT"/configs/shared/hooks/* "$REPO_ROOT"/configs/claude-code/hooks/* "$HOOK_STAGE/" 2>/dev/null || true
HOOK="$HOOK_STAGE/crew-question-guard.sh"

mkdir -p "$TMP_DIR/herdr-bin" "$TMP_DIR/role-bin" "$TMP_DIR/failing-bin" "$TMP_DIR/slow-bin"
cat >"$TMP_DIR/herdr-bin/herdr" <<'EOF'
#!/usr/bin/env bash
echo '{"error":{"code":"server_unreachable","message":"fake herdr reached"}}'
exit 1
EOF
ln -s "$REPO_ROOT/configs/claude-code/bin/crew-role" "$TMP_DIR/role-bin/crew-role"
printf '#!/usr/bin/env bash\necho "crew-role broke" >&2\nexit 3\n' >"$TMP_DIR/failing-bin/crew-role"
printf '#!/usr/bin/env bash\nsleep 5\necho lead\n' >"$TMP_DIR/slow-bin/crew-role"
chmod +x "$TMP_DIR"/*-bin/*

WITH_ROLE="$TMP_DIR/herdr-bin:$TMP_DIR/role-bin:$PATH"
NO_ROLE="$TMP_DIR/herdr-bin:/usr/bin:/bin"
FAILING_ROLE="$TMP_DIR/herdr-bin:$TMP_DIR/failing-bin:$PATH"
SLOW_ROLE="$TMP_DIR/herdr-bin:$TMP_DIR/slow-bin:$PATH"

MAIN="$TMP_DIR/repo"
git init -q "$MAIN"
git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
MAIN=$(cd "$MAIN" && pwd -P)
mkdir -p "$MAIN/.claude/crew"
printf 'wB:p1\tS1\n' >"$MAIN/.claude/crew/lead"

WORKER_TEXT="write the question to report.md with status question and stop"
LEAD_TEXT="a crew is running: write the plan into rulings.md and ask in plain text at the end of the turn (if you are in plan mode, ask the user to press Shift+Tab)"

RC=0
ERR=""
run_hook() {
  local tool="$1" session="$2" path="$3" payload
  payload=$(jq -cn --arg t "$tool" --arg s "$session" --arg c "$MAIN" \
    '{hook_event_name:"PreToolUse",session_id:$s,cwd:$c,tool_name:$t,tool_input:{}}')
  RC=0
  ERR=$(PATH="$path" bash "$HOOK" <<<"$payload" 2>&1 >/dev/null) || RC=$?
}
denied_with() {
  local text="$1"
  shift
  run_hook "$@"
  [[ $RC -eq 2 ]] && jq -e --arg r "BLOCKED by crew-question-guard: $text" \
    '.decision == "deny" and .reason == $r' <<<"$ERR" >/dev/null
}
allowed() {
  run_hook "$@"
  [[ $RC -eq 0 && -z "$ERR" ]]
}

assert "crew-role is not reachable on the no-role PATH" '! PATH="$NO_ROLE" command -v crew-role >/dev/null'

for tool in AskUserQuestion ExitPlanMode EnterPlanMode; do
  assert "worker is denied $tool" 'HARNESS_UNATTENDED=1 denied_with "$WORKER_TEXT" $tool S9 "$WITH_ROLE"'
  assert "worker is denied $tool with no crew-role on PATH" 'HARNESS_UNATTENDED=1 denied_with "$WORKER_TEXT" $tool S9 "$NO_ROLE"'
  assert "lead is denied $tool" 'HERDR_PANE_ID=wB:p1 denied_with "$LEAD_TEXT" $tool S1 "$WITH_ROLE"'
  assert "a non-crew pane is allowed $tool" 'HERDR_PANE_ID=wB:p9 allowed $tool S1 "$WITH_ROLE"'
  assert "a new session in the lead pane is allowed $tool" 'HERDR_PANE_ID=wB:p1 allowed $tool S2 "$WITH_ROLE"'
  assert "a session outside herdr is allowed $tool" 'allowed $tool S1 "$WITH_ROLE"'
  assert "a missing crew-role allows $tool" 'HERDR_PANE_ID=wB:p1 allowed $tool S1 "$NO_ROLE"'
  assert "a failing crew-role allows $tool" 'HERDR_PANE_ID=wB:p1 allowed $tool S1 "$FAILING_ROLE"'
done

assert "a crew-role error from herdr allows the call" 'HERDR_PANE_ID=wB:p1 allowed AskUserQuestion "" "$WITH_ROLE"'
start=$SECONDS
assert "a crew-role slower than two seconds allows the call" 'HERDR_PANE_ID=wB:p1 allowed AskUserQuestion S1 "$SLOW_ROLE"'
assert "the slow crew-role is cut off" '(( SECONDS - start < 5 ))'

: >"$HARNESS_BLOCK_LOG"
HERDR_PANE_ID=wB:p1 run_hook AskUserQuestion S1 "$WITH_ROLE"
assert "a block is logged" '[[ $(jq -r .hook "$HARNESS_BLOCK_LOG") == crew-question-guard ]]'
: >"$HARNESS_BLOCK_LOG"
HERDR_PANE_ID=wB:p9 run_hook AskUserQuestion S1 "$WITH_ROLE"
assert "an allowed call is not logged" '[[ ! -s "$HARNESS_BLOCK_LOG" ]]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
