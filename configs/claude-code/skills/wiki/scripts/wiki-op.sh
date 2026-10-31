#!/usr/bin/env bash
op="${1:-}"
skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

top=$(git rev-parse --show-toplevel 2>/dev/null) || top=""
hooks="$HOME/.claude/hooks"
slug=""
vault=""
if [ -f "$hooks/load-harness-env.sh" ] && [ -f "$hooks/harness-project.sh" ]; then
  . "$hooks/load-harness-env.sh"
  . "$hooks/harness-project.sh"
  load_wiki_vault
  slug=$(harness_wiki_slug "${top:-$PWD}")
  vault="${WIKI_VAULT:-}"
fi

# A repo's .wiki-vault may only narrow the vault in use, so a work session
# can't be pointed back at the personal vault by a file in the checkout.
if [ -f .wiki-vault ]; then
  local_vault=$(head -1 .wiki-vault)
  case "$local_vault" in
    "$vault"|"$vault"/*) vault="$local_vault" ;;
    *) [ -z "$vault" ] && vault="$local_vault" ;;
  esac
fi

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
