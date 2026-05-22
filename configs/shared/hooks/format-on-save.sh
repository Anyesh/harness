#!/bin/bash
set -euo pipefail

input=$(cat)
# Cursor afterFileEdit: file_path at top level
# Claude Code PostToolUse: file_path nested under tool_input
file_path=$(echo "$input" | jq -r '.file_path // .tool_input.file_path // empty')

if [ -z "$file_path" ] || [ ! -f "$file_path" ]; then
  exit 0
fi

ext="${file_path##*.}"
formatted=""

case "$ext" in
  py)
    if command -v ruff &>/dev/null; then
      ruff format --quiet "$file_path" 2>/dev/null && formatted="ruff" || true
    elif command -v black &>/dev/null; then
      black --quiet "$file_path" 2>/dev/null && formatted="black" || true
    fi
    ;;
  rs)
    if command -v rustfmt &>/dev/null; then
      rustfmt --edition 2021 "$file_path" 2>/dev/null && formatted="rustfmt" || true
    fi
    ;;
  go)
    if command -v gofmt &>/dev/null; then
      gofmt -w "$file_path" 2>/dev/null && formatted="gofmt" || true
    fi
    ;;
  js|jsx|ts|tsx|css|scss|html|json|yaml|yml|md)
    if command -v prettier &>/dev/null; then
      prettier --write "$file_path" 2>/dev/null && formatted="prettier" || true
    fi
    ;;
  sh|bash)
    if command -v shfmt &>/dev/null; then
      shfmt -w "$file_path" 2>/dev/null && formatted="shfmt" || true
    fi
    ;;
esac

if [ -n "$formatted" ]; then
  echo "Auto-formatted ${file_path} with ${formatted}. File on disk may differ from what you wrote — re-read before further edits."
fi

exit 0
