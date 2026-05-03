#!/bin/bash
set -uo pipefail

# PreToolUse hook: blocks large-output operations on main thread to avoid
# context inflation. Each turn re-sends full conversation as input, so large
# tool outputs compound cost on every subsequent turn.
#
# Philosophy: block unbounded output, allow bounded output. If a command is
# piped to head/tail/wc/grep or uses flags that limit output (-l, -c, --count,
# --tail), it's bounded and safe.

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

case "$TOOL_NAME" in
  Read|Bash) ;;
  *) exit 0 ;;
esac

block_with_message() {
  local reason="$1" command="$2"
  cat >&2 <<EOF
[hook:cost-guard] BLOCKED: $reason
Command: $command

COST RULE: Large outputs inflate main context permanently.
Options:
  1. Pipe to head/tail/wc/grep to limit output
  2. Delegate to subagent: Agent({ model: "sonnet", prompt: "Run and summarize: ..." })
  3. Add -l (filenames only) or -c (counts only) flags
EOF
  exit 2
}

if [[ "$TOOL_NAME" == "Read" ]]; then
  FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  [[ -z "$FILE_PATH" || ! -f "$FILE_PATH" ]] && exit 0

  FILE_SIZE=$(stat -c%s "$FILE_PATH" 2>/dev/null || stat -f%z "$FILE_PATH" 2>/dev/null || echo 0)
  LINE_COUNT=$(wc -l < "$FILE_PATH" 2>/dev/null || echo 0)

  # Only block large files that are logs/output (not source code being edited)
  if [[ $FILE_SIZE -gt 102400 || $LINE_COUNT -gt 2000 ]]; then
    case "$FILE_PATH" in
      *.log|*.jsonl|*transcript*|*/debug/*|*/logs/*|*/output/*|*.out|*.csv)
        cat >&2 <<EOF
[hook:cost-guard] BLOCKED: Large log/output file (${FILE_SIZE} bytes, ${LINE_COUNT} lines)
File: $FILE_PATH

COST RULE: Large file reads inflate main context.
Delegate to subagent: Agent({ model: "sonnet", prompt: "Read $FILE_PATH and [extract/summarize]" })
EOF
        exit 2
        ;;
    esac
  fi
  exit 0
fi

if [[ "$TOOL_NAME" == "Bash" ]]; then
  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  [[ -z "$COMMAND" ]] && exit 0

  # Safe: command is piped to something that limits output
  # Match: | head, | tail (without huge -n), | wc, | grep, | sort | head, | cut
  if echo "$COMMAND" | grep -qE '\|\s*(head|wc|grep|cut|awk|sort\s*\|)' ; then
    exit 0
  fi
  # tail with small number is fine
  if echo "$COMMAND" | grep -qE '\|\s*tail\s+(-n\s*)?[0-9]{1,2}\b'; then
    exit 0
  fi

  # Safe: grep with -l (filenames only), -c (counts), -L (non-matching files)
  if echo "$COMMAND" | grep -qE 'grep\s+(-[a-zA-Z]*[lcL])'; then
    exit 0
  fi
  # Also safe: grep -rl, grep --count, grep --files-with-matches
  if echo "$COMMAND" | grep -qE 'grep\s+--?(files-with|count)'; then
    exit 0
  fi

  # Safe: find with -name filter (scoped, not a full tree dump)
  if echo "$COMMAND" | grep -qE 'find\s+\S+.*-name'; then
    exit 0
  fi

  # Safe: tail/head with small numbers (default or <100 lines)
  if echo "$COMMAND" | grep -qE '(^|\s)(tail|head)(\s+-[0-9]{1,2}\b|\s+-n\s*[0-9]{1,2}\b|\s+)'; then
    exit 0
  fi

  # Safe: commands with explicit --limit, --max-count, --tail flags
  if echo "$COMMAND" | grep -qE '--(limit|max-count|tail|max-results)\s*[=\s]?[0-9]'; then
    exit 0
  fi

  # Now check for dangerous patterns (unbounded output)

  # docker/kubectl logs without --tail
  if echo "$COMMAND" | grep -qEi '^(docker|kubectl)\s+logs' ; then
    if ! echo "$COMMAND" | grep -qE '--tail'; then
      block_with_message "Unbounded container logs (add --tail N)" "$COMMAND"
    fi
  fi

  # journalctl without -n or --lines limit
  if echo "$COMMAND" | grep -qE '^\s*journalctl' ; then
    if ! echo "$COMMAND" | grep -qE '(-n\s*[0-9]|--lines)'; then
      block_with_message "Unbounded journalctl (add -n N)" "$COMMAND"
    fi
  fi

  # cat/less on log files
  if echo "$COMMAND" | grep -qEi '\b(cat|less)\b.*\.(log|jsonl|csv|out)\b'; then
    block_with_message "Unbounded read of log file (use head/tail or subagent)" "$COMMAND"
  fi

  # tail with large line count (>200)
  if echo "$COMMAND" | grep -qE 'tail\s+(-n\s*|-)[0-9]{3,}'; then
    block_with_message "Large tail (>200 lines enters context)" "$COMMAND"
  fi

  # find from root (/) without pipe
  if echo "$COMMAND" | grep -qE '\bfind\s+/\s' ; then
    block_with_message "find from / produces massive output (scope to specific dir)" "$COMMAND"
  fi

  # Recursive grep without output-limiting flags, on broad scope
  # Block: grep -r "pattern" . (whole repo, no -l/-c, no pipe)
  if echo "$COMMAND" | grep -qE '\bgrep\s+(-[a-zA-Z]*r|-[a-zA-Z]*-recursive)'; then
    # Already passed the "safe" checks above (piped, -l, -c)
    # Block only if targeting broad directories (., ./, entire repo)
    if echo "$COMMAND" | grep -qE '\s[.]\s*$|\s[.]/\s*$|\s\.$'; then
      block_with_message "Recursive grep on entire directory without output limit (add -l, -c, or | head)" "$COMMAND"
    fi
  fi

  # npm list --all (massive dependency tree)
  if echo "$COMMAND" | grep -qE 'npm\s+list\s+--all'; then
    block_with_message "npm list --all dumps entire dep tree (use --depth=0)" "$COMMAND"
  fi

  # pip list (usually fine but pip freeze can be long in large envs)
  # Not blocking — it's typically <100 lines

  # ag/rg on broad scope without pipe
  if echo "$COMMAND" | grep -qE '\b(ag|rg)\s+\S+\s+\.\s*$'; then
    block_with_message "Broad search without output limit (add | head or -l)" "$COMMAND"
  fi
fi

exit 0
