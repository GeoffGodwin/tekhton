#!/usr/bin/env bash
# =============================================================================
# milestone_dag_io.sh — Manifest I/O: path helpers, presence check, load/save
#
# Sourced by milestone_dag.sh — do not run directly.
# Expects: TEKHTON_HOME, PROJECT_DIR from common.sh
# Expects: MILESTONE_DIR, MILESTONE_MANIFEST from config_defaults.sh
# Expects: _DAG_* parallel arrays and _DAG_IDX declared by milestone_dag.sh
#
# Provides:
#   _dag_manifest_path     — absolute path to MANIFEST.cfg
#   _dag_milestone_dir     — absolute path to milestones directory
#   has_milestone_manifest — check if MANIFEST.cfg exists
#   load_manifest          — parse manifest into parallel arrays
#   save_manifest          — atomic write of parallel arrays to manifest
# =============================================================================
set -euo pipefail

# --- Path helpers -----------------------------------------------------------

# _dag_manifest_path
# Returns the absolute path to MANIFEST.cfg.
_dag_manifest_path() {
    local dir="${MILESTONE_DIR:-.claude/milestones}"
    # Resolve relative paths against PROJECT_DIR
    if [[ "$dir" != /* ]]; then
        dir="${PROJECT_DIR}/${dir}"
    fi
    echo "${dir}/${MILESTONE_MANIFEST:-MANIFEST.cfg}"
}

# _dag_milestone_dir
# Returns the absolute path to the milestones directory.
_dag_milestone_dir() {
    local dir="${MILESTONE_DIR:-.claude/milestones}"
    if [[ "$dir" != /* ]]; then
        dir="${PROJECT_DIR}/${dir}"
    fi
    echo "$dir"
}

# --- Manifest presence check ------------------------------------------------

# has_milestone_manifest
# Returns 0 if MANIFEST.cfg exists, 1 otherwise.
has_milestone_manifest() {
    local manifest
    manifest=$(_dag_manifest_path)
    [[ -f "$manifest" ]]
}

# --- Manifest I/O -----------------------------------------------------------

# load_manifest [MANIFEST_PATH]
# Parses MANIFEST.cfg into parallel arrays. Clears any prior state.
# Returns 0 on success, 1 on missing/empty manifest.
load_manifest() {
    local manifest="${1:-$(_dag_manifest_path)}"

    if [[ ! -f "$manifest" ]]; then
        return 1
    fi

    # Clear prior state
    _DAG_IDS=()
    _DAG_TITLES=()
    _DAG_STATUSES=()
    _DAG_DEPS=()
    _DAG_FILES=()
    _DAG_GROUPS=()
    _DAG_IDX=()
    _DAG_LOADED=false

    local idx=0
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Parse pipe-delimited fields
        local id title status deps file group
        IFS='|' read -r id title status deps file group <<< "$line"

        # Trim whitespace from each field
        id="${id#"${id%%[![:space:]]*}"}"
        id="${id%"${id##*[![:space:]]}"}"
        title="${title#"${title%%[![:space:]]*}"}"
        title="${title%"${title##*[![:space:]]}"}"
        status="${status#"${status%%[![:space:]]*}"}"
        status="${status%"${status##*[![:space:]]}"}"
        deps="${deps#"${deps%%[![:space:]]*}"}"
        deps="${deps%"${deps##*[![:space:]]}"}"
        file="${file#"${file%%[![:space:]]*}"}"
        file="${file%"${file##*[![:space:]]}"}"
        group="${group#"${group%%[![:space:]]*}"}"
        group="${group%"${group##*[![:space:]]}"}"

        # Validate ID is non-empty
        if [[ -z "$id" ]]; then
            continue
        fi

        _DAG_IDS+=("$id")
        _DAG_TITLES+=("$title")
        _DAG_STATUSES+=("${status:-pending}")
        _DAG_DEPS+=("$deps")
        _DAG_FILES+=("$file")
        _DAG_GROUPS+=("${group:-}")
        _DAG_IDX["$id"]=$idx
        idx=$((idx + 1))
    done < "$manifest"

    if [[ ${#_DAG_IDS[@]} -eq 0 ]]; then
        return 1
    fi

    _DAG_LOADED=true
    return 0
}

# save_manifest [MANIFEST_PATH]
# Atomically writes the current parallel arrays to MANIFEST.cfg.
# Uses tmpfile + mv for crash safety.
save_manifest() {
    local manifest="${1:-$(_dag_manifest_path)}"
    local manifest_dir
    manifest_dir="$(dirname "$manifest")"
    mkdir -p "$manifest_dir"

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
