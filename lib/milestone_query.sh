#!/usr/bin/env bash
# =============================================================================
# milestone_query.sh — DAG-aware milestone query wrappers.
#
# Sourced by tekhton.sh after milestone_dag.sh — do not run directly.
# Replaces the deleted lib/milestone_dag_helpers.sh (m14): same dual-path
# wrappers that prefer the DAG (Go-backed) path when a manifest is present
# and fall back to inline CLAUDE.md parsing otherwise.
#
# Expects: parse_milestones() from milestones.sh; dag_* queries from
#          milestone_dag.sh; log(), warn() from common.sh.
#
# Provides:
#   parse_milestones_auto  — dual-path milestone list (manifest or inline)
#   get_milestone_count    — count milestones via DAG or inline
#   get_milestone_title    — title lookup via DAG or inline
#   is_milestone_done      — done check via DAG or inline
# =============================================================================

# parse_milestones_auto [CLAUDE_MD_PATH]
# Returns NUMBER|TITLE|ACCEPTANCE_CRITERIA rows from the DAG manifest when
# present; falls back to inline parse_milestones when no manifest exists or
# DAG mode is disabled. Acceptance criteria are extracted by reading each
# milestone file's "Acceptance Criteria" bullet list.
parse_milestones_auto() {
    local claude_md="${1:-CLAUDE.md}"

    if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
       && declare -f has_milestone_manifest &>/dev/null \
       && has_milestone_manifest; then

        if [[ "${_DAG_LOADED:-false}" != "true" ]]; then
            load_manifest || {
                warn "parse_milestones_auto: manifest load failed, falling back to inline"
                parse_milestones "$claude_md"
                return
            }
        fi

        local found=0 milestone_dir i
        milestone_dir=$(_dag_milestone_dir)
        for (( i = 0; i < ${#_DAG_IDS[@]}; i++ )); do
            local id="${_DAG_IDS[$i]}" title="${_DAG_TITLES[$i]}" num
            num=$(dag_id_to_number "$id")

            local acceptance=""
            local file="${_DAG_FILES[$i]}"
            if [[ -n "$file" ]] && [[ -f "${milestone_dir}/${file}" ]]; then
                local in_acceptance=false
                while IFS= read -r line; do
                    if [[ "$line" =~ ^[[:space:]]*(A|a)cceptance[[:space:]]+(C|c)riteria ]]; then
                        in_acceptance=true
                        continue
                    fi
                    if [[ "$in_acceptance" == true ]] && [[ "$line" =~ ^#{1,5}[[:space:]] ]]; then
                        in_acceptance=false
                    fi
                    if [[ "$in_acceptance" == true ]] && [[ "$line" =~ ^[[:space:]]*[-*][[:space:]]+(.*) ]]; then
                        local criterion="${BASH_REMATCH[1]}"
                        if [[ -n "$acceptance" ]]; then
                            acceptance="${acceptance};${criterion}"
                        else
                            acceptance="${criterion}"
                        fi
                    fi
                done < "${milestone_dir}/${file}"
            fi

            echo "${num}|${title}|${acceptance}"
            found=1
        done

        [[ "$found" -eq 1 ]]
        return
    fi

    parse_milestones "$claude_md"
}

# get_milestone_count CLAUDE_MD_PATH — milestone count via DAG or inline.
get_milestone_count() {
    local claude_md="${1:-CLAUDE.md}"

    if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
       && declare -f has_milestone_manifest &>/dev/null \
       && has_milestone_manifest; then
        if [[ "${_DAG_LOADED:-false}" != "true" ]]; then
            load_manifest 2>/dev/null || true
        fi
        dag_get_count
        return
    fi

    local all_ms count
    all_ms=$(parse_milestones "$claude_md" 2>/dev/null) || true
    count=$(echo "$all_ms" | grep -c '.' || true)
    echo "${count:-0}"
}

# get_milestone_title MILESTONE_NUM CLAUDE_MD_PATH — title via DAG or inline.
get_milestone_title() {
    local num="$1"
    local claude_md="${2:-CLAUDE.md}"

    if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
       && declare -f has_milestone_manifest &>/dev/null \
       && has_milestone_manifest; then
        if [[ "${_DAG_LOADED:-false}" != "true" ]]; then
            load_manifest 2>/dev/null || true
        fi
        local id
        id=$(dag_number_to_id "$num")
        dag_get_title "$id" 2>/dev/null || true
        return
    fi

    local all_milestones
    all_milestones=$(parse_milestones "$claude_md" 2>/dev/null) || true
    echo "$all_milestones" | awk -F'|' -v n="$num" '$1 == n {print $2; exit}'
}

# is_milestone_done MILESTONE_NUM CLAUDE_MD_PATH — done check via DAG or inline.
is_milestone_done() {
    local num="$1"
    local claude_md="${2:-CLAUDE.md}"

    if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
       && declare -f has_milestone_manifest &>/dev/null \
       && has_milestone_manifest; then
        if [[ "${_DAG_LOADED:-false}" != "true" ]]; then
            load_manifest 2>/dev/null || true
        fi
        local id status
        id=$(dag_number_to_id "$num")
        status=$(dag_get_status "$id" 2>/dev/null) || return 1
        [[ "$status" == "done" ]]
        return
    fi

    local num_pattern="${num//./\\.}"
    grep -qiE "^#{1,5}[[:space:]]*\[DONE\][[:space:]]*(M|m)ilestone[[:space:]]+${num_pattern}[[:space:]]*[:.\—\-]" "$claude_md" 2>/dev/null
}
