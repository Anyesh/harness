#!/bin/bash
# Install the unified graphify+wiki post-commit hook into the current repo.
# Safe to run multiple times — appends only if not already present.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
    echo "Error: not inside a git repository."
    exit 1
fi

HOOK_DIR="$REPO_ROOT/.git/hooks"
HOOK_FILE="$HOOK_DIR/post-commit"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_HOOK="$SCRIPT_DIR/post-commit-graphify-wiki.sh"

MARKER="# graphify-wiki-sync"

if [ -f "$HOOK_FILE" ] && grep -q "$MARKER" "$HOOK_FILE"; then
    echo "Hook already installed in $HOOK_FILE"
    exit 0
fi

if [ ! -f "$HOOK_FILE" ]; then
    echo "#!/bin/bash" > "$HOOK_FILE"
    chmod +x "$HOOK_FILE"
fi

{
    echo ""
    echo "$MARKER"
    echo "bash \"$SOURCE_HOOK\""
} >> "$HOOK_FILE"

echo "Installed graphify+wiki post-commit hook in $HOOK_FILE"
echo "Post-commit will: (1) run graphify AST update, (2) write .wiki-sync-pending marker"
echo "Next agent session picks up the marker and runs /wiki sync automatically."
