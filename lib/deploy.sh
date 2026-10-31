#!/usr/bin/env bash

json_equivalent() {
  local a b
  a=$(jq -S -c . "$1" 2>/dev/null) || return 1
  b=$(jq -S -c . "$2" 2>/dev/null) || return 1
  [[ "$a" == "$b" ]]
}

deployed_matches() {
  local candidate="$1" dest="$2"
  cmp -s "$candidate" "$dest" && return 0
  # WHY: tools rewrite their own JSON configs in their own key order (Claude
  # Code does this to settings.json whenever a setting changes in its UI), so
  # byte equality would redeploy identical config on every install.
  [[ "$dest" == *.json ]] && json_equivalent "$candidate" "$dest"
}

# Every file the harness writes into a tool's config dir goes through here, so
# the skip, dry-run, backup and manifest rules stay identical everywhere. The
# candidate is left in place; callers own its cleanup. Pass "executable" as the
# sixth argument for scripts.
deploy_file() {
  local candidate="$1" dest="$2" manifest_source="$3" templated="$4" label="$5" mode="${6:-}"

  if [[ "$FORCE" == "false" && -f "$dest" ]] && deployed_matches "$candidate" "$dest"; then
    log_skip "$label" "unchanged"
    manifest_record_unchanged "$dest" "$manifest_source" "$templated"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would deploy: $label"
    return 0
  fi

  local existed=false
  [[ -e "$dest" ]] && existed=true
  [[ "$NO_BACKUP" == "false" ]] && backup_if_exists "$dest"
  mkdir -p "$(dirname "$dest")"
  cp "$candidate" "$dest"
  if [[ "$mode" == "executable" ]]; then
    chmod +x "$dest" 2>/dev/null || true
  fi
  manifest_add "$dest" "$manifest_source" "$templated"
  if [[ "$existed" == "true" ]]; then
    log_update "updated: $label"
  else
    log_success "installed: $label"
  fi
}

render_candidate() {
  local src="$1" out="$2" dest="$3" label="$4"
  render_template "$src" "$out"
  if [[ "$dest" == *.json ]] && profile_no_memory && ! strip_memory_json "$out"; then
    log_error "failed to deploy $label (memory filter could not parse the JSON)"
    return 1
  fi
  if [[ "$dest" == *.json ]] && ! strip_work_json "$out"; then
    log_error "failed to deploy $label (work filter could not parse the JSON)"
    return 1
  fi
  if ! validate_template "$out"; then
    log_error "failed to deploy $label (unresolved template vars)"
    return 1
  fi
}

deploy_rendered_template() {
  local src="$1" dest="$2" manifest_source="$3" label="$4"
  local tmp
  tmp=$(mktemp)
  if ! render_candidate "$src" "$tmp" "$dest" "$label"; then
    rm -f "$tmp"
    return 1
  fi
  deploy_file "$tmp" "$dest" "$manifest_source" "true" "$label"
  rm -f "$tmp"
}

merge_base_path() {
  printf '%s/%s\n' "${HARNESS_MERGE_BASE_DIR:-$HOME/.harness-merge-base}" "${1//\//%}"
}

# For a file the harness deployed before merge bases existed: the manifest
# records the commit of the last install, and the template at that commit
# renders to what that install applied. Without this the first merge has no
# base, so a hook the template changed since would stay twice, old and new.
rebuild_merge_base() {
  local manifest_source="$1" dest="$2" out="$3"
  local manifest="${HARNESS_MANIFEST:-$HOME/.harness-manifest.json}" commit old_src
  manifest_is_managed "$dest" || return 1
  commit=$(jq -r '.repo_commit // ""' "$manifest" 2>/dev/null)
  [[ -n "$commit" && "$commit" != "unknown" ]] || return 1
  old_src=$(mktemp)
  if ! git -C "$REPO_ROOT" show "$commit:$manifest_source" > "$old_src" 2>/dev/null; then
    rm -f "$old_src"
    return 1
  fi
  render_candidate "$old_src" "$out" "$dest" "$manifest_source at $commit" 2>/dev/null
  local rc=$?
  rm -f "$old_src"
  return $rc
}

