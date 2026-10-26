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

ROLE="$REPO_ROOT/configs/claude-code/bin/crew-role"
CALLS="$TMP_DIR/herdr.calls"

mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_HERDR_CALLS"
[[ "$1 $2" == "pane list" ]] || { echo '{"error":{"code":"unsupported","message":"fake herdr"}}'; exit 1; }
case "${FAKE_HERDR_MODE:-ok}" in
  fail)
    echo '{"error":{"code":"server_unreachable","message":"herdr server is not running"}}'
    exit 1
    ;;
  noagent)
    echo '{"result":{"panes":[{"pane_id":"wB:p1","agent":null,"agent_status":"unknown","cwd":"/x","tab_id":"wB:t1"}]}}'
    ;;
  absent)
    echo '{"result":{"panes":[{"pane_id":"wB:p7","agent":"claude","agent_session":{"value":"S1"},"agent_status":"idle","cwd":"/x","tab_id":"wB:t7"}]}}'
    ;;
  ok)
    printf '{"result":{"panes":[{"pane_id":"wB:p3","agent":"claude","agent_session":{"value":"OTHER"},"agent_status":"idle","cwd":"/x","tab_id":"wB:t3"},{"pane_id":"wB:p1","agent":"claude","agent_session":{"value":"%s"},"agent_status":"working","cwd":"/x","tab_id":"wB:t1"}]}}\n' "$FAKE_HERDR_SESSION"
    ;;
esac
EOF
chmod +x "$TMP_DIR/bin/herdr"
export PATH="$TMP_DIR/bin:$PATH" FAKE_HERDR_CALLS="$CALLS" FAKE_HERDR_SESSION=S1

OUT=""
ERR=""
RC=0
run_role() {
  local dir="$1"
  shift
  RC=0
  OUT=$(cd "$dir" && "$ROLE" "$@" 2>"$TMP_DIR/err") || RC=$?
  ERR=$(cat "$TMP_DIR/err")
}
answers() {
  local want="$1"
  shift
  run_role "$@"
  [[ $RC -eq 0 && "$OUT" == "$want" ]]
}
fails_quietly() {
  run_role "$@"
  [[ $RC -ne 0 && -z "$OUT" && -n "$ERR" ]]
}

MAIN="$TMP_DIR/repo"
git init -q "$MAIN"
git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
MAIN=$(cd "$MAIN" && pwd -P)
WT="$MAIN/.claude/worktrees/w-1"
git -C "$MAIN" worktree add -q -b w/1 "$WT"
mkdir -p "$TMP_DIR/norepo"
CREW="$MAIN/.claude/crew"

assert "outside a git repo is none" 'HERDR_PANE_ID=wB:p1 answers none "$TMP_DIR/norepo"'
command rm -rf "$CREW"
assert "a repo with no crew dir is none" 'HERDR_PANE_ID=wB:p1 answers none "$MAIN"'
mkdir -p "$CREW"
assert "a crew dir with no lead file is none" 'HERDR_PANE_ID=wB:p1 answers none "$MAIN"'

assert "HARNESS_UNATTENDED=1 is worker in the main checkout" 'HARNESS_UNATTENDED=1 answers worker "$MAIN"'
assert "HARNESS_UNATTENDED=1 is worker in a worktree" 'HARNESS_UNATTENDED=1 answers worker "$WT"'
assert "HARNESS_UNATTENDED=1 is worker outside a repo" 'HARNESS_UNATTENDED=1 answers worker "$TMP_DIR/norepo"'

printf 'wB:p1\tS1\n' >"$CREW/lead"

assert "worker wins even in the lead's pane" 'HARNESS_UNATTENDED=1 HERDR_PANE_ID=wB:p1 answers worker "$MAIN" --session S1'
assert "HARNESS_UNATTENDED=0 is not worker" 'HARNESS_UNATTENDED=0 HERDR_PANE_ID=wB:p9 answers none "$MAIN"'

: >"$CALLS"
assert "outside herdr is none" 'answers none "$MAIN"'
assert "another pane is none" 'HERDR_PANE_ID=wB:p9 answers none "$MAIN"'
assert "another pane never asks herdr" '[[ ! -s "$CALLS" ]]'
assert "another pane is none even when herdr is down" 'FAKE_HERDR_MODE=fail HERDR_PANE_ID=wB:p9 answers none "$MAIN"'

assert "lead pane with the lead's session id is lead" 'HERDR_PANE_ID=wB:p1 answers lead "$MAIN" --session S1'
assert "lead from a worktree cwd" 'HERDR_PANE_ID=wB:p1 answers lead "$WT" --session S1'
assert "lead with the worktree passed as dir" 'HERDR_PANE_ID=wB:p1 answers lead "$TMP_DIR/norepo" --session S1 "$WT"'
assert "lead with the dir before --session" 'HERDR_PANE_ID=wB:p1 answers lead "$TMP_DIR/norepo" "$MAIN" --session S1'
: >"$CALLS"
assert "lead pane with a different session id is none" 'HERDR_PANE_ID=wB:p1 answers none "$MAIN" --session S2'
assert "a passed session id needs no herdr call" '[[ ! -s "$CALLS" ]]'

assert "without --session the session id comes from herdr" 'HERDR_PANE_ID=wB:p1 answers lead "$MAIN"'
assert "herdr session id works from a worktree" 'HERDR_PANE_ID=wB:p1 answers lead "$WT"'
assert "a stale session in the lead's pane is none" 'FAKE_HERDR_SESSION=S-new HERDR_PANE_ID=wB:p1 answers none "$MAIN"'

assert "a failing herdr exits non-zero and prints nothing" 'FAKE_HERDR_MODE=fail HERDR_PANE_ID=wB:p1 fails_quietly "$MAIN"'
assert "the herdr error reaches stderr" '[[ "$ERR" == *"herdr server is not running"* ]]'
assert "the lead pane with no agent_session exits non-zero and prints nothing" 'FAKE_HERDR_MODE=noagent HERDR_PANE_ID=wB:p1 fails_quietly "$MAIN"'
assert "the lead pane missing from herdr exits non-zero and prints nothing" 'FAKE_HERDR_MODE=absent HERDR_PANE_ID=wB:p1 fails_quietly "$MAIN"'
assert "an empty --session is a usage error" 'HERDR_PANE_ID=wB:p1 fails_quietly "$MAIN" --session ""'

command rm -f "$CREW/lead"
assert "none once the lead file is deleted" 'HERDR_PANE_ID=wB:p1 answers none "$MAIN" --session S1'
assert "none once the lead file is deleted, via herdr" 'HERDR_PANE_ID=wB:p1 answers none "$MAIN"'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
