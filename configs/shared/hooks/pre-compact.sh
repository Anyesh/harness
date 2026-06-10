#!/bin/bash
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=harness-project.sh
source "$HOOK_DIR/harness-project.sh"
INPUT=$(cat 2>/dev/null || true)
AGENT=$("$HOOK_DIR/detect-agent.sh" <<< "$INPUT")

REPO_ROOT="$(harness_repo_root "$INPUT")"

MSG=$(cat <<'EOF'
COMPACTION OCCURRING — Before context is compressed:

WIKI CAPTURE: If this session produced plans, decisions, spikes, or concepts that haven't been written to the wiki yet, write them NOW using /wiki (plan|decide|spike|concept|log). This is your last chance before context is lost.

After compaction, restore working context:
1. Check task list (TaskList) for in-progress work
2. Check MEMORY.md for persistent context
3. Re-read any files you were actively editing
4. Re-read .scope.md if doing feature work
5. Read wiki/projects/<current-project>/devlog.md for session continuity
EOF
)

if [ -f "$REPO_ROOT/.scope.md" ]; then
    MSG="${MSG}

ACTIVE SCOPE (from .scope.md):
$(cat "$REPO_ROOT/.scope.md")"
fi

if command -v sb >/dev/null 2>&1; then
    sb ingest >/dev/null 2>&1 || true
fi

if [ "$AGENT" = "cursor" ]; then
    jq -n --arg msg "$MSG" '{user_message: $msg}'
else
    printf '%s\n' "$MSG"
fi

exit 0
