#!/usr/bin/env bash
# Prints the repo's .scope.md for re-injection after a context compaction, or
# nothing when there is none. Shared by every harness's compaction hook.
set -euo pipefail

ROOT="${1:-$PWD}"
SCOPE="$ROOT/.scope.md"

# Codex caps injected context near 2,500 tokens and Claude Code at 10,000
# chars, so the note must stay under both with room for the header.
BUDGET="${COMPACT_NOTE_BUDGET:-6000}"

[[ -s "$SCOPE" ]] || exit 0
grep -q '[^[:space:]]' "$SCOPE" || exit 0

# iconv -c drops a multibyte character that head -c cut in half.
BODY=$(head -c "$BUDGET" "$SCOPE" | iconv -f UTF-8 -t UTF-8 -c)
printf 'ACTIVE SCOPE (from %s, restored after compaction):\n%s' "$SCOPE" "$BODY"
if (( $(wc -c < "$SCOPE") > BUDGET )); then
  printf '\n... truncated, read %s for the rest' "$SCOPE"
fi
printf '\n'
