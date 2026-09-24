#!/bin/bash

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

deploy_rendered_template() {
  local src="$1" dest="$2" manifest_source="$3" label="$4"
  local tmp
  tmp=$(mktemp)
  render_template "$src" "$tmp"
  if ! validate_template "$tmp"; then
    rm -f "$tmp"
    log_error "failed to deploy $label (unresolved template vars)"
    return 1
  fi
  deploy_file "$tmp" "$dest" "$manifest_source" "true" "$label"
  rm -f "$tmp"
}

# Merges a rendered JSON fragment's top-level $merge_key into dest without
# clobbering dest's other keys, then deploys the result like any other file.
# Consumes and removes rendered_tmp. Refuses (exit 1) instead of merging when
# dest exists but isn't strict JSON (a hand-edited file with comments), since a
# blind json.load/dump round-trip would silently drop the user's content.
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
  rm -f "$py_err" "$rendered_tmp"

  deploy_file "$tmp_merged" "$dest" "$manifest_source" "true" "$label"
  rm -f "$tmp_merged"
}
