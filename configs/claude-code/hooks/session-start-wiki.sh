#!/usr/bin/env bash
# SessionStart hook: inject wiki index as context

WIKI_VAULT="${WIKI_VAULT:-}"

if [[ -z "$WIKI_VAULT" ]]; then
    echo '{}'
    exit 0
fi

INDEX_FILE="${WIKI_VAULT}/wiki/index.md"
if [[ ! -f "$INDEX_FILE" ]]; then
    echo '{}'
    exit 0
fi

INDEX_CONTENT=$(head -c 4000 "$INDEX_FILE")

python3 -c "
import json, sys
content = sys.stdin.read()
print(json.dumps({'message': 'Wiki knowledge base available. Index:\\n\\n' + content}))
" <<< "$INDEX_CONTENT"
