#!/usr/bin/env bash

MODULES_LOADED=()
MODULES_OK=()
MODULES_FAILED=()

load_module() {
    local name="$1"
    local path="$REPO_ROOT/modules/${name}.sh"
    [[ -f "$path" ]] || { log_error "Module not found: $path"; return 1; }
    source "$path"
    local prefix="${name//-/_}"
    for fn in "${prefix}_check" "${prefix}_install" "${prefix}_test"; do
        declare -f "$fn" >/dev/null 2>&1 || { log_error "Module '$name' missing: $fn"; return 1; }
    done
    MODULES_LOADED+=("$name")
}

run_module() {
    local name="$1"
    local prefix="${name//-/_}"
    log_section "Module: $name"
    if ! "${prefix}_check"; then
        log_warn "Module '$name' check failed, skipping"
        MODULES_FAILED+=("$name")
        return 1
    fi
    if "${prefix}_install"; then
        MODULES_OK+=("$name")
    else
        MODULES_FAILED+=("$name")
        return 1
    fi
}
