#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# milestone_dag_helpers.sh — DAG-aware milestone query wrappers
#
# Dual-path wrappers that check the DAG manifest first and fall back to
# inline CLAUDE.md parsing. Extracted from milestones.sh to stay under the
# 300-line ceiling.
#
# Sourced by tekhton.sh — do not run directly.
# Expects: milestones.sh sourced first (provides parse_milestones)
# Expects: milestone_dag.sh sourced first (provides DAG queries)
# Expects: log(), warn() from common.sh
#
# Provides:
#   parse_milestones_auto  — dual-path milestone list (manifest or inline)
#   get_milestone_count    — count milestones via DAG or inline
#   get_milestone_title    — title lookup via DAG or inline
#   is_milestone_done      — done check via DAG or inline
# =============================================================================

# parse_milestones_auto [CLAUDE_MD_PATH]
# Dual-path wrapper: if a milestone manifest exists (DAG mode), returns
# milestone data from the manifest in the same NUMBER|TITLE|ACCEPTANCE_CRITERIA
# format as parse_milestones(). Otherwise falls back to inline parsing.
# This allows all downstream consumers to work unchanged.
parse_milestones_auto() {
    local claude_md="${1:-CLAUDE.md}"

    # DAG path: manifest exists and DAG is enabled
    if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
       && declare -f has_milestone_manifest &>/dev/null \
       && has_milestone_manifest; then

        # Load manifest if not already loaded
        if [[ "${_DAG_LOADED:-false}" != "true" ]]; then
            load_manifest || {
                warn "parse_milestones_auto: manifest load failed, falling back to inline"
                parse_milestones "$claude_md"
                return
            }
        fi

        local found=0
        local milestone_dir
        milestone_dir=$(_dag_milestone_dir)
        local i
        for (( i = 0; i < ${#_DAG_IDS[@]}; i++ )); do
            local id="${_DAG_IDS[$i]}"
            local title="${_DAG_TITLES[$i]}"
            local num
            num=$(dag_id_to_number "$id")

            # Extract acceptance criteria from the milestone file
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

    # Inline path: no manifest, fall back to traditional parsing
    parse_milestones "$claude_md"
}

# get_milestone_count CLAUDE_MD_PATH
# Returns the number of milestones found. Uses DAG when available.
get_milestone_count() {
    local claude_md="${1:-CLAUDE.md}"

    # DAG path
    if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
       && declare -f has_milestone_manifest &>/dev/null \
       && has_milestone_manifest; then
        if [[ "${_DAG_LOADED:-false}" != "true" ]]; then
            load_manifest 2>/dev/null || true
        fi
        dag_get_count
        return
    fi

    local all_ms
    all_ms=$(parse_milestones "$claude_md" 2>/dev/null) || true
    local count
    count=$(echo "$all_ms" | grep -c '.' || true)
    echo "${count:-0}"
}

# get_milestone_title MILESTONE_NUM CLAUDE_MD_PATH
# Returns the title of a specific milestone. Uses DAG when available.
get_milestone_title() {
    local num="$1"
    local claude_md="${2:-CLAUDE.md}"

    # DAG path
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

    # Collect all output first to avoid SIGPIPE when awk exits early
    local all_milestones
    all_milestones=$(parse_milestones "$claude_md" 2>/dev/null) || true
    echo "$all_milestones" | awk -F'|' -v n="$num" '$1 == n {print $2; exit}'
}

# is_milestone_done MILESTONE_NUM CLAUDE_MD_PATH
# Returns 0 if milestone is done. Checks DAG manifest first, then CLAUDE.md.
is_milestone_done() {
    local num="$1"
    local claude_md="${2:-CLAUDE.md}"

    # DAG path: check manifest status
    if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
       && declare -f has_milestone_manifest &>/dev/null \
       && has_milestone_manifest; then
        if [[ "${_DAG_LOADED:-false}" != "true" ]]; then
            load_manifest 2>/dev/null || true
        fi
        local id
        id=$(dag_number_to_id "$num")
        local status
        status=$(dag_get_status "$id" 2>/dev/null) || return 1
        [[ "$status" == "done" ]]
        return
    fi

    # Inline path: check [DONE] marker in CLAUDE.md
    local num_pattern="${num//./\\.}"
    grep -qiE "^#{1,5}[[:space:]]*\[DONE\][[:space:]]*(M|m)ilestone[[:space:]]+${num_pattern}[[:space:]]*[:.\—\-]" "$claude_md" 2>/dev/null
}
