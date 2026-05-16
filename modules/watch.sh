#!/usr/bin/env bash

WATCH_DIRS=("configs" "lib" "modules")
WATCH_DEBOUNCE=1

map_change_to_modules() {
  local changed_path="$1"

  case "$changed_path" in
    configs/claude-code/*)  echo "claude" ;;
    configs/cursor/*)       echo "cursor" ;;
    configs/codex/*)        echo "codex" ;;
    configs/shared/*)       echo "${MODULE_ORDER[*]}" ;;
    modules/*.sh)
      local mod
      mod=$(basename "$changed_path" .sh)
      if [[ "$mod" != "lib" && "$mod" != "watch" ]]; then
        echo "$mod"
      else
        echo "${MODULE_ORDER[*]}"
      fi
      ;;
    lib/*.sh)               echo "${MODULE_ORDER[*]}" ;;
    *)                      echo "" ;;
  esac
}

debounce_and_run() {
  local -A pending_modules=()

  while IFS= read -r changed_file; do
    local rel="${changed_file#$REPO_ROOT/}"
    local mods
    mods=$(map_change_to_modules "$rel")
    [[ -z "$mods" ]] && continue

    for m in $mods; do
      pending_modules["$m"]=1
    done

    while read -t "$WATCH_DEBOUNCE" -r extra_file; do
      rel="${extra_file#$REPO_ROOT/}"
      mods=$(map_change_to_modules "$rel")
      [[ -z "$mods" ]] && continue
      for m in $mods; do
        pending_modules["$m"]=1
      done
    done

    if [[ ${#pending_modules[@]} -gt 0 ]]; then
      log_info "changes detected, re-running: ${!pending_modules[*]}"
      for mod in "${MODULE_ORDER[@]}"; do
        if [[ -n "${pending_modules[$mod]+_}" ]]; then
          load_module "$mod"
          run_module "$mod" || true
        fi
      done
      pending_modules=()
    fi
  done
}

watch_inotify() {
  local dirs=()
  for d in "${WATCH_DIRS[@]}"; do
    dirs+=("$REPO_ROOT/$d")
  done

  log_info "watching with inotifywait: ${dirs[*]}"
  inotifywait -m -r -e modify,create,delete,move \
    --format '%w%f' "${dirs[@]}" 2>/dev/null | debounce_and_run
}

watch_poll() {
  local interval=2
  local marker
  marker=$(mktemp)
  touch "$marker"

  log_info "watching with polling (${interval}s interval): ${WATCH_DIRS[*]}"

  while true; do
    sleep "$interval"

    local changed_files=()
    for d in "${WATCH_DIRS[@]}"; do
      while IFS= read -r f; do
        changed_files+=("$f")
      done < <(find "$REPO_ROOT/$d" -newer "$marker" -type f 2>/dev/null)
    done

    if [[ ${#changed_files[@]} -gt 0 ]]; then
      local -A pending_modules=()
      for changed_file in "${changed_files[@]}"; do
        local rel="${changed_file#$REPO_ROOT/}"
        local mods
        mods=$(map_change_to_modules "$rel")
        [[ -z "$mods" ]] && continue
        for m in $mods; do
          pending_modules["$m"]=1
        done
      done

      if [[ ${#pending_modules[@]} -gt 0 ]]; then
        log_info "changes detected, re-running: ${!pending_modules[*]}"
        for mod in "${MODULE_ORDER[@]}"; do
          if [[ -n "${pending_modules[$mod]+_}" ]]; then
            load_module "$mod"
            run_module "$mod" || true
          fi
        done
      fi

      touch "$marker"
    fi
  done
}

cmd_watch() {
  log_section "Watch Mode"
  detect_tools

  for mod in "${MODULE_ORDER[@]}"; do
    load_module "$mod"
  done

  if command -v inotifywait &>/dev/null; then
    watch_inotify
  else
    log_warn "inotifywait not found, falling back to polling"
    watch_poll
  fi
}
