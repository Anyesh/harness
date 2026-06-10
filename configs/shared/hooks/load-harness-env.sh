#!/bin/bash
# Sources WIKI_VAULT from the environment or ~/.harness.env when unset.

load_wiki_vault() {
  if [[ -n "${WIKI_VAULT:-}" ]]; then
    return 0
  fi
  local env_file="${HARNESS_ENV:-$HOME/.harness.env}"
  [[ -f "$env_file" ]] || return 0
  local line
  line=$(grep -E '^WIKI_VAULT=' "$env_file" 2>/dev/null | tail -1 || true)
  [[ -n "$line" ]] || return 0
  WIKI_VAULT="${line#WIKI_VAULT=}"
  WIKI_VAULT="${WIKI_VAULT%\"}"
  WIKI_VAULT="${WIKI_VAULT#\"}"
  export WIKI_VAULT
}
