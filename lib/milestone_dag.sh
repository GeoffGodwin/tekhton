#!/usr/bin/env bash
# =============================================================================
# milestone_dag.sh — Milestone DAG infrastructure: DAG queries + orchestration
#
# Sourced by tekhton.sh — do not run directly.
# Expects: TEKHTON_HOME, PROJECT_DIR, log(), warn(), error() from common.sh
# Expects: MILESTONE_DIR, MILESTONE_MANIFEST from config_defaults.sh
#
# Manifest format (.claude/milestones/MANIFEST.cfg):
#   # Tekhton Milestone Manifest v1
#   # id|title|status|depends_on|file|parallel_group
#   m01|DAG Infrastructure|pending||m01-dag-infra.md|foundation
#
# Data structures: parallel bash arrays indexed by integer position,
# with associative index _DAG_IDX[id]=position for O(1) lookup.
#
# Sourced from milestone_dag_io.sh:
#   _dag_manifest_path, _dag_milestone_dir, has_milestone_manifest,
#   load_manifest, save_manifest
#
# Sourced from milestone_dag_validate.sh:
#   validate_manifest
#
# Provides:
#   dag_get_frontier          — milestones whose deps are all done
#   dag_deps_satisfied        — check if all deps of an ID are done
#   dag_find_next             — next actionable milestone (respects DAG order)
#   dag_get_active            — currently in-progress milestone(s)
#   dag_get_status            — status of a single milestone
#   dag_set_status            — update status of a single milestone
#   dag_get_file              — file path for a milestone ID
#   dag_get_title             — title for a milestone ID
#   dag_id_to_number          — m01 → 1, m02 → 2
#   dag_number_to_id          — 1 → m01, 2 → m02
#   dag_get_count             — number of milestones in manifest
# =============================================================================
set -euo pipefail

# --- Data structures (module-scoped) ----------------------------------------
# Parallel arrays — same index across all arrays = same milestone
_DAG_IDS=()
_DAG_TITLES=()
_DAG_STATUSES=()
_DAG_DEPS=()
_DAG_FILES=()
_DAG_GROUPS=()

# Associative index: _DAG_IDX[id] = array index
declare -A _DAG_IDX=()

# Loaded flag — prevents double-loading
_DAG_LOADED=false

# --- I/O (sourced from milestone_dag_io.sh) ---------------------------------
# shellcheck source=milestone_dag_io.sh
source "${TEKHTON_HOME}/lib/milestone_dag_io.sh"

# --- DAG queries ------------------------------------------------------------

# dag_get_count
# Returns the number of milestones in the loaded manifest.
dag_get_count() {
    echo "${#_DAG_IDS[@]}"
}

# dag_get_status ID
# Returns the status of a milestone by ID.
dag_get_status() {
    local id="$1"
    if [[ -z "${_DAG_IDX[$id]+set}" ]]; then
        return 1
    fi
    echo "${_DAG_STATUSES[${_DAG_IDX[$id]}]}"
}

# dag_set_status ID STATUS
# Updates the status of a milestone in the loaded arrays.
# Does NOT write to disk — call save_manifest() after.
dag_set_status() {
    local id="$1"
    local status="$2"
    if [[ -z "${_DAG_IDX[$id]+set}" ]]; then
        warn "dag_set_status: unknown milestone ID '${id}'"
        return 1
    fi
    _DAG_STATUSES[${_DAG_IDX[$id]}]="$status"
}

# dag_get_file ID
# Returns the milestone file path (relative to milestone dir) for an ID.
dag_get_file() {
    local id="$1"
    if [[ -z "${_DAG_IDX[$id]+set}" ]]; then
        return 1
    fi
    echo "${_DAG_FILES[${_DAG_IDX[$id]}]}"
}

# dag_get_title ID
# Returns the title of a milestone by ID.
dag_get_title() {
    local id="$1"
    if [[ -z "${_DAG_IDX[$id]+set}" ]]; then
        return 1
    fi
    echo "${_DAG_TITLES[${_DAG_IDX[$id]}]}"
}

