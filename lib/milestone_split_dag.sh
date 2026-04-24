#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# milestone_split_dag.sh — DAG-mode helpers for milestone splitting
#
# Sourced by milestone_split.sh — do not run directly.
# Expects: load_manifest, save_manifest, has_milestone_manifest,
#          _dag_milestone_dir from milestone_dag_io.sh
#          dag_number_to_id, dag_get_file, dag_set_status from milestone_dag.sh
#          _slugify from milestone_dag_migrate.sh
#          error() from common.sh
#
# Provides:
#   _split_read_dag_milestone  — read milestone definition from DAG file
#   _split_apply_dag           — parse sub-milestones, write files, splice manifest
# =============================================================================

# _split_read_dag_milestone MILESTONE_NUM
# Echoes the contents of the milestone's DAG file.
# Returns 0 on success, 1 if file not found or ID unknown.
_split_read_dag_milestone() {
    local milestone_num="$1"
    local dag_id
    dag_id=$(dag_number_to_id "$milestone_num")

    local dag_file
    if ! dag_file=$(dag_get_file "$dag_id"); then
        error "Milestone ${milestone_num} (id: ${dag_id}) not found in DAG manifest"
        return 1
    fi

    local dir
    dir=$(_dag_milestone_dir)
    local path="${dir}/${dag_file}"

    if [[ ! -f "$path" ]]; then
        error "Milestone file missing: ${path}"
        return 1
    fi

    cat "$path"
}

# _split_apply_dag MILESTONE_NUM SPLIT_OUTPUT
# Parses sub-milestones from agent output, writes their .md files to the
# milestone directory, splices them into the manifest arrays immediately
# after the parent milestone's position, marks the parent as "split", and
# saves the manifest.
# Returns 0 on success, 1 on failure.
_split_apply_dag() {
    local milestone_num="$1"
    local split_output="$2"

    local parent_id
    parent_id=$(dag_number_to_id "$milestone_num")
    local parent_idx="${_DAG_IDX[$parent_id]:-}"
    if [[ -z "$parent_idx" ]]; then
        error "Parent milestone ${parent_id} not found in DAG"
        return 1
    fi
    local parent_deps="${_DAG_DEPS[$parent_idx]:-}"

    local milestone_dir
    milestone_dir=$(_dag_milestone_dir)

    local new_ids=() new_titles=() new_files=() new_deps=()
    local sub_num="" sub_title="" sub_block="" prev_sub_id=""

    _split_flush_sub_entry() {
        [[ -z "$sub_num" ]] && return 0
        local sub_main="${sub_num%%.*}"
        local sub_suffix="${sub_num#"$sub_main"}"
        local sub_id
        sub_id=$(printf "m%02d%s" "$sub_main" "$sub_suffix")
        local sub_slug
        sub_slug=$(_slugify "$sub_title")
        local sub_file="${sub_id}-${sub_slug}.md"
        # Path-traversal guard: reject any filename that has survived slugging
        # with a path separator or that is the bare ".." traversal token.
        # Keeps write safety independent of _slugify's current behaviour, and
        # makes the defensive intent self-documenting even though the OS would
        # reject a bare ".." write path anyway.
        if [[ "$sub_file" == */* ]] || [[ "$sub_file" == ".." ]]; then
            error "Refusing to write milestone file with path separator: ${sub_file}"
            return 1
        fi
        echo "$sub_block" > "${milestone_dir}/${sub_file}"

        local sub_deps="$prev_sub_id"
        [[ -z "$sub_deps" ]] && sub_deps="$parent_deps"

        new_ids+=("$sub_id")
        new_titles+=("$sub_title")
        new_files+=("$sub_file")
        new_deps+=("$sub_deps")
        prev_sub_id="$sub_id"
    }

    while IFS= read -r line; do
        if [[ "$line" =~ ^#{1,5}[[:space:]]*[Mm]ilestone[[:space:]]+([0-9]+([.][0-9]+)*)[[:space:]]*[:.\—\-][[:space:]]*(.*) ]]; then
            _split_flush_sub_entry
            sub_num="${BASH_REMATCH[1]}"
            sub_title="${BASH_REMATCH[3]}"
            sub_title="${sub_title%"${sub_title##*[![:space:]]}"}"
            sub_block="$line"
            continue
        fi
        if [[ -n "$sub_num" ]]; then
            sub_block="${sub_block}"$'\n'"${line}"
        fi
    done <<< "$split_output"
    _split_flush_sub_entry
    unset -f _split_flush_sub_entry

    local insert_count="${#new_ids[@]}"
    if (( insert_count == 0 )); then
        error "Failed to parse sub-milestones from split output"
        return 1
    fi

    local rebuilt_ids=() rebuilt_titles=() rebuilt_statuses=() \
          rebuilt_deps=() rebuilt_files=() rebuilt_groups=()
    local i j
    for (( i = 0; i < ${#_DAG_IDS[@]}; i++ )); do
        rebuilt_ids+=("${_DAG_IDS[$i]}")
        rebuilt_titles+=("${_DAG_TITLES[$i]}")
        rebuilt_statuses+=("${_DAG_STATUSES[$i]}")
        rebuilt_deps+=("${_DAG_DEPS[$i]}")
        rebuilt_files+=("${_DAG_FILES[$i]}")
        rebuilt_groups+=("${_DAG_GROUPS[$i]}")
        if (( i == parent_idx )); then
            for (( j = 0; j < insert_count; j++ )); do
                rebuilt_ids+=("${new_ids[$j]}")
                rebuilt_titles+=("${new_titles[$j]}")
                rebuilt_statuses+=("pending")
                rebuilt_deps+=("${new_deps[$j]}")
                rebuilt_files+=("${new_files[$j]}")
                rebuilt_groups+=("")
            done
        fi
    done

    _DAG_IDS=("${rebuilt_ids[@]}")
    _DAG_TITLES=("${rebuilt_titles[@]}")
    _DAG_STATUSES=("${rebuilt_statuses[@]}")
    _DAG_DEPS=("${rebuilt_deps[@]}")
    _DAG_FILES=("${rebuilt_files[@]}")
    _DAG_GROUPS=("${rebuilt_groups[@]}")

    _DAG_IDX=()
    for (( i = 0; i < ${#_DAG_IDS[@]}; i++ )); do
        _DAG_IDX["${_DAG_IDS[$i]}"]=$i
    done

    dag_set_status "$parent_id" "split"
    save_manifest

    return 0
}
