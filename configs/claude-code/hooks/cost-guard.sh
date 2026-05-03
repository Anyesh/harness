#!/bin/bash
set -uo pipefail

# PreToolUse hook: blocks large-output operations on the main thread.
# Forces delegation to cheaper subagents to avoid context inflation.
# Because each turn re-sends the full conversation as input, large tool
# outputs here compound cost on every subsequent turn.

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

case "$TOOL_NAME" in
  Read|Bash) ;;
  *) exit 0 ;;
esac

if [[ "$TOOL_NAME" == "Read" ]]; then
  FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  [[ -z "$FILE_PATH" || ! -f "$FILE_PATH" ]] && exit 0

  # Allow small files without blocking
  FILE_SIZE=$(stat -c%s "$FILE_PATH" 2>/dev/null || stat -f%z "$FILE_PATH" 2>/dev/null || echo 0)
  LINE_COUNT=$(wc -l < "$FILE_PATH" 2>/dev/null || echo 0)

  # Threshold: >100KB or >2000 lines
  if [[ $FILE_SIZE -gt 102400 || $LINE_COUNT -gt 2000 ]]; then
    # Allow if file is in the current working project (likely needed for editing)
    # Block if it's logs, transcripts, or output files
    case "$FILE_PATH" in
      *.log|*.jsonl|*transcript*|*/debug/*|*/logs/*|*/output/*|*.out)
        cat >&2 <<EOF
[hook:cost-guard] BLOCKED: Reading large file on main thread (${FILE_SIZE} bytes, ${LINE_COUNT} lines)
File: $FILE_PATH

COST RULE: Large file reads inflate main context. Every future turn re-sends this content.
Delegate to a subagent:
  Agent({ model: "sonnet", prompt: "Read $FILE_PATH and [summarize/extract/find X]" })

The subagent reads in its own context (cheap), returns only what matters (small).
EOF
        exit 2
        ;;
    esac
  fi
fi

if [[ "$TOOL_NAME" == "Bash" ]]; then
  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  [[ -z "$COMMAND" ]] && exit 0

  # Detect commands that typically produce large output
  LARGE_OUTPUT_PATTERNS=(
    'docker logs'
    'journalctl'
    'kubectl logs'
    'cat.*\.log'
    'tail -[0-9]*[0-9][0-9][0-9]'
    'find / '
    'find \. -type f$'
    'grep -r[^l].*\.'
    'ag .* \.'
    'rg .* \.'
    'npm list --all'
    'pip list'
    'ls -[lR].*/'
  )

  for pattern in "${LARGE_OUTPUT_PATTERNS[@]}"; do
    if echo "$COMMAND" | grep -qEi "$pattern"; then
      cat >&2 <<EOF
[hook:cost-guard] BLOCKED: Command likely produces large output on main thread
Command: $COMMAND
Matched: $pattern

COST RULE: Large command outputs inflate main context permanently.
Delegate to a subagent:
  Agent({ model: "sonnet", prompt: "Run: $COMMAND — summarize/extract relevant findings" })

Or pipe to head/tail/grep to limit output before it hits context.
EOF
      exit 2
    fi
  done
fi

exit 0
