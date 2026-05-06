#!/usr/bin/env bash
# =============================================================================
# milestone_dag_io_bash.sh — Pure-bash fallback for the m13 manifest shim.
#
# Sourced by milestone_dag_io.sh — do not run directly. Used when the Go
# binary (`tekhton`) is not on PATH (test sandboxes, fresh clones before
# `make build`). The Go path is authoritative; this branch only exists so
# bash unit tests remain runnable without first building the supervisor.
#
# Provides:
#   _dag_bash_load_arrays  — parse MANIFEST.cfg into the _DAG_* arrays
#   _dag_bash_save_arrays  — atomic write of the _DAG_* arrays back out
# =============================================================================

# _dag_bash_load_arrays MANIFEST_PATH
# Pure-bash port of the legacy load_manifest body. Returns 1 on missing or
# empty file (caller resets _DAG_LOADED).
_dag_bash_load_arrays() {
    local manifest="$1"
    [[ -f "$manifest" ]] || return 1

    local idx=0 line id title status deps file group
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        IFS='|' read -r id title status deps file group <<< "$line"
        id="${id#"${id%%[![:space:]]*}"}"; id="${id%"${id##*[![:space:]]}"}"
        [[ -z "$id" ]] && continue
        title="${title#"${title%%[![:space:]]*}"}"; title="${title%"${title##*[![:space:]]}"}"
        status="${status#"${status%%[![:space:]]*}"}"; status="${status%"${status##*[![:space:]]}"}"
        deps="${deps#"${deps%%[![:space:]]*}"}"; deps="${deps%"${deps##*[![:space:]]}"}"
        file="${file#"${file%%[![:space:]]*}"}"; file="${file%"${file##*[![:space:]]}"}"
        group="${group#"${group%%[![:space:]]*}"}"; group="${group%"${group##*[![:space:]]}"}"

        _DAG_IDS+=("$id")
        _DAG_TITLES+=("$title")
        _DAG_STATUSES+=("${status:-pending}")
        _DAG_DEPS+=("$deps")
        _DAG_FILES+=("$file")
        _DAG_GROUPS+=("${group:-}")
        _DAG_IDX["$id"]=$idx
        idx=$((idx + 1))
    done < "$manifest"

    [[ ${#_DAG_IDS[@]} -gt 0 ]]
}

# _dag_bash_save_arrays MANIFEST_PATH
# Atomic write of the _DAG_* arrays via tmpfile + mv. Re-emits the legacy
# two-line header; comments from the original file are NOT round-tripped on
# this path. Use `tekhton manifest set-status` for comment-preserving updates.
_dag_bash_save_arrays() {
    local manifest="$1"
    local tmpfile
    tmpfile="$(mktemp "${manifest}.XXXXXX")"

    {
        echo "# Tekhton Milestone Manifest v1"
        echo "# id|title|status|depends_on|file|parallel_group"
        local i
        for (( i = 0; i < ${#_DAG_IDS[@]}; i++ )); do
            echo "${_DAG_IDS[$i]}|${_DAG_TITLES[$i]}|${_DAG_STATUSES[$i]}|${_DAG_DEPS[$i]}|${_DAG_FILES[$i]}|${_DAG_GROUPS[$i]}"
        done
    } > "$tmpfile"

    mv -f "$tmpfile" "$manifest"
}
