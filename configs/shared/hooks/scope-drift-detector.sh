#!/bin/bash
# UserPromptSubmit hook: soft reminder when .scope.md is missing/stale
# during long conversations that look like feature work.
# To avoid friction on quick fixes, only fires after 10+ conversation turns.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
SCOPE_FILE="$REPO_ROOT/.scope.md"
TURN_MARKER="$REPO_ROOT/.scope-turn-count"

if [ ! -f "$TURN_MARKER" ]; then
    echo "1" > "$TURN_MARKER"
    exit 0
fi

TURNS=$(cat "$TURN_MARKER")
TURNS=$((TURNS + 1))
echo "$TURNS" > "$TURN_MARKER"

if [ "$TURNS" -lt 10 ]; then
    exit 0
fi

if [ -f "$SCOPE_FILE" ]; then
    SCOPE_AGE_SECONDS=$(( $(date +%s) - $(stat -c %Y "$SCOPE_FILE" 2>/dev/null || stat -f %m "$SCOPE_FILE" 2>/dev/null || echo 0) ))
    # Stale = older than 2 hours
    if [ "$SCOPE_AGE_SECONDS" -lt 7200 ]; then
        exit 0
    fi
fi

cat <<'EOF'
{
  "message": "SCOPE CHECK (turn $TURNS): No current .scope.md found. If you are doing feature work or multi-file changes, answer the Three Questions before continuing: (1) Context — where are specs/plans/wiki? (2) Definition of done — what declares this complete? (3) Feedback loop — how are you validating? Write answers to .scope.md. If this is a quick fix or config change, ignore this reminder."
}
EOF

exit 0
