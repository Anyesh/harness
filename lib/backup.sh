#!/bin/bash

backup_file() {
  local file="$1"
  local backup_dir="${HARNESS_BACKUP_DIR:-$HOME/.harness-backups}"

  # WHY: one timestamp per install run, not per file. Computing it per file
  # scatters a single run's backups across dirs when it crosses a second
  # boundary, and restore only reads the newest dir -> partial restore.
  if [[ -z "${HARNESS_RUN_TS:-}" ]]; then
    HARNESS_RUN_TS=$(date +%Y%m%d_%H%M%S)
  fi
  local dest_dir="$backup_dir/$HARNESS_RUN_TS"

  if [[ ! -f "$file" ]]; then
    return 0
  fi

  mkdir -p "$dest_dir"
  local relative="${file#$HOME/}"
  local backup_path="$dest_dir/$relative"
  mkdir -p "$(dirname "$backup_path")"
  cp -p "$file" "$backup_path"
  log_info "backed up: $file"
}

preexist_state() {
  local file="$1"
  local index="${HARNESS_BACKUP_DIR:-$HOME/.harness-backups}/.preexist"
  [[ -f "$index" ]] || return 0
  awk -F'\t' -v f="$file" '$2==f{print $1; exit}' "$index"
}

record_preexistence() {
  local file="$1"
  local backup_dir="${HARNESS_BACKUP_DIR:-$HOME/.harness-backups}"

  # WHY: only the first observation of a path reflects true pre-harness state.
  # On later runs the path holds harness output, so a fresh check would
  # mislabel a harness-created file as pre-existing. Record once, never update.
  [[ -n "$(preexist_state "$file")" ]] && return 0

  mkdir -p "$backup_dir"
  local state="absent"
  [[ -e "$file" ]] && state="present"
  printf '%s\t%s\n' "$state" "$file" >> "$backup_dir/.preexist"
}

backup_if_exists() {
  local file="$1"
  record_preexistence "$file"
  if [[ -f "$file" ]]; then
    backup_file "$file"
  fi
}

find_original() {
  local file="$1"
  local backup_dir="${HARNESS_BACKUP_DIR:-$HOME/.harness-backups}"
  local relative="${file#$HOME/}"
  local d
  # WHY: oldest dir holding this path = the copy taken before harness first
  # touched it. Newer dirs hold harness output from prior runs.
  while IFS= read -r d; do
    if [[ -f "$backup_dir/$d/$relative" ]]; then
      echo "$backup_dir/$d/$relative"
      return 0
    fi
  done < <(ls -1tr "$backup_dir" 2>/dev/null)
  return 1
}

restore_originals() {
  manifest_init
  local restored=0 removed=0 kept=0

  for dest in $(manifest_list_files); do
    local state
    state=$(preexist_state "$dest")

    if [[ "$state" == "absent" ]]; then
      rm -f "$dest"
      log_info "removed (harness-created): $dest"
      removed=$((removed + 1))
    elif [[ "$state" == "present" ]]; then
      local orig
      if orig=$(find_original "$dest"); then
        mkdir -p "$(dirname "$dest")"
        cp -p "$orig" "$dest"
        log_info "restored original: $dest"
        restored=$((restored + 1))
      else
        log_warn "no backup found for $dest, leaving in place"
        kept=$((kept + 1))
      fi
    else
      log_warn "no pre-existence record for $dest, leaving in place"
      kept=$((kept + 1))
    fi
  done

  log_info "uninstall: $restored restored, $removed removed, $kept kept"
}
