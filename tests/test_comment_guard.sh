#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/configs/shared/hooks/pre-edit-comment-guard.py"

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
LOG="$TMP_DIR/blocks.jsonl"
ERR="$TMP_DIR/stderr.txt"

RC=0
run_guard() {
  RC=0
  HARNESS_BLOCK_LOG="$LOG" python3 "$HOOK" <<<"$1" >/dev/null 2>"$ERR" || RC=$?
}

write_payload() { jq -cn --arg p "$1" --arg c "$2" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$p,content:$c}}'; }
edit_payload() { jq -cn --arg p "$1" --arg o "$2" --arg n "$3" '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:$p,old_string:$o,new_string:$n}}'; }

blocks() { run_guard "$(write_payload "$TMP_DIR/$1" "$2")"; [[ $RC -eq 2 ]]; }
allows() { run_guard "$(write_payload "$TMP_DIR/$1" "$2")"; [[ $RC -eq 0 ]]; }

echo "=== comment guard: narration the guard used to miss ==="

assert "trailing period" 'blocks a.rs $'"'"'// Clear the unseeded buffers.\nlet x = 1;\n'"'"''
assert "no trailing period" 'blocks a.rs $'"'"'// Clear the unseeded buffers\nlet x = 1;\n'"'"''
assert "a flag's state described with set is allowed" 'allows a.rs $'"'"'/// Set while the taint memo has entries.\nlet x = 1;\n'"'"''
assert "a clause after a comma is left to the rule" 'allows a.rs $'"'"'/// Loads through a fresh handle, so nothing is served from a cached file.\nlet x = 1;\n'"'"''
assert "numbered step with period" 'blocks a.rs $'"'"'// 1. Clear the buffers.\nlet x = 1;\n'"'"''
assert "numbered step with paren" 'blocks a.py $'"'"'# 2) Parse the config\nx = 1\n'"'"''
assert "Step N colon" 'blocks a.py $'"'"'# Step 3: Load the file\nx = 1\n'"'"''
assert "label then dashes banner" 'blocks a.py $'"'"'# --- client\nx = 1\n'"'"''
assert "equals banner" 'blocks a.rs $'"'"'// ==== Helpers\nlet x = 1;\n'"'"''
assert "trailing run banner" 'blocks a.py $'"'"'# client ----\nx = 1\n'"'"''
assert "consecutive numbered steps" 'blocks a.js $'"'"'// 1. Clear the buffers\n// 2. Run each member\nfoo();\n'"'"''
assert "begin and end markers are not banners" 'allows a.sh $'"'"'# ---- BEGIN LICENSE\n# ---- END LICENSE\nx=1\n'"'"''
assert "multi-line python docstring that restates" 'blocks a.py $'"'"'def f(user_id):\n    """Get the user.\n\n    Args:\n        user_id: the user id\n\n    Returns:\n        The user.\n    """\n    return 1\n'"'"''
assert "multi-line JSDoc that restates" 'blocks a.ts $'"'"'/**\n * Get the user.\n * @param id the id\n * @returns the user\n */\nfunction f(id) {}\n'"'"''
assert "yaml step comment" 'blocks ci.yml $'"'"'steps:\n  # Install dependencies\n  - run: npm ci\n'"'"''
assert "yaml extension" 'blocks ci.yaml $'"'"'# Install dependencies\nkey: 1\n'"'"''
assert "toml comment" 'blocks c.toml $'"'"'# Set the port\nport = 1\n'"'"''
assert "Dockerfile comment" 'blocks Dockerfile $'"'"'# Install dependencies\nRUN npm ci\n'"'"''
assert "Dockerfile.dev comment" 'blocks Dockerfile.dev $'"'"'# Install dependencies\nRUN npm ci\n'"'"''
assert "Makefile comment" 'blocks Makefile $'"'"'# Build the binary\nall:\n\tcc x.c\n'"'"''

echo "=== comment guard: stays allowed ==="

assert "real WHY comment" 'allows a.py $'"'"'# retry once because the socket is closed by the proxy after idle\nx = 1\n'"'"''
assert "directives" 'allows a.py $'"'"'import os  # noqa\n# type: ignore\n# TODO: remove\n# ruff: noqa\nx = 1\n'"'"''
assert "eslint directive" 'allows a.ts $'"'"'// eslint-disable-next-line no-console\nconsole.log(1);\n'"'"''
assert "rustdoc table" 'allows a.rs $'"'"'/// ```text\n/// +----+----+\n/// | a  | b  |\n/// +----+----+\n/// ```\nfn f() {}\n'"'"''
assert "docstring with Raises prose" 'allows a.py $'"'"'def f():\n    """Return the balance in cents.\n\n    Raises KeyError for an unknown account."""\n    return 1\n'"'"''
assert "docstring with Raises section" 'allows a.py $'"'"'def f():\n    """Get the user.\n\n    Args:\n        user_id: the id\n\n    Raises:\n        KeyError: unknown id\n    """\n    return 1\n'"'"''
assert "docstring stating a constraint" 'allows a.py $'"'"'def f():\n    """Get the user.\n\n    The cache is keyed by tenant, so ids may repeat across tenants.\n    """\n    return 1\n'"'"''
assert "JSDoc with @throws" 'allows a.ts $'"'"'/**\n * Get the user.\n * @param id the id\n * @throws NotFound when missing\n */\nfunction f(id) {}\n'"'"''
assert "plain code" 'allows a.py $'"'"'x = 1\n'"'"''
assert "yaml schema comment" 'allows ci.yml $'"'"'# yaml-language-server: $schema=https://example.com/s.json\nkey: 1\n'"'"''

echo "=== comment guard: only added comments are judged ==="

assert "Edit whose old_string already holds the comment" 'run_guard "$(edit_payload "$TMP_DIR/a.rs" $'"'"'// Clear the buffers.\nlet a = 1;'"'"' $'"'"'// Clear the buffers.\nlet a = 2;'"'"')"; [[ $RC -eq 0 ]]'
assert "Edit adding a new narrating comment" 'run_guard "$(edit_payload "$TMP_DIR/a.rs" $'"'"'let a = 1;'"'"' $'"'"'// Clear the buffers.\nlet a = 1;'"'"')"; [[ $RC -eq 2 ]]'

printf '// Clear the buffers.\nlet a = 1;\n' >"$TMP_DIR/existing.rs"
assert "Write over a file that already holds the comment" 'allows existing.rs $'"'"'// Clear the buffers.\nlet a = 2;\n'"'"''

printf '// Clear the buffers.\nlet a = 1;\n' >"$TMP_DIR/beside.rs"
assert "new narration beside an old one blocks, naming only the new line" 'blocks beside.rs $'"'"'// Clear the buffers.\n// Open the socket.\nlet a = 1;\n'"'"'; grep -q "Open the socket" "$ERR" && ! grep -q "line 1 " "$ERR"'

printf '    """Get the user.\n\n    Args:\n        x: the x\n    """\n' >"$TMP_DIR/old_doc.py"
assert "Write over a file holding the same docstring" 'allows old_doc.py $'"'"'def f(x):\n    """Get the user.\n\n    Args:\n        x: the x\n    """\n    return 1\n'"'"''

assert "deny text no longer advises a because marker" 'blocks a.rs $'"'"'// Clear the buffers.\n'"'"'; ! grep -qi "add a" "$ERR" && grep -qi "marker" "$ERR"'
assert "block is logged" 'blocks a.rs $'"'"'// Clear the buffers.\n'"'"'; jq -e ".hook == \"pre-edit-comment-guard\"" "$LOG" >/dev/null'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
