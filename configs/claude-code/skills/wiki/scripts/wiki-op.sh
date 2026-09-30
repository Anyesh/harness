#!/bin/bash
op="${1:-}"
skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

env_loader="$HOME/.claude/hooks/load-harness-env.sh"
if [ -f "$env_loader" ]; then
  . "$env_loader"
  load_wiki_vault
fi

vault=""
if [ -f .wiki-vault ]; then
  vault=$(head -1 .wiki-vault)
elif [ -n "${WIKI_VAULT:-}" ]; then
  vault="$WIKI_VAULT"
fi

top=$(git rev-parse --show-toplevel 2>/dev/null) || top=""
base=$(basename "${top:-$PWD}")
slug=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//')

echo "vault: ${vault:-UNRESOLVED}"
echo "project_slug: $slug"
echo "today: $(date +%F)"
echo

case "$op" in
  init|log|plan|decide|spike|concept|ingest|query|lint|status)
    cat "$skill_dir/references/$op.md" 2>/dev/null || echo "reference for $op is missing"
    ;;
  *)
    echo "Operations: init, log, plan, decide, spike, concept, ingest, query, lint, status."
    echo "Read references/<operation>.md in this skill directory for the one you need."
    ;;
esac
exit 0
