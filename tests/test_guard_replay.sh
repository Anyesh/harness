#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPLAY="$REPO_ROOT/scripts/guard-replay.sh"

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

FAKE_HOME="$TMP_DIR/home"
CONFIG="$FAKE_HOME/.claude"
mkdir -p "$CONFIG/shell-snapshots" "$CONFIG/projects/-work/sess1/subagents" "$TMP_DIR/work"
printf "alias -- rm='rm -i'\n" >"$CONFIG/shell-snapshots/snapshot-zsh-1-abc.sh"

tool_use() {
  jq -cn --arg cwd "$TMP_DIR/work" --arg name "$1" --argjson input "$2" \
    '{type:"assistant",cwd:$cwd,sessionId:"sess1",message:{content:[{type:"tool_use",name:$name,input:$input}]}}'
}
bash_call() { tool_use Bash "$(jq -cn --arg c "$1" '{command:$c}')"; }

{
  bash_call 'docker logs web'
  bash_call 'docker logs web'
  bash_call 'git status'
  bash_call 'git commit -m "tidy; rm stays quoted"'
  bash_call 'rm build.txt'
  tool_use Write "$(jq -cn --arg p "$TMP_DIR/work/a.py" '{file_path:$p,content:"# Set the user\nuser = 1\n"}')"
  tool_use Write "$(jq -cn --arg p "$TMP_DIR/work/b.py" '{file_path:$p,content:"user = 1\n"}')"
  jq -cn '{type:"user",message:{content:[{type:"tool_result",content:"ok"}]}}'
} >"$CONFIG/projects/-work/sess1.jsonl"
bash_call 'journalctl -u web' >"$CONFIG/projects/-work/sess1/subagents/agent-a1.jsonl"

OUT=$(HOME="$FAKE_HOME" CLAUDE_CONFIG_DIR="$CONFIG" bash "$REPLAY" --samples 5 2>&1) || true
field() { awk -v h="$1" -v c="$2" '$1 == h { print $c; exit }' <<<"$OUT"; }

echo "=== guard-replay ==="
assert "duplicate calls are replayed once" '[[ $(field cost-guard 2) == 5 ]]'
assert "cost-guard blocks the unbounded docker and journalctl calls" '[[ $(field cost-guard 3) == 2 ]]'
assert "subagent transcripts are included" 'grep -q "journalctl -u web" <<<"$OUT"'
assert "alias guard blocks only the bare rm" '[[ $(field pre-bash-interactive-alias 3) == 1 ]]'
assert "alias guard sample shows the command" 'grep -q "rm build.txt" <<<"$OUT"'
assert "comment guard checks only the Write calls" '[[ $(field pre-edit-comment-guard 2) == 2 ]]'
assert "comment guard blocks the narrative comment" '[[ $(field pre-edit-comment-guard 3) == 1 ]]'
assert "pre-bash-guard blocks nothing" '[[ $(field pre-bash-guard 3) == 0 ]]'
assert "samples carry the guard message" 'grep -q "Unbounded container logs" <<<"$OUT"'
assert "replay never writes the block log" '[[ ! -e "$FAKE_HOME/.local/state/harness/hook-blocks.jsonl" ]]'

OUT=$(HOME="$FAKE_HOME" CLAUDE_CONFIG_DIR="$CONFIG" bash "$REPLAY" --hook cost-guard 2>&1) || true
assert "--hook limits the replay to one guard" '[[ -n $(field cost-guard 3) && -z $(field pre-bash-guard 3) ]]'

OUT=$(HOME="$FAKE_HOME" CLAUDE_CONFIG_DIR="$TMP_DIR/empty" bash "$REPLAY" 2>&1) && RC=0 || RC=$?
assert "no transcripts is reported as an error" '[[ $RC -ne 0 ]] && grep -qi "no transcripts" <<<"$OUT"'

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
