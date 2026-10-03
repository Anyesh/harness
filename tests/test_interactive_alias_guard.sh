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
HOOK_STAGE="$TMP_DIR/hooks"
mkdir -p "$HOOK_STAGE"
command cp "$REPO_ROOT"/configs/shared/hooks/* "$REPO_ROOT"/configs/claude-code/hooks/* "$HOOK_STAGE/"
HOOK="$HOOK_STAGE/pre-bash-interactive-alias.sh"
trap 'rm -rf "$TMP_DIR"' EXIT

ALIASED_HOME="$TMP_DIR/aliased"
PLAIN_HOME="$TMP_DIR/plain"
VERBOSE_HOME="$TMP_DIR/verbose"
BASH_FMT_HOME="$TMP_DIR/bashfmt"
mkdir -p "$ALIASED_HOME/.claude/shell-snapshots" "$PLAIN_HOME/.claude" \
  "$VERBOSE_HOME/.claude/shell-snapshots" "$BASH_FMT_HOME/.claude/shell-snapshots"

cat > "$ALIASED_HOME/.claude/shell-snapshots/snapshot-zsh-1-abc.sh" <<'EOF'
alias -- cp='cp -i'
alias -- ls='ls --color=tty'
alias -- mv='mv -i'
alias -- rm='rm -i'
EOF
cat > "$VERBOSE_HOME/.claude/shell-snapshots/snapshot-zsh-1-abc.sh" <<'EOF'
alias -- rm='rm -v'
alias -- cp='cp --verbose'
EOF
cat > "$BASH_FMT_HOME/.claude/shell-snapshots/snapshot-bash-1-abc.sh" <<'EOF'
alias rm='rm -i'
EOF

RC=0
ERR=""
run_hook() {
  local home="$1" cmd="$2" payload
  payload=$(jq -cn --arg c "$cmd" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}')
  RC=0
  ERR=$(HOME="$home" CLAUDE_CONFIG_DIR="$home/.claude" bash "$HOOK" <<<"$payload" 2>&1 >/dev/null) || RC=$?
}

denied() { run_hook "$1" "$2"; [[ $RC -eq 2 ]]; }
allowed() { run_hook "$1" "$2"; [[ $RC -eq 0 && -z "$ERR" ]]; }

echo ""
echo "## aliased rm/cp/mv (interactive)"
assert "bare rm is denied" 'denied "$ALIASED_HOME" "rm foo.txt"'
assert "rm -r without -f is denied" 'denied "$ALIASED_HOME" "rm -r build"'
assert "denial message names the fix" 'run_hook "$ALIASED_HOME" "rm foo"; grep -q "command rm" <<<"$ERR"'
assert "denial message says the alias is interactive" 'run_hook "$ALIASED_HOME" "rm foo"; grep -q "rm -i" <<<"$ERR"'
assert "bare cp is denied" 'denied "$ALIASED_HOME" "cp a b"'
assert "bare mv is denied" 'denied "$ALIASED_HOME" "mv a b"'
assert "rm after && is denied" 'denied "$ALIASED_HOME" "cd x && rm y"'
assert "rm after ; is denied" 'denied "$ALIASED_HOME" "echo hi; mv a b"'
assert "rm in a pipe segment is denied" 'denied "$ALIASED_HOME" "ls | rm"'
assert "rm on a later line is denied" 'denied "$ALIASED_HOME" $'"'"'echo hi\nrm x'"'"
assert "rm -f is allowed because -f overrides the alias -i" 'allowed "$ALIASED_HOME" "rm -f foo"'
assert "rm -rf is allowed" 'allowed "$ALIASED_HOME" "rm -rf build"'
assert "rm --force is allowed" 'allowed "$ALIASED_HOME" "rm --force foo"'
assert "rm with -f after the operand is allowed" 'allowed "$ALIASED_HOME" "rm foo -f"'
assert "mv -f is allowed" 'allowed "$ALIASED_HOME" "mv -f a b"'
assert "rm -fi is denied because the later -i wins" 'denied "$ALIASED_HOME" "rm -fi foo"'
assert "rm -f -I is denied" 'denied "$ALIASED_HOME" "rm -f -I foo"'
assert "-f after -- is a filename, so rm is denied" 'denied "$ALIASED_HOME" "rm -- -f"'
assert "cp -f is denied because cp -f does not cancel -i" 'denied "$ALIASED_HOME" "cp -f a b"'
assert "a forced rm does not excuse a later bare rm" 'denied "$ALIASED_HOME" "rm -f a; rm b"'
assert "bare rm before ; is denied" 'denied "$ALIASED_HOME" "rm a; echo done"'
assert "command rm is allowed" 'allowed "$ALIASED_HOME" "command rm -f foo"'
assert "backslash rm is allowed" 'allowed "$ALIASED_HOME" "\\rm -f foo"'
assert "absolute-path rm is allowed" 'allowed "$ALIASED_HOME" "/bin/rm -f foo"'
assert "git rm is allowed" 'allowed "$ALIASED_HOME" "git rm foo"'
assert "xargs rm is allowed" 'allowed "$ALIASED_HOME" "find . -name x | xargs rm -f"'
assert "find -exec rm is allowed" 'allowed "$ALIASED_HOME" "find . -exec rm {} ;"'
assert "sudo rm is allowed" 'allowed "$ALIASED_HOME" "sudo rm foo"'
assert "unrelated command is allowed" 'allowed "$ALIASED_HOME" "ls -la"'
assert "word containing rm is allowed" 'allowed "$ALIASED_HOME" "echo confirm; npm run format"'
assert "unaliased ln is allowed" 'allowed "$ALIASED_HOME" "ln -s a b"'
assert "rm inside a double-quoted message is allowed" 'allowed "$ALIASED_HOME" "git commit -m \"done; rm stays\""'
assert "rm inside single quotes is allowed" 'allowed "$ALIASED_HOME" "echo '"'"'a; rm b'"'"'"'
assert "escaped quote does not end the string" 'allowed "$ALIASED_HOME" "echo \"a \\\" ; rm b\""'
assert "rm after a closed quote is denied" 'denied "$ALIASED_HOME" "echo \"hi\"; rm x"'
assert "rm in a heredoc body is allowed" 'allowed "$ALIASED_HOME" $'"'"'python3 - <<EOF\nx = 1 && rm y\nEOF'"'"
QUOTED_HEREDOC=$'cat <<\'EOF\'\nrm y\nEOF'
assert "rm in a quoted-delimiter heredoc body is allowed" 'allowed "$ALIASED_HOME" "$QUOTED_HEREDOC"'
assert "rm after the heredoc ends is denied" 'denied "$ALIASED_HOME" $'"'"'cat <<EOF\nhi\nEOF\nrm x'"'"
assert "quoted rm inside bash -c is allowed" 'allowed "$ALIASED_HOME" "bash -c \"rm x\""'

echo ""
echo "## systems without the alias"
assert "no snapshot dir allows rm" 'allowed "$PLAIN_HOME" "rm foo"'
assert "non-interactive aliases allow rm" 'allowed "$VERBOSE_HOME" "rm foo"'
assert "non-interactive aliases allow cp" 'allowed "$VERBOSE_HOME" "cp a b"'

echo ""
echo "## alias syntax variants"
assert "bash-format alias (no --) is detected" 'denied "$BASH_FMT_HOME" "rm foo"'

echo ""
echo "## input robustness"
assert "empty command exits 0" 'allowed "$ALIASED_HOME" ""'
assert "garbage stdin exits 0" 'RC=0; HOME="$ALIASED_HOME" CLAUDE_CONFIG_DIR="$ALIASED_HOME/.claude" bash "$HOOK" <<<"not json" >/dev/null 2>&1 || RC=$?; [[ $RC -eq 0 ]]'

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
