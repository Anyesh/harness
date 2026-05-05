#!/bin/bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"

cat <<'EOF'
COMPACTION OCCURRING — After compaction, restore your working context:
1. Check task list (TaskList) for in-progress work
2. Check MEMORY.md for persistent context
3. Re-read any files you were actively editing before continuing
4. If doing feature work: re-read .scope.md for the Three Questions (Context, Definition of Done, Feedback Loop)
5. If .wiki-sync-pending exists: wiki needs syncing from recent commits
EOF

if [ -f "$REPO_ROOT/.scope.md" ]; then
    echo ""
    echo "ACTIVE SCOPE (from .scope.md):"
    cat "$REPO_ROOT/.scope.md"
fi

exit 0
