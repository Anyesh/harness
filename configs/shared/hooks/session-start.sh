#!/bin/bash
# sessionStart hook: inject session-scoped environment variables.
# Used by Cursor (via sessionStart hook). Claude Code handles env via settings.json.
cat <<'EOF'
{
  "env": {
    "RTK_TELEMETRY_DISABLED": "1"
  }
}
EOF
exit 0
