#!/usr/bin/env bash
# =============================================================================
# milestone_dag_validate.sh — Manifest validation: referential integrity + cycles
#
# Sourced by milestone_dag.sh — do not run directly.
# Expects: _DAG_IDS[], _DAG_TITLES[], _DAG_STATUSES[], _DAG_DEPS[], _DAG_FILES[],
#          _DAG_GROUPS[], _DAG_IDX[], _DAG_LOADED from milestone_dag.sh
# Expects: _dag_milestone_dir() from milestone_dag.sh
# Expects: warn() from common.sh
#
# Provides:
#   validate_manifest — cycle detection + referential integrity + file checks
# =============================================================================
set -euo pipefail

# shellcheck disable=SC2153
# (_DAG_IDS and related arrays are provided by milestone_dag.sh)

# validate_manifest
# Checks the loaded manifest for:
#   1. Missing dependency references (dep ID not in manifest)
#   2. Missing milestone files (file field points to nonexistent file)
#   3. Circular dependencies (DFS cycle detection)
# Prints errors to stderr and returns 1 if any validation fails.
validate_manifest() {
    if [[ "$_DAG_LOADED" != true ]]; then
        warn "validate_manifest: no manifest loaded"
        return 1
    fi

    local errors=0
    local milestone_dir
    milestone_dir=$(_dag_milestone_dir)

    # 1. Check dependency references
    local i
    for (( i = 0; i < ${#_DAG_IDS[@]}; i++ )); do
        local deps="${_DAG_DEPS[$i]}"
        [[ -z "$deps" ]] && continue

        local dep
        while IFS=',' read -r dep; do
            dep="${dep#"${dep%%[![:space:]]*}"}"
            dep="${dep%"${dep##*[![:space:]]}"}"
            [[ -z "$dep" ]] && continue

            if [[ -z "${_DAG_IDX[$dep]+set}" ]]; then
                echo "ERROR: ${_DAG_IDS[$i]} depends on '${dep}' which is not in the manifest" >&2
                errors=$((errors + 1))
            fi
        done <<< "${deps//,/$'\n'}"
    done

    # 2. Check milestone files exist
    for (( i = 0; i < ${#_DAG_IDS[@]}; i++ )); do
        local file="${_DAG_FILES[$i]}"
        if [[ -n "$file" ]] && [[ ! -f "${milestone_dir}/${file}" ]]; then
            echo "ERROR: ${_DAG_IDS[$i]} references file '${file}' which does not exist in ${milestone_dir}" >&2
            errors=$((errors + 1))
        fi
    done

    # 3. Cycle detection via DFS
    declare -A _visited=()
    declare -A _in_stack=()

    _dfs_cycle_check() {
        local node="$1"
        _visited["$node"]=1
        _in_stack["$node"]=1

        local deps="${_DAG_DEPS[${_DAG_IDX[$node]}]}"
        if [[ -n "$deps" ]]; then
            local dep
            while IFS=',' read -r dep; do
                dep="${dep#"${dep%%[![:space:]]*}"}"
                dep="${dep%"${dep##*[![:space:]]}"}"
                [[ -z "$dep" ]] && continue
                # Skip unknown deps (already reported above)
                [[ -z "${_DAG_IDX[$dep]+set}" ]] && continue

                if [[ -n "${_in_stack[$dep]+set}" ]]; then
                    echo "ERROR: Circular dependency detected: ${node} → ${dep}" >&2
                    return 1
                fi
                if [[ -z "${_visited[$dep]+set}" ]]; then
                    _dfs_cycle_check "$dep" || return 1
                fi
            done <<< "${deps//,/$'\n'}"
        fi

        unset "_in_stack[$node]"
        return 0
    }

    for (( i = 0; i < ${#_DAG_IDS[@]}; i++ )); do
        if [[ -z "${_visited[${_DAG_IDS[$i]}]+set}" ]]; then
            if ! _dfs_cycle_check "${_DAG_IDS[$i]}"; then
                errors=$((errors + 1))
            fi
        fi
    done

    unset _visited _in_stack

    [[ "$errors" -eq 0 ]]
}
