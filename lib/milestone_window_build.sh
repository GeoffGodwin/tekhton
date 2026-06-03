#!/usr/bin/env bash
# =============================================================================
# milestone_window_build.sh — Multi-milestone budgeted sliding window
#
# Sourced by lib/milestone_window.sh — do not run directly.
# Expects: milestone_dag.sh sourced first (provides DAG queries over the
#          _DAG_* arrays populated by m13's load_manifest shim).
# Expects: context.sh sourced first (provides _add_context_component,
#          _get_model_window, check_context_budget)
# Expects: MILESTONE_WINDOW_PCT, MILESTONE_WINDOW_MAX_CHARS from config.
# Expects: log(), warn() from common.sh.
#
# Provides:
#   _compute_milestone_budget                 — char budget from model window
#   _milestone_priority_list                  — active / frontier / on-deck order
#   _extract_first_paragraph_and_acceptance   — truncation-mode summary
#   _extract_title_line                       — on-deck row
#   build_milestone_window                    — assembles the budgeted block
#
# m41: _extract_first_paragraph_and_acceptance tolerates `**Acceptance
# Criteria:**` (bold-label) and `## Acceptance Criteria` (H2) markup, and
# does NOT terminate on Watch For / Seeds Forward H2 markers so those
# sections survive the truncation path.
# =============================================================================
set -euo pipefail

# _MILESTONE_WINDOW_HEADER_CHARS
# Approximate size of the instruction header prepended by build_milestone_window.
# Subtracted from budget before filling with file content.
_MILESTONE_WINDOW_HEADER_CHARS=350

# _compute_milestone_budget MODEL
# Returns the character budget for the milestone window.
# Budget = min(available_chars * MILESTONE_WINDOW_PCT/100, MILESTONE_WINDOW_MAX_CHARS)
# where available_chars = model_window_tokens * CHARS_PER_TOKEN * CONTEXT_BUDGET_PCT/100.
_compute_milestone_budget() {
    local model="$1"
    local window_tokens
    window_tokens=$(_get_model_window "$model")
    local cpt="${CHARS_PER_TOKEN:-4}"
    local budget_pct="${CONTEXT_BUDGET_PCT:-50}"
    local window_pct="${MILESTONE_WINDOW_PCT:-30}"
    local max_chars="${MILESTONE_WINDOW_MAX_CHARS:-20000}"

    local available_chars
    available_chars=$(( window_tokens * cpt * budget_pct / 100 ))

    local milestone_chars
    milestone_chars=$(( available_chars * window_pct / 100 ))

    if [[ "$milestone_chars" -gt "$max_chars" ]]; then
        milestone_chars="$max_chars"
    fi

    echo "$milestone_chars"
}

