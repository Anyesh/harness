#!/bin/bash

render_template() {
  local input="$1" output="$2"
  local env_file="${HARNESS_ENV:-$HOME/.harness.env}"

  cp "$input" "$output"

  # HOME_DIR always resolves from $HOME so it never needs manual config
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
