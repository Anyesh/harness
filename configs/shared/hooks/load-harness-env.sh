#!/usr/bin/env bash
# Fills harness settings from the environment, else from ~/.harness.env.

# The last assignment in the file wins, and surrounding double quotes are stripped.
harness_env_file_value() {
  local name="$1" env_file="${HARNESS_ENV:-$HOME/.harness.env}" line value
  [[ -f "$env_file" ]] || return 0
  line=$(grep -E "^${name}=" "$env_file" 2>/dev/null | tail -1 || true)
  value="${line#"${name}"=}"
  value="${value%\"}"
  printf '%s' "${value#\"}"
}

# The environment wins so a one-off override needs no file edit.
load_harness_var() {
  local name="$1" value
  [[ -n "${!name:-}" ]] && return 0
  value=$(harness_env_file_value "$name")
  [[ -n "$value" ]] || return 0
  printf -v "$name" '%s' "$value"
  export "${name?}"
}

harness_work_vault() {
  local vault="${1%/}"
  case "$vault" in
    */Work/agent-wiki) printf '%s' "$vault" ;;
    *) printf '%s/Work/agent-wiki' "$vault" ;;
  esac
}

# Settings env, rendered from the machine's file at install, wins over a later
# edit of that file until the next install; mapping an already mapped vault is
# a no-op.
load_wiki_vault() {
  load_harness_var WIKI_VAULT
  load_harness_var HARNESS_WORK
  if [[ "${HARNESS_WORK:-}" == 1 && -n "${WIKI_VAULT:-}" ]]; then
    WIKI_VAULT=$(harness_work_vault "$WIKI_VAULT")
    export WIKI_VAULT
  fi
}