# _milestone_priority_list
# Returns ordered milestone IDs by priority:
#   1. Active milestone (status=in_progress)
#   2. Frontier milestones (deps satisfied, not done)
#   3. On-deck milestones (deps not yet satisfied, not done)
# Output: one ID per line.
_milestone_priority_list() {
    local active_ids=""
    local frontier_ids=""
    local ondeck_ids=""

    local i
    for (( i = 0; i < ${#_DAG_IDS[@]}; i++ )); do
        local id="${_DAG_IDS[$i]}"
        local status="${_DAG_STATUSES[$i]}"

        [[ "$status" == "done" ]] && continue

        if [[ "$status" == "in_progress" ]]; then
            active_ids="${active_ids}${id}"$'\n'
        elif dag_deps_satisfied "$id"; then
            frontier_ids="${frontier_ids}${id}"$'\n'
        else
            ondeck_ids="${ondeck_ids}${id}"$'\n'
        fi
    done

    printf '%s' "${active_ids}${frontier_ids}${ondeck_ids}"
}

# _extract_first_paragraph_and_acceptance CONTENT
# Returns the first paragraph (up to first blank line) plus the acceptance
# criteria section. Used for frontier milestones when budget is tight.
#
# m41 widening: matches `## Acceptance Criteria` (H2/H3), `**Acceptance
# Criteria:**` (bold-label), AND bare `Acceptance Criteria:`. The
# heading-end check also exempts `## Watch For` and `## Seeds Forward`
# so those sections survive when the file uses H2 markup throughout.
_extract_first_paragraph_and_acceptance() {
    local content="$1"
    local first_para=""
    local acceptance=""
    local in_acceptance=false
    local past_first_blank=false

    while IFS= read -r line; do
        if [[ "$past_first_blank" == false ]]; then
            if [[ -z "$line" ]] && [[ -n "$first_para" ]]; then
                past_first_blank=true
            else
                first_para="${first_para}${line}"$'\n'
            fi
        fi

        if [[ "$line" =~ ^[[:space:]]*(#+[[:space:]]+|\*\*)?(A|a)cceptance[[:space:]]+(C|c)riteria ]]; then
            in_acceptance=true
            acceptance="${acceptance}${line}"$'\n'
            continue
        fi

        if [[ "$in_acceptance" == true ]]; then
            # End on next heading — but keep Watch For / Seeds Forward
            # rolled into the section so downstream agents see them even
            # when the file uses H2 markup throughout.
            if [[ "$line" =~ ^#{1,5}[[:space:]] ]] \
               && [[ ! "$line" =~ ((A|a)cceptance|(W|w)atch[[:space:]]+(F|f)or|(S|s)eeds[[:space:]]+(F|f)orward) ]]; then
                in_acceptance=false
                continue
            fi
            acceptance="${acceptance}${line}"$'\n'
        fi
    done <<< "$content"

    printf '%s' "${first_para}"
    if [[ -n "$acceptance" ]]; then
        printf '\n%s' "$acceptance"
    fi
}

# _extract_title_line CONTENT
# Returns just the first non-empty line. Used for on-deck milestones.
_extract_title_line() {
    local content="$1"
    local first_line=""
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            first_line="$line"
            break
        fi
    done <<< "$content"
    echo "$first_line"
}

# build_milestone_window MODEL
# Assembles a character-budgeted milestone context block from the manifest.
# Priority: active milestone (full) → frontier (first para + acceptance) →
# on-deck (title only). Fills greedily until budget exhaustion.
# Sets MILESTONE_BLOCK global variable with the assembled content.
# Returns 0 on success, 1 if no manifest or no milestones to show.
build_milestone_window() {
    local model="$1"

    if [[ "${MILESTONE_DAG_ENABLED:-true}" != "true" ]]; then
        return 1
    fi
    if [[ "${_DAG_LOADED:-false}" != "true" ]]; then
        return 1
    fi

    local budget
    budget=$(_compute_milestone_budget "$model")

    local remaining
    remaining=$(( budget - _MILESTONE_WINDOW_HEADER_CHARS ))
    if [[ "$remaining" -le 0 ]]; then
        warn "[milestone_window] Budget too small for any milestone content"
        return 1
    fi

    local priority_list
    priority_list=$(_milestone_priority_list)

    if [[ -z "$priority_list" ]]; then
        return 1
    fi

    local window_content=""
    local is_first=true
    local included_count=0

    while IFS= read -r id; do
        [[ -z "$id" ]] && continue

        local full_content
        full_content=$(_read_milestone_file "$id")
        if [[ -z "$full_content" ]]; then
            continue
        fi

        local status
        status=$(dag_get_status "$id" 2>/dev/null) || true
        local num
        num=$(dag_id_to_number "$id")

        local entry=""

        if [[ "$status" == "in_progress" ]]; then
            local content_len=${#full_content}
            if [[ "$content_len" -le "$remaining" ]]; then
                entry="$full_content"
            else
                local truncated
                truncated=$(_extract_first_paragraph_and_acceptance "$full_content")
                if [[ ${#truncated} -le "$remaining" ]]; then
                    entry="$truncated"
                    warn "[milestone_window] Active milestone ${num} truncated to fit budget"
                else
                    entry=$(_extract_title_line "$full_content")
                    warn "[milestone_window] Active milestone ${num} severely truncated"
                fi
            fi
        elif dag_deps_satisfied "$id"; then
            local summary
            summary=$(_extract_first_paragraph_and_acceptance "$full_content")
            if [[ ${#summary} -le "$remaining" ]]; then
                entry="$summary"
            else
                entry=$(_extract_title_line "$full_content")
            fi
        else
            entry=$(_extract_title_line "$full_content")
        fi

        if [[ -z "$entry" ]]; then
            continue
        fi

        local entry_len=${#entry}
        if [[ "$entry_len" -gt "$remaining" ]]; then
            break
        fi

        if [[ "$is_first" == true ]]; then
            is_first=false
        else
            window_content="${window_content}"$'\n\n'
        fi

        window_content="${window_content}${entry}"
        remaining=$(( remaining - entry_len ))
        included_count=$(( included_count + 1 ))
    done <<< "$priority_list"

    if [[ "$included_count" -eq 0 ]]; then
        return 1
    fi

    local _header
    read -r -d '' _header << 'WINDOW_HEADER' || true
## Milestone Mode
This is a milestone-sized task. Before writing any code:
1. Read the active milestone section below in full
2. Check the Seeds forward annotations for architectural decisions
   that must be made now to avoid rework later
3. Note any Watch for annotations and design those extension points into your implementation
4. Document your architectural decisions in ${CODER_SUMMARY_FILE} under Architecture Decisions
WINDOW_HEADER

    MILESTONE_BLOCK="${_header}

${window_content}"
    export MILESTONE_BLOCK

    _add_context_component "Milestone Window" "$MILESTONE_BLOCK"

    log_verbose "[milestone_window] Included ${included_count} milestone(s), ${budget} budget, ${remaining} remaining"
    return 0
}
