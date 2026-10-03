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
trap 'chmod -R u+w "$TMP_DIR"; command rm -rf "$TMP_DIR"' EXIT

# Claude deploys shared and claude-code hooks into one directory, and the
# guards find log-block.sh next to themselves, so test that layout.
SHARED="$TMP_DIR/hooks"
CLAUDE_HOOKS="$SHARED"
mkdir -p "$SHARED"
command cp "$REPO_ROOT"/configs/shared/hooks/* "$REPO_ROOT"/configs/claude-code/hooks/* "$SHARED/"

FAKE_HOME="$TMP_DIR/home"
mkdir -p "$FAKE_HOME/.claude/shell-snapshots"
printf "alias -- rm='rm -i'\n" >"$FAKE_HOME/.claude/shell-snapshots/snapshot-zsh-1-abc.sh"
LOG="$TMP_DIR/blocks.jsonl"
EM_DASH=$(printf '\342\200\224')

RC=0
run_hook() {
  local hook="$1" payload="$2" log="${3:-$LOG}" runner=bash
  [[ "$hook" == *.py ]] && runner=python3
  [[ "$log" == "$LOG" ]] && : >"$LOG"
  RC=0
  (cd "$TMP_DIR" && HOME="$FAKE_HOME" CLAUDE_CONFIG_DIR="$FAKE_HOME/.claude" HARNESS_BLOCK_LOG="$log" \
    "$runner" "$hook" <<<"$payload" >/dev/null 2>&1) || RC=$?
}

bash_payload() { jq -cn --arg c "$1" '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"s1",cwd:"/work",tool_input:{command:$c}}'; }
write_payload() { jq -cn --arg p "$1" --arg c "$2" '{hook_event_name:"PreToolUse",tool_name:"Write",session_id:"s1",tool_input:{file_path:$p,content:$c}}'; }

logged() { [[ $(wc -l <"$LOG") -eq 1 ]] && jq -e "$1" "$LOG" >/dev/null; }
not_logged() { [[ ! -s "$LOG" ]]; }

echo "=== block log ==="

run_hook "$SHARED/cost-guard.sh" "$(bash_payload 'docker logs web')"
assert "cost-guard logs its block" 'logged ".hook == \"cost-guard\" and .event == \"PreToolUse\" and .tool == \"Bash\" and .detail == \"docker logs web\" and .session == \"s1\" and .cwd == \"/work\" and (.ts | test(\"^[0-9]{4}-\"))"'
run_hook "$SHARED/cost-guard.sh" "$(bash_payload 'docker logs --tail 5 web')"
assert "cost-guard logs nothing when it allows" 'not_logged'

run_hook "$SHARED/pre-bash-guard.sh" "$(bash_payload 'git push --force origin main')"
assert "pre-bash-guard logs a Claude block" '[[ $RC -eq 2 ]] && logged ".hook == \"pre-bash-guard\" and .agent == \"claude\""'
run_hook "$SHARED/pre-bash-guard.sh" "$(jq -cn '{hook_event_name:"beforeShellExecution",cursor_version:"1",command:"git push -f origin main"}')"
assert "pre-bash-guard logs a Cursor deny" 'logged ".hook == \"pre-bash-guard\" and .agent == \"cursor\" and .detail == \"git push -f origin main\""'
run_hook "$SHARED/pre-bash-guard.sh" "$(bash_payload 'git status')"
assert "pre-bash-guard logs nothing when it allows" 'not_logged'

run_hook "$CLAUDE_HOOKS/pre-bash-interactive-alias.sh" "$(bash_payload 'rm foo')"
assert "alias guard logs its block" 'logged ".hook == \"pre-bash-interactive-alias\""'
run_hook "$CLAUDE_HOOKS/pre-bash-interactive-alias.sh" "$(bash_payload 'rm -f foo')"
assert "alias guard logs nothing when it allows" 'not_logged'

run_hook "$SHARED/pre-edit-code-quality.sh" "$(write_payload "$TMP_DIR/a.md" "a $EM_DASH b")"
assert "code-quality logs its block with the file path" 'logged ".hook == \"pre-edit-code-quality\" and .tool == \"Write\" and .detail == \"$TMP_DIR/a.md\""'
run_hook "$SHARED/pre-edit-code-quality.sh" "$(write_payload "$TMP_DIR/a.md" 'plain text')"
assert "code-quality logs nothing when it allows" 'not_logged'

run_hook "$SHARED/pre-edit-comment-guard.py" "$(write_payload "$TMP_DIR/a.py" $'# Set the user\nuser = 1\n')"
assert "comment guard logs its block" '[[ $RC -eq 2 ]] && logged ".hook == \"pre-edit-comment-guard\" and .detail == \"$TMP_DIR/a.py\""'
run_hook "$SHARED/pre-edit-comment-guard.py" "$(write_payload "$TMP_DIR/a.py" $'user = 1\n')"
assert "comment guard logs nothing when it allows" 'not_logged'

TRANSCRIPT="$TMP_DIR/t.jsonl"
jq -cn '{type:"assistant",message:{content:[{type:"text",text:"For now I will stub out for now the parser."}]}}' >"$TRANSCRIPT"
run_hook "$SHARED/stop-sloppiness-guard.sh" "$(jq -cn --arg t "$TRANSCRIPT" '{hook_event_name:"Stop",session_id:"s2",transcript_path:$t}')"
assert "sloppiness guard logs its block" 'logged ".hook == \"stop-sloppiness-guard\" and .event == \"Stop\" and .session == \"s2\""'

mkdir -p "$TMP_DIR/ro" && chmod 500 "$TMP_DIR/ro"
run_hook "$SHARED/cost-guard.sh" "$(bash_payload 'docker logs web')" "$TMP_DIR/ro/sub/blocks.jsonl"
assert "an unwritable log does not change the decision" '[[ $RC -eq 2 ]]'

long=$(printf 'x%.0s' {1..2000})
run_hook "$SHARED/cost-guard.sh" "$(bash_payload "docker logs $long")"
assert "long details are truncated" 'logged "(.detail | length) <= 500"'

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