# Deploys a JSON template into a file the user also edits (Claude Code's own UI
# writes settings.json, and a work machine carries its own keys). Three-way
# merges the render into the local file against the render last applied, see
# lib/json_merge3.py for the rules. OVERRIDE_SETTINGS=true replaces the file.
deploy_reconciled_template() {
  local src="$1" dest="$2" manifest_source="$3" label="$4"
  local ours rc=0
  ours=$(mktemp)
  if ! render_candidate "$src" "$ours" "$dest" "$label"; then
    rm -f "$ours"
    return 1
  fi
  deploy_reconciled_candidate "$ours" "$dest" "$manifest_source" "$label" || rc=$?
  rm -f "$ours"
  return $rc
}

# The reconcile half of deploy_reconciled_template, for a candidate the caller
# already built (a claude-profile settings.json is a render plus an overlay).
# The candidate is left in place; callers own its cleanup.
deploy_reconciled_candidate() {
  local ours="$1" dest="$2" manifest_source="$3" label="$4"
  local base merged rebuilt conflicts rc=0
  base=$(merge_base_path "$dest")

  if [[ "${OVERRIDE_SETTINGS:-false}" == "true" || ! -f "$dest" ]]; then
    deploy_file "$ours" "$dest" "$manifest_source" "true" "$label"
    save_merge_base "$ours" "$base"
    return 0
  fi

  rebuilt=$(mktemp)
  local base_arg=()
  if [[ -f "$base" ]]; then
    base_arg=("$base")
  elif rebuild_merge_base "$manifest_source" "$dest" "$rebuilt"; then
    base_arg=("$rebuilt")
  fi
  merged=$(mktemp)
  conflicts=$(python3 "$REPO_ROOT/lib/json_merge3.py" "$ours" "$dest" "$merged" ${base_arg[@]+"${base_arg[@]}"}) || rc=$?
  rm -f "$rebuilt"
  if [[ $rc -ne 0 ]]; then
    rm -f "$merged"
    if [[ $rc -eq 3 ]]; then
      log_warn "$label: $dest is not strict JSON, left untouched (--override-settings replaces it)"
    else
      log_error "failed to deploy $label (merge exited $rc)"
    fi
    return 1
  fi

  if [[ -n "$conflicts" ]]; then
    log_warn "$label: kept your value where the harness changed it too; reconcile by hand or rerun with --override-settings"
    local path mine theirs
    while IFS=$'\t' read -r path mine theirs; do
      log_warn "  conflict at $path: yours $mine, harness $theirs"
    done <<<"$conflicts"
  fi
  deploy_file "$merged" "$dest" "$manifest_source" "true" "$label"
  save_merge_base "$ours" "$base"
  rm -f "$merged"
}

# The base is the harness render, never the merged file, so that the next
# merge sees which values the user chose over the harness.
save_merge_base() {
  [[ "$DRY_RUN" == "true" ]] && return 0
  mkdir -p "$(dirname "$2")"
  cp "$1" "$2"
}

# Merges a rendered JSON fragment's top-level $merge_key into dest without
# clobbering dest's other keys, then deploys the result like any other file.
# Consumes and removes rendered_tmp. Refuses (exit 1) instead of merging when
# dest exists but isn't strict JSON (a hand-edited file with comments), since a
# blind json.load/dump round-trip would silently drop the user's content.
deploy_merged_json() {
  local rendered_tmp="$1" dest="$2" manifest_source="$3" label="$4" merge_key="${5:-mcpServers}"
  # The merge only adds keys, so servers a work install withholds are dropped
  # from dest explicitly or an earlier personal install's entry would survive.
  local drop=""
  profile_work && drop=$(IFS=,; printf '%s' "${WORK_MCP_SERVERS[*]}")

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
  if ! python3 - "$rendered_tmp" "$dest" "$tmp_merged" "$merge_key" "$drop" 2>"$py_err" <<'PYEOF'
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
for key in filter(None, sys.argv[5].split(",")):
    merged[merge_key].pop(key, None)
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
  rm -f "$py_err" "$rendered_tmp"

  deploy_file "$tmp_merged" "$dest" "$manifest_source" "true" "$label"
  rm -f "$tmp_merged"
}
