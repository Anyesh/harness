#!/bin/bash

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
