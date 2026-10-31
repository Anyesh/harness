#!/usr/bin/env bash

file_checksum() {
  sha256sum "$1" | cut -d' ' -f1
}

manifest_init() {
  local manifest="${HARNESS_MANIFEST:-$HOME/.harness-manifest.json}"
  if [[ ! -f "$manifest" ]]; then
    local commit="unknown"
    if command -v git &>/dev/null && [[ -d "${REPO_ROOT:-.}/.git" ]]; then
      commit=$(git -C "${REPO_ROOT:-.}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    fi
    cat > "$manifest" <<EOF
{
  "version": "1.0.0",
  "repo": "anyesh/harness",
  "last_deploy": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "repo_commit": "$commit",
  "files": {}
}
EOF
  fi
}

manifest_add() {
  local dest="$1" source="$2" templated="${3:-false}"
  local manifest="${HARNESS_MANIFEST:-$HOME/.harness-manifest.json}"
  local checksum
  checksum=$(file_checksum "$dest")

  local tmp
  tmp=$(mktemp)
  jq --arg dest "$dest" \
     --arg source "$source" \
     --arg sha "$checksum" \
     --arg tmpl "$templated" \
     '.files[$dest] = {"sha256": $sha, "source": $source, "templated": ($tmpl == "true")}' \
     "$manifest" > "$tmp"
  mv "$tmp" "$manifest"
}

manifest_check_changed() {
  local dest="$1"
  local manifest="${HARNESS_MANIFEST:-$HOME/.harness-manifest.json}"

  if [[ ! -f "$manifest" ]] || [[ ! -f "$dest" ]]; then
    return 0
  fi

  local recorded
  recorded=$(jq -r --arg dest "$dest" '.files[$dest].sha256 // ""' "$manifest")
  if [[ -z "$recorded" ]]; then
    return 0
  fi

  local current
  current=$(file_checksum "$dest")
  [[ "$current" != "$recorded" ]]
}

manifest_is_managed() {
  local dest="$1"
  local manifest="${HARNESS_MANIFEST:-$HOME/.harness-manifest.json}"
  [[ -f "$manifest" ]] && jq -e --arg dest "$dest" '.files[$dest] != null' "$manifest" &>/dev/null
}

manifest_finalize() {
  local manifest="${HARNESS_MANIFEST:-$HOME/.harness-manifest.json}"
  local commit="unknown"
  if command -v git &>/dev/null && [[ -d "${REPO_ROOT:-.}/.git" ]]; then
    commit=$(git -C "${REPO_ROOT:-.}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  fi
  local tmp
  tmp=$(mktemp)
  jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --arg commit "$commit" \
     '.last_deploy = $ts | .repo_commit = $commit' \
     "$manifest" > "$tmp"
  mv "$tmp" "$manifest"
}

manifest_list_files() {
  local manifest="${HARNESS_MANIFEST:-$HOME/.harness-manifest.json}"
  [[ -f "$manifest" ]] && jq -r '.files | keys[]' "$manifest" 2>/dev/null || true
}

manifest_record_unchanged() {
  [[ "$DRY_RUN" == "true" ]] && return 0
  manifest_add "$@"
}

manifest_prune_missing() {
  local manifest="${HARNESS_MANIFEST:-$HOME/.harness-manifest.json}"
  local dest tmp
  for dest in $(manifest_list_files); do
    [[ -e "$dest" ]] && continue
    # WHY: a path that existed before the harness first touched it keeps its
    # entry, because uninstall uses it to restore the user's original file.
    [[ "$(preexist_state "$dest")" == "present" ]] && continue
    manifest_drop "$dest"
    log_info "manifest: dropped $dest (file no longer exists)"
  done
}

manifest_drop() {
  local manifest="${HARNESS_MANIFEST:-$HOME/.harness-manifest.json}"
  local tmp
  tmp=$(mktemp)
  jq --arg dest "$1" 'del(.files[$dest])' "$manifest" > "$tmp"
  mv "$tmp" "$manifest"
}

# Stops below $HOME and the config home so that a top-level folder such as ~/.cursor survives.
remove_empty_parents() {
  local dir
  dir=$(dirname "$1")
  local config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
  while [[ "$dir" == "$HOME"/* ]]; do
    local parent
    parent=$(dirname "$dir")
    [[ "$parent" == "$HOME" || "$parent" == "$config_home" ]] && break
    rmdir "$dir" 2>/dev/null || break
    dir="$parent"
  done
}

# A deployed file whose configs/ source is gone. Only an unchanged copy with a
# known pre-harness state is touched, because anything else may hold the user's work.
manifest_prune_orphans() {
  local manifest="${HARNESS_MANIFEST:-$HOME/.harness-manifest.json}"
  [[ -f "$manifest" ]] || return 0
  local dest source state orig
  while IFS=$'\t' read -r dest source; do
    [[ -n "$dest" && "$source" == configs/* && -f "$dest" ]] || continue
    [[ -e "$REPO_ROOT/$source" ]] && continue
    if manifest_check_changed "$dest"; then
      log_warn "orphan edited since deploy, left in place: $dest"
      continue
    fi
    state=$(preexist_state "$dest")
    if [[ "$state" == "absent" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        log_info "would remove orphan: $dest"
        continue
      fi
      rm -f "$dest"
      remove_empty_parents "$dest"
      manifest_drop "$dest"
      log_info "removed orphan: $dest (source $source is gone)"
    elif [[ "$state" == "present" ]] && orig=$(find_original "$dest"); then
      if [[ "$DRY_RUN" == "true" ]]; then
        log_info "would restore the original over orphan: $dest"
        continue
      fi
      cp -p "$orig" "$dest"
      manifest_drop "$dest"
      log_info "restored the original over orphan: $dest (source $source is gone)"
    else
      log_warn "orphan with no record of what it replaced, left in place: $dest"
    fi
  done < <(jq -r '.files | to_entries[] | [.key, .value.source] | @tsv' "$manifest")
}
