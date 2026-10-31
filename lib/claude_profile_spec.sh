#!/usr/bin/env bash

# A claude-profile spec (~/.config/harness/profiles/<name>/) lists only how a
# profile differs from ~/.claude. This file parses it and answers selection
# questions; lib/claude_profiles.sh applies it to ~/.claude-<name>.

SPEC_LIST_KEYS=(skills_only skills_exclude rules_only rules_exclude commands_only commands_exclude)
SPEC_DIR=""
SPEC_MEMORY=on
# -g because load_module sources modules (and so this file) inside a function,
# where a plain declare would make the array local to that call.
declare -gA SPEC_LISTS=()

spec_dir() {
  printf '%s/harness/profiles/%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}" "$1"
}

spec_fail() {
  log_error "profile spec $1"
  return 2
}

# Stores a comma list as ",a,b," so membership is one pattern match. Rules and
# commands may be named with or without their file extension.
spec_store_list() {
  local key="$1" raw="$2" where="$3" item stored=","
  local -a items
  IFS=',' read -ra items <<<"$raw"
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" ]] || continue
    case "$key" in
      rules_*) item="${item%.mdc}" ;;
      commands_*) item="${item%.md}" ;;
    esac
    [[ "$item" =~ ^[A-Za-z0-9._-]+$ ]] || {
      spec_fail "$where: '$item' is not a valid name"
      return 2
    }
    stored+="$item,"
  done
  SPEC_LISTS[$key]="$stored"
}

# Returns 0 with the spec loaded, 1 when the profile has no spec, 2 when the
# spec is invalid. Nothing is written in any case, so a bad spec changes nothing.
spec_load() {
  local name="$1" conf line key value lineno=0 kind
  SPEC_DIR=""
  SPEC_MEMORY=on
  SPEC_LISTS=()
  local dir
  dir=$(spec_dir "$name")
  [[ -d "$dir" ]] || return 1

  conf="$dir/profile.conf"
  if [[ -f "$conf" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      lineno=$((lineno + 1))
      line="${line%%#*}"
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      [[ "$line" =~ ^[[:space:]]*([a-z_]+)[[:space:]]*=[[:space:]]*(.*[^[:space:]])?[[:space:]]*$ ]] || {
        spec_fail "$conf:$lineno: expected key=value"
        return 2
      }
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      case "$key" in
        memory)
          [[ "$value" == on || "$value" == off ]] || {
            spec_fail "$conf:$lineno: memory must be on or off"
            return 2
          }
          SPEC_MEMORY="$value"
          ;;
        work)
          spec_fail "$conf:$lineno: work= was removed; ./install.sh --work or --personal sets the mode for every profile"
          return 2
          ;;
        skills_only | skills_exclude | rules_only | rules_exclude | commands_only | commands_exclude)
          [[ -z "${SPEC_LISTS[$key]+set}" ]] || {
            spec_fail "$conf:$lineno: $key is set twice"
            return 2
          }
          spec_store_list "$key" "$value" "$conf:$lineno" || return 2
          ;;
        *)
          spec_fail "$conf:$lineno: unknown key '$key' (known: memory ${SPEC_LIST_KEYS[*]})"
          return 2
          ;;
      esac
    done <"$conf"
  fi

  for kind in skills rules commands; do
    if [[ -n "${SPEC_LISTS[${kind}_only]+set}" && -n "${SPEC_LISTS[${kind}_exclude]+set}" ]]; then
      spec_fail "$conf: ${kind}_only and ${kind}_exclude cannot both be set"
      return 2
    fi
  done
  if [[ -f "$dir/settings.json" ]] && ! jq -e 'type == "object"' "$dir/settings.json" >/dev/null 2>&1; then
    spec_fail "$dir/settings.json: must be a strict JSON object"
    return 2
  fi
  SPEC_DIR="$dir"
}

spec_selects() {
  local kind="$1" name="$2"
  if [[ -n "${SPEC_LISTS[${kind}_only]+set}" ]]; then
    [[ "${SPEC_LISTS[${kind}_only]}" == *",$name,"* ]]
    return
  fi
  if [[ -n "${SPEC_LISTS[${kind}_exclude]+set}" ]]; then
    [[ "${SPEC_LISTS[${kind}_exclude]}" != *",$name,"* ]]
    return
  fi
  return 0
}

spec_skips_rule() {
  [[ -n "$SPEC_DIR" ]] || return 1
  ! spec_selects rules "${1%.mdc}"
}

spec_touches() {
  local kind="$1"
  [[ -n "${SPEC_LISTS[${kind}_only]+set}${SPEC_LISTS[${kind}_exclude]+set}" || -d "$SPEC_DIR/$kind" ]]
}

# The ~/.claude entries this profile builds itself; every other entry stays a
# link to ~/.claude.
spec_owned_entries() {
  [[ -n "$SPEC_DIR" ]] || return 0
  if [[ -f "$SPEC_DIR/settings.json" || "$SPEC_MEMORY" == off ]]; then echo settings.json; fi
  if spec_touches rules || [[ "$SPEC_MEMORY" == off ]]; then echo CLAUDE.md; fi
  if spec_touches skills || [[ "$SPEC_MEMORY" == off ]]; then echo skills; fi
  if spec_touches commands || [[ "$SPEC_MEMORY" == off ]]; then echo commands; fi
  return 0
}
