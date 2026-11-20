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
SLEEPER=""
trap 'command rm -rf "$TMP_DIR"; [[ -n $SLEEPER ]] && kill "$SLEEPER" 2>/dev/null || true' EXIT
export HARNESS_BLOCK_LOG="$TMP_DIR/blocks.jsonl"

HOOK_STAGE="$TMP_DIR/hooks"
mkdir -p "$HOOK_STAGE" "$TMP_DIR/bin"
command cp "$REPO_ROOT"/configs/shared/hooks/* "$REPO_ROOT"/configs/claude-code/hooks/* "$HOOK_STAGE/" 2>/dev/null || true
command cp "$REPO_ROOT/configs/claude-code/bin/crew-lib.sh" "$TMP_DIR/bin/"
write_role() {
  printf '#!/usr/bin/env bash\n%s\n' "$1" >"$TMP_DIR/bin/crew-role"
  chmod +x "$TMP_DIR/bin/crew-role"
}
# shellcheck disable=SC2016
write_role 'echo "${FAKE_ROLE:-none}"'
export PATH="$TMP_DIR/bin:$PATH"
# shellcheck source=../configs/claude-code/bin/crew-lib.sh
. "$TMP_DIR/bin/crew-lib.sh"

MAIN="$TMP_DIR/repo"
git init -q "$MAIN"
git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
MAIN=$(cd "$MAIN" && pwd -P)
CREW="$MAIN/.claude/crew"
mkdir -p "$CREW/live" "$CREW/items"

sleep 300 &
SLEEPER=$!
SLEEPER_START=$(crew_pid_start "$SLEEPER")

RC=0
OUT=""
run_stop() {
  local hook="$1" payload="$2"
  RC=0
  OUT=$(bash "$HOOK_STAGE/$hook" <<<"$payload" 2>&1) || RC=$?
}
blocks_with() {
  [[ $RC -eq 0 ]] && jq -e --arg t "$1" '.decision == "block" and (.reason | contains($t))' <<<"$OUT" >/dev/null
}
silent() {
  [[ $RC -eq 0 && -z "$OUT" ]]
}

echo "=== crew-lead-stop-guard ==="

LEAD_TEXT="start crew-sweep with run_in_background before ending the turn"
lead_payload() {
  jq -cn --arg c "$MAIN" --argjson a "${1:-false}" \
    '{hook_event_name:"Stop",session_id:"S1",cwd:$c,stop_hook_active:$a}'
}
set_board() {
  printf 'a\t%s\t\tw/a\tmain\t\t\t\n' "$1" >"$CREW/board.tsv"
}
reset_lead() {
  command rm -rf "$CREW/live" "$CREW/paused"
  mkdir -p "$CREW/live"
  set_board assigned
}

reset_lead
FAKE_ROLE=lead run_stop crew-lead-stop-guard.sh "$(lead_payload)"
assert "lead with assigned rows and no sweep is blocked" 'blocks_with "$LEAD_TEXT"'
assert "the block is logged" '[[ $(jq -r .hook "$HARNESS_BLOCK_LOG") == crew-lead-stop-guard ]]'

FAKE_ROLE=lead run_stop crew-lead-stop-guard.sh "$(lead_payload true)"
assert "stop_hook_active ends the loop" 'silent'

printf '%s %s\n' "$SLEEPER" "$SLEEPER_START" >"$CREW/live/sweep.$SLEEPER"
FAKE_ROLE=lead run_stop crew-lead-stop-guard.sh "$(lead_payload)"
assert "a live sweep file keeps the guard silent" 'silent'

printf '%s %s\n' "$SLEEPER" "$((SLEEPER_START + 1))" >"$CREW/live/sweep.$SLEEPER"
FAKE_ROLE=lead run_stop crew-lead-stop-guard.sh "$(lead_payload)"
assert "a live file with a stale start time does not count" 'blocks_with "$LEAD_TEXT"'

reset_lead
printf '%s %s\n' "$SLEEPER" "$SLEEPER_START" >"$CREW/live/succession.$SLEEPER"
FAKE_ROLE=lead run_stop crew-lead-stop-guard.sh "$(lead_payload)"
assert "a live succession file keeps the guard silent" 'silent'

reset_lead
: >"$CREW/paused"
FAKE_ROLE=lead run_stop crew-lead-stop-guard.sh "$(lead_payload)"
assert "paused keeps the guard silent" 'silent'

reset_lead
set_board done
FAKE_ROLE=lead run_stop crew-lead-stop-guard.sh "$(lead_payload)"
assert "no assigned rows keeps the guard silent" 'silent'

reset_lead
command rm -f "$CREW/board.tsv"
FAKE_ROLE=lead run_stop crew-lead-stop-guard.sh "$(lead_payload)"
assert "no board keeps the guard silent" 'silent'

reset_lead
FAKE_ROLE=worker run_stop crew-lead-stop-guard.sh "$(lead_payload)"
assert "a worker is not guarded by the lead guard" 'silent'
FAKE_ROLE=none run_stop crew-lead-stop-guard.sh "$(lead_payload)"
assert "a non-crew session is not guarded" 'silent'
write_role 'exit 3'
run_stop crew-lead-stop-guard.sh "$(lead_payload)"
assert "a failing crew-role keeps the guard silent" 'silent'
# shellcheck disable=SC2016
write_role 'echo "${FAKE_ROLE:-none}"'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