# dag_deps_satisfied ID
# Returns 0 if all dependencies of the given milestone have status=done.
# Returns 0 if the milestone has no dependencies.
dag_deps_satisfied() {
    local id="$1"
    if [[ -z "${_DAG_IDX[$id]+set}" ]]; then
        return 1
    fi
    local deps="${_DAG_DEPS[${_DAG_IDX[$id]}]}"

    # No dependencies — always satisfied
    if [[ -z "$deps" ]]; then
        return 0
    fi

    # Dependencies are comma-separated; splitting on newlines after replacement
    local dep
    while IFS=',' read -r dep; do
        dep="${dep#"${dep%%[![:space:]]*}"}"
        dep="${dep%"${dep##*[![:space:]]}"}"
        [[ -z "$dep" ]] && continue

        if [[ -z "${_DAG_IDX[$dep]+set}" ]]; then
            warn "dag_deps_satisfied: dependency '${dep}' of '${id}' not found in manifest"
            return 1
        fi

        local dep_status="${_DAG_STATUSES[${_DAG_IDX[$dep]}]}"
        if [[ "$dep_status" != "done" ]]; then
            return 1
        fi
    done <<< "${deps//,/$'\n'}"

    return 0
}

# dag_get_frontier
# Prints IDs of milestones whose status is not "done" and all deps are satisfied.
# Output: one ID per line, in manifest order.
dag_get_frontier() {
    local i
    for (( i = 0; i < ${#_DAG_IDS[@]}; i++ )); do
        if [[ "${_DAG_STATUSES[$i]}" == "done" ]]; then
            continue
        fi
        if dag_deps_satisfied "${_DAG_IDS[$i]}"; then
            echo "${_DAG_IDS[$i]}"
        fi
    done
}

# dag_find_next [CURRENT_ID]
# Returns the next actionable milestone ID from the frontier.
# If CURRENT_ID is given, returns the first frontier milestone after it in
# manifest order (or the first frontier milestone if CURRENT_ID is the last).
# If no CURRENT_ID, returns the first frontier milestone.
dag_find_next() {
    local current="${1:-}"
    local frontier
    frontier=$(dag_get_frontier) || true

    if [[ -z "$frontier" ]]; then
        return 1
    fi

    if [[ -z "$current" ]]; then
        echo "$frontier" | head -1
        return 0
    fi

    # Find first frontier ID that comes after current in manifest order
    local current_idx="${_DAG_IDX[$current]:-}"
    if [[ -z "$current_idx" ]]; then
        echo "$frontier" | head -1
        return 0
    fi

    local id
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        local id_idx="${_DAG_IDX[$id]}"
        if [[ "$id_idx" -gt "$current_idx" ]]; then
            echo "$id"
            return 0
        fi
    done <<< "$frontier"

    # Wrapped — no frontier ID after current; return first frontier
    echo "$frontier" | head -1
    return 0
}

# dag_get_active
# Prints IDs of milestones with status "in_progress".
dag_get_active() {
    local i
    for (( i = 0; i < ${#_DAG_IDS[@]}; i++ )); do
        if [[ "${_DAG_STATUSES[$i]}" == "in_progress" ]]; then
            echo "${_DAG_IDS[$i]}"
        fi
    done
}

# --- ID ↔ number conversion -------------------------------------------------

# dag_id_to_number ID
# Converts manifest ID (m01, m02, m03.1) to display number (1, 2, 3.1).
dag_id_to_number() {
    local id="$1"
    # Strip leading 'm' and any leading zeros from each segment
    local num="${id#m}"
    # Handle compound IDs like m03.1 → 3.1
    # Remove leading zeros: 01 → 1, 003 → 3
    num=$(echo "$num" | sed 's/^0*\([0-9]\)/\1/; s/\.0*\([0-9]\)/.\1/g')
    echo "$num"
}

# dag_number_to_id NUMBER
# Converts display number (1, 2, 3.1) to manifest ID (m01, m02, m03.1).
# Looks up in loaded manifest first; falls back to printf-based formatting.
dag_number_to_id() {
    local num="$1"

    # Check loaded manifest for exact match by number
    local i
    for (( i = 0; i < ${#_DAG_IDS[@]}; i++ )); do
        local id_num
        id_num=$(dag_id_to_number "${_DAG_IDS[$i]}")
        if [[ "$id_num" == "$num" ]]; then
            echo "${_DAG_IDS[$i]}"
            return 0
        fi
    done

    # Fallback: format as m{NN}
    local main_num="${num%%.*}"
    local suffix="${num#"$main_num"}"
    printf "m%02d%s" "$main_num" "$suffix"
}

# --- Validation (sourced from milestone_dag_validate.sh) --------------------
# shellcheck source=milestone_dag_validate.sh
source "${TEKHTON_HOME}/lib/milestone_dag_validate.sh"
