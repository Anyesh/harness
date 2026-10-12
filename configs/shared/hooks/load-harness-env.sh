#!/bin/bash
# Fills harness settings from the environment, else from ~/.harness.env.

# The environment wins so a one-off override needs no file edit; the last
# assignment in the file wins, and surrounding double quotes are stripped.
load_harness_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] && return 0
  local env_file="${HARNESS_ENV:-$HOME/.harness.env}"
  [[ -f "$env_file" ]] || return 0
  local line value
  line=$(grep -E "^${name}=" "$env_file" 2>/dev/null | tail -1 || true)
  [[ -n "$line" ]] || return 0
  value="${line#"${name}"=}"
  value="${value%\"}"
  value="${value#\"}"
  printf -v "$name" '%s' "$value"
  export "${name?}"
}

load_wiki_vault() {
  load_harness_var WIKI_VAULT
}
