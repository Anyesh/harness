#!/bin/bash
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

# A profile's settings env carries its own WIKI_VAULT and HARNESS_WORK, so they
# override the machine's file; mapping an already mapped vault is a no-op.
load_wiki_vault() {
  load_harness_var WIKI_VAULT
  load_harness_var HARNESS_WORK
  if [[ "${HARNESS_WORK:-}" == 1 && -n "${WIKI_VAULT:-}" ]]; then
    WIKI_VAULT=$(harness_work_vault "$WIKI_VAULT")
    export WIKI_VAULT
  fi
}

# A work session only ever resolves the work vault; a personal session reaches
# it only for slugs the machine lists as work, never because a folder exists.
harness_wiki_vault_for() {
  local slug="$1" listed
  [[ -n "${WIKI_VAULT:-}" ]] || return 0
  if [[ "${HARNESS_WORK:-}" == 1 ]]; then
    printf '%s' "$WIKI_VAULT"
    return 0
  fi
  load_harness_var WIKI_WORK_PROJECTS
  for listed in ${WIKI_WORK_PROJECTS:+${WIKI_WORK_PROJECTS//,/ }}; do
    if [[ "$listed" == "$slug" ]]; then
      harness_work_vault "$WIKI_VAULT"
      return 0
    fi
  done
  printf '%s' "$WIKI_VAULT"
}
