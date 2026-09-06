#!/bin/bash

render_template() {
  local input="$1" output="$2"
  local env_file="${HARNESS_ENV:-$HOME/.harness.env}"
  local repo_root="${REPO_ROOT:-$(cd "$(dirname "$input")/.." && pwd)}"

  \cp -f "$input" "$output"

  # Resolve {{INCLUDE:path}} (literal), {{INCLUDE_BODY:path}} (strip YAML
  # frontmatter), and {{INCLUDE_BODY_GLOB:pattern}} (strip frontmatter from
  # every file matching pattern, sorted, blank-line separated) directives.
  # Paths/patterns are relative to configs/. INCLUDE_BODY exists so .mdc rule
  # files can be shared between Cursor (needs frontmatter) and Claude's
  # CLAUDE.md (must not contain frontmatter). INCLUDE_BODY_GLOB exists so
  # every shared rule file lands in every agent's instructions automatically:
  # adding a new file under configs/shared/rules/ requires no template edit.
  while grep -qE '\{\{INCLUDE(_BODY(_GLOB)?)?:' "$output" 2>/dev/null; do
    local tmp_include
    tmp_include=$(mktemp)
    local found_include=false

    while IFS= read -r line; do
      if [[ "$line" == *'{{INCLUDE_BODY_GLOB:'* ]]; then
        local glob_ref="${line#*\{\{INCLUDE_BODY_GLOB:}"
        glob_ref="${glob_ref%%\}\}*}"
        local full_glob="$repo_root/configs/$glob_ref"
        local prefix="${line%%\{\{INCLUDE_BODY_GLOB:*}"
        local suffix="${line#*\}\}}"

        [[ -n "$prefix" ]] && printf '%s\n' "$prefix"
        # WHY: compgen -G mangles filenames containing spaces, and plain
        # unquoted `for f in $full_glob` word-splits the pattern itself
        # before globbing if the pattern (not just a match) contains a
        # space. Setting IFS to newline-only for the expansion disables
        # field-splitting on the pattern while still letting pathname
        # expansion produce one array element per match.
        local old_ifs="$IFS"
        IFS=$'\n'
        local glob_matches=($full_glob)
        IFS="$old_ifs"
        local glob_file first_glob_file=true glob_match_count=0
        while IFS= read -r glob_file; do
          [[ -f "$glob_file" ]] || continue
          glob_match_count=$((glob_match_count + 1))
          [[ "$first_glob_file" == false ]] && printf '\n'
          first_glob_file=false
          awk 'BEGIN{in_fm=0; past_fm=0}
               NR==1 && /^---[[:space:]]*$/ {in_fm=1; next}
               in_fm && /^---[[:space:]]*$/ {in_fm=0; past_fm=1; next}
               in_fm {next}
               past_fm==0 && NR==1 {past_fm=1}
               {print}' "$glob_file"
        done < <(printf '%s\n' "${glob_matches[@]}" | sort)
        if [[ "$glob_match_count" -eq 0 ]]; then
          declare -f log_warn >/dev/null 2>&1 && log_warn "INCLUDE_BODY_GLOB matched no files: $full_glob"
        fi
        [[ -n "$suffix" ]] && printf '%s\n' "$suffix"
        found_include=true
      elif [[ "$line" == *'{{INCLUDE_BODY:'* ]]; then
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

# Merges a rendered JSON fragment's top-level $merge_key into dest without
# clobbering dest's other keys, then applies the same checksum-skip/dry-run/
# backup/manifest treatment every other deploy function gets. Consumes and
# removes rendered_tmp. Refuses (exit 1) instead of merging when dest exists
# but isn't strict JSON (a hand-edited file with comments), since a blind
# json.load/dump round-trip would silently drop the user's content.
deploy_merged_json() {
  local rendered_tmp="$1" dest="$2" manifest_source="$3" label="$4" merge_key="${5:-mcpServers}"

  local tmp_merged
  tmp_merged=$(mktemp)
  # WHY: always normalize through the same json.dump(indent=2) pass, even
  # when dest doesn't exist yet (existing={}). A "cp the raw fragment on
  # first deploy, pretty-print on every later merge" split produces
  # different bytes for identical content, so checksum-skip never fires
  # after the first run unless the fragment happens to already be
  # formatted exactly like python's output.
  local py_err
  py_err=$(mktemp)
  if ! python3 - "$rendered_tmp" "$dest" "$tmp_merged" "$merge_key" 2>"$py_err" <<'PYEOF'
import json, sys
try:
    harness = json.load(open(sys.argv[1]))
except json.JSONDecodeError as e:
    sys.stderr.write(f"fragment:{sys.argv[1]} is not strict JSON (parse error: {e})\n")
    sys.exit(1)
merge_key = sys.argv[4]
try:
    existing = json.load(open(sys.argv[2]))
except FileNotFoundError:
    existing = {}
except json.JSONDecodeError as e:
    sys.stderr.write(f"dest:{sys.argv[2]} is not strict JSON (parse error: {e})\n")
    sys.exit(1)
merged = existing.copy()
merged.setdefault(merge_key, {}).update(harness.get(merge_key, {}))
json.dump(merged, open(sys.argv[3], "w"), indent=2)
open(sys.argv[3], "a").write("\n")
PYEOF
  then
    rm -f "$rendered_tmp" "$tmp_merged"
    if grep -q '^fragment:' "$py_err"; then
      log_warn "$label: harness-generated fragment isn't strict JSON, this is a harness bug: $(cat "$py_err")"
    else
      log_warn "$label: existing $dest isn't strict JSON, left untouched"
    fi
    rm -f "$py_err"
    return 1
  fi
  rm -f "$py_err"
  rm -f "$rendered_tmp"

  if [[ "$FORCE" == "false" && -f "$dest" ]]; then
    local src_hash dest_hash
    src_hash=$(file_checksum "$tmp_merged")
    dest_hash=$(file_checksum "$dest")
    if [[ "$src_hash" == "$dest_hash" ]]; then
      rm -f "$tmp_merged"
      log_skip "$label" "unchanged"
      return 0
    fi
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    rm -f "$tmp_merged"
    log_info "[dry-run] would deploy $label"
    return 0
  fi

  [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"
  mkdir -p "$(dirname "$dest")"
  mv "$tmp_merged" "$dest"
  manifest_add "$dest" "$manifest_source" "true"
  log_success "$label deployed"
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
