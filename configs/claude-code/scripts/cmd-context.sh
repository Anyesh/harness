#!/bin/bash
cmd="${1:-}"

top=$(git rev-parse --show-toplevel 2>/dev/null) || top=""
if [ -n "$top" ]; then
  base=$(basename "$top")
else
  base=$(basename "$PWD")
fi
slug=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//')

env_loader="$HOME/.claude/hooks/load-harness-env.sh"
if [ -f "$env_loader" ]; then
  . "$env_loader"
  load_wiki_vault
fi
vault="${WIKI_VAULT:-}"
case "$cmd" in
  decision|devlog|plan)
    if [ -z "$vault" ]; then
      echo "WIKI_VAULT is not set; /$cmd writes to the Obsidian wiki and cannot continue." >&2
      exit 1
    fi
    ;;
esac

echo "repo_slug: $slug"

if [ "$cmd" = "orchestrate" ]; then
  if [ -z "$vault" ]; then
    echo "plans_dir: UNSET"
    echo "plans:"
    echo "NONE"
  else
    echo "plans_dir: $vault/wiki/projects/$slug/plans"
    echo "plans:"
    ls "$vault/wiki/projects/$slug/plans" 2>/dev/null || echo "NONE"
  fi
  exit 0
fi

if [ "$cmd" = "commit" ]; then
  echo "git_status:"
  git status --short 2>/dev/null || echo "NOT A GIT REPO"
  echo "git_log:"
  git log --oneline -10 2>/dev/null || echo "NONE"
  echo "git_diff_staged_stat:"
  git diff --staged --stat 2>/dev/null || echo "NONE"
  exit 0
fi

echo "wiki_vault: ${vault:-UNSET}"
echo "today: $(date +%F)"

if [ -n "$vault" ]; then
  proj="$vault/wiki/projects/$slug"
  [ -f "$vault/wiki/index.md" ] && echo "wiki_index: exists" || echo "wiki_index: absent"
  [ -f "$proj/devlog.md" ] && echo "devlog: exists" || echo "devlog: absent"
  case "$cmd" in
    plan|scope)
      echo "plans:"
      ls "$proj/plans" 2>/dev/null || echo "NONE"
      ;;
  esac
  case "$cmd" in
    decision|scope)
      echo "decisions:"
      ls "$proj/decisions" 2>/dev/null || echo "NONE"
      ;;
  esac
fi

if [ "$cmd" = "scope" ]; then
  echo "scope_file:"
  if [ -n "$top" ] && [ -f "$top/.scope.md" ]; then
    cat "$top/.scope.md"
  elif [ -f .scope.md ]; then
    cat .scope.md
  else
    echo "NONE"
  fi
fi
exit 0
