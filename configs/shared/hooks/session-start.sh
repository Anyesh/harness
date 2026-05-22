#!/bin/bash
# sessionStart hook: inject session-scoped environment for Claude Code.
# Cursor's sessionStart does not accept the {env: {...}} schema, so on
# Cursor this script is a no-op (Cursor env comes from the user shell).

INPUT=$(cat 2>/dev/null || true)
CONVERSATION_ID=$(printf '%s' "$INPUT" | jq -r '.conversation_id // empty' 2>/dev/null || true)

if [ -n "$CONVERSATION_ID" ]; then
    echo '{}'
    exit 0
fi

cat <<'EOF'
{
  "env": {
    "RTK_TELEMETRY_DISABLED": "1"
  }
}
EOF
exit 0
