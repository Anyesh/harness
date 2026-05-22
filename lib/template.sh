#!/bin/bash

render_template() {
  local input="$1" output="$2"
  local env_file="${HARNESS_ENV:-$HOME/.harness.env}"
  local repo_root="${REPO_ROOT:-$(cd "$(dirname "$input")/.." && pwd)}"

  \cp -f "$input" "$output"

  # Resolve {{INCLUDE:path}} (literal) and {{INCLUDE_BODY:path}} (strip YAML
  # frontmatter) directives. Paths are relative to configs/. INCLUDE_BODY
  # exists so .mdc rule files can be shared between Cursor (needs frontmatter)
  # and Claude's CLAUDE.md (must not contain frontmatter).
  while grep -qE '\{\{INCLUDE(_BODY)?:' "$output" 2>/dev/null; do
    local tmp_include
    tmp_include=$(mktemp)
    local found_include=false

    while IFS= read -r line; do
      if [[ "$line" == *'{{INCLUDE_BODY:'* ]]; then
        local include_ref="${line#*\{\{INCLUDE_BODY:}"
        include_ref="${include_ref%%\}\}*}"
        local full_path="$repo_root/configs/$include_ref"
        local prefix="${line%%\{\{INCLUDE_BODY:*}"
        local suffix="${line#*\}\}}"

        [[ -n "$prefix" ]] && printf '%s\n' "$prefix"
        if [[ -f "$full_path" ]]; then
          awk 'BEGIN{in_fm=0; past_fm=0}
               NR==1 && /^---[[:space:]]*$/ {in_fm=1; next}
               in_fm && /^---[[:space:]]*$/ {in_fm=0; past_fm=1; next}
               in_fm {next}
               past_fm==0 && NR==1 {past_fm=1}
               {print}' "$full_path"
        fi
        [[ -n "$suffix" ]] && printf '%s\n' "$suffix"
        found_include=true
      elif [[ "$line" == *'{{INCLUDE:'* ]]; then
        local include_ref="${line#*\{\{INCLUDE:}"
        include_ref="${include_ref%%\}\}*}"
        local full_path="$repo_root/configs/$include_ref"
        local prefix="${line%%\{\{INCLUDE:*}"
        local suffix="${line#*\}\}}"

        [[ -n "$prefix" ]] && printf '%s\n' "$prefix"
        if [[ -f "$full_path" ]]; then
          cat "$full_path"
        fi
        [[ -n "$suffix" ]] && printf '%s\n' "$suffix"
        found_include=true
      else
        printf '%s\n' "$line"
      fi
    done < "$output" > "$tmp_include"

    \mv -f "$tmp_include" "$output"
    [[ "$found_include" == false ]] && break
  done

  local home_escaped="${HOME//\\/\\\\}"
  home_escaped="${home_escaped//&/\\&}"
  sed -i "s|{{HOME_DIR}}|${home_escaped}|g" "$output"

  if [[ -f "$env_file" ]]; then
    while IFS='=' read -r key value; do
      [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
      key=$(echo "$key" | xargs)
      value="${value#\"}"
      value="${value%\"}"
      local escaped_value="${value//\\/\\\\}"
      escaped_value="${escaped_value//&/\\&}"
      sed -i "s|{{${key}}}|${escaped_value}|g" "$output"
    done < "$env_file"
  fi
}

validate_template() {
  local file="$1"
  local unresolved
  # INCLUDE directives use mixed case so only flag ALL_CAPS unresolved vars
  unresolved=$(grep -oP '\{\{[A-Z_][A-Z0-9_]*\}\}' "$file" 2>/dev/null | sort -u || true)

  if [[ -n "$unresolved" ]]; then
    log_error "unresolved template variables in $file:"
    echo "$unresolved" | sed 's/^/  /' >&2
    return 1
  fi
  return 0
}

deploy_template() {
  local src="$1" dest="$2"
  local tmp
  tmp=$(mktemp)

  render_template "$src" "$tmp"

  if ! validate_template "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  mkdir -p "$(dirname "$dest")"
  mv "$tmp" "$dest"
  return 0
}

validate_rendered() {
  local file="$1"
  local unresolved
  unresolved=$(grep -oP '\{\{[^}]+\}\}' "$file" 2>/dev/null | sort -u || true)

  if [[ -n "$unresolved" ]]; then
    log_error "unresolved variables in rendered output ($file):"
    echo "$unresolved" | sed 's/^/  /' >&2
    return 1
  fi
  return 0
}

validate_all_templates() {
  local templates_dir="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/configs"
  local failed=0
  local checked=0

  while IFS= read -r tmpl; do
    [[ -z "$tmpl" ]] && continue
    local tmp
    tmp=$(mktemp)
    render_template "$tmpl" "$tmp"

    checked=$((checked + 1))
    if ! validate_rendered "$tmp"; then
      log_error "template failed validation: $tmpl"
      failed=$((failed + 1))
    fi

    rm -f "$tmp"
  done < <(find "$templates_dir" -name '*.tmpl' -type f 2>/dev/null)

  log_info "validated $checked template(s), $failed failure(s)"

  [[ $failed -eq 0 ]]
}
