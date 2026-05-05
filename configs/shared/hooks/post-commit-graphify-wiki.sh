#!/bin/bash
# post-commit hook: graphify AST update + wiki sync marker
# Installs into any project's .git/hooks/post-commit
# Works with any agent harness — the git hook is universal.
# Wiki sync requires LLM reasoning, so we write a marker file
# that the next agent session picks up.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
GRAPHIFY_OUT="$REPO_ROOT/graphify-out"
WIKI_VAULT_FILE="$REPO_ROOT/.wiki-vault"
PENDING_FILE="$REPO_ROOT/.wiki-sync-pending"

if command -v graphify >/dev/null 2>&1; then
    CHANGED_CODE_FILES=$(git diff --name-only HEAD~1 HEAD 2>/dev/null | grep -E '\.(py|js|ts|tsx|jsx|go|rs|rb|java|kt|scala|swift|c|cpp|h|hpp|sh|lua|dart|php)$' || true)

    if [ -n "$CHANGED_CODE_FILES" ]; then
        graphify --update --ast-only "$REPO_ROOT" >/dev/null 2>&1 || true
    fi
fi

if [ -f "$WIKI_VAULT_FILE" ]; then
    VAULT_PATH=$(cat "$WIKI_VAULT_FILE")
    WIKI_INDEX="$VAULT_PATH/wiki/index.md"

    if [ -f "$WIKI_INDEX" ] && [ -f "$GRAPHIFY_OUT/graph.json" ]; then
        CHANGED_FILES=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || true)
        TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        COMMIT_SHA=$(git rev-parse HEAD)
        COMMIT_MSG=$(git log -1 --pretty=%s)

        cat > "$PENDING_FILE" <<EOF
---
timestamp: $TIMESTAMP
commit: $COMMIT_SHA
message: $COMMIT_MSG
vault: $VAULT_PATH
---
$CHANGED_FILES
EOF
    fi
fi

exit 0
