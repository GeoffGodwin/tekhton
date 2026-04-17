#!/usr/bin/env bash
# =============================================================================
# milestone_window.sh — Character-budgeted milestone sliding window
#
# Sourced by tekhton.sh — do not run directly.
# Expects: milestone_dag.sh sourced first (provides DAG queries)
# Expects: context.sh sourced first (provides _add_context_component,
#          _get_model_window, check_context_budget)
# Expects: MILESTONE_WINDOW_PCT, MILESTONE_WINDOW_MAX_CHARS from config
# Expects: log(), warn() from common.sh
#
# Provides:
#   build_milestone_window  — assembles budgeted milestone context block
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

    # Total available chars for the entire prompt
    local available_chars
    available_chars=$(( window_tokens * cpt * budget_pct / 100 ))

    # Milestone's share
    local milestone_chars
    milestone_chars=$(( available_chars * window_pct / 100 ))

    # Apply hard cap
    if [[ "$milestone_chars" -gt "$max_chars" ]]; then
        milestone_chars="$max_chars"
    fi

    echo "$milestone_chars"
}

# _milestone_priority_list
# Returns ordered milestone IDs by priority:
#   1. Active milestone (status=in_progress) — highest priority
#   2. Frontier milestones (deps satisfied, not done) — in manifest order
#   3. On-deck milestones (deps not yet satisfied, not done) — in manifest order
# Output: one ID per line.
_milestone_priority_list() {
    local active_ids=""
    local frontier_ids=""
    local ondeck_ids=""

    local i
    for (( i = 0; i < ${#_DAG_IDS[@]}; i++ )); do
        local id="${_DAG_IDS[$i]}"
        local status="${_DAG_STATUSES[$i]}"

        # Skip done milestones
        [[ "$status" == "done" ]] && continue

        if [[ "$status" == "in_progress" ]]; then
            active_ids="${active_ids}${id}"$'\n'
        elif dag_deps_satisfied "$id"; then
            frontier_ids="${frontier_ids}${id}"$'\n'
        else
            ondeck_ids="${ondeck_ids}${id}"$'\n'
        fi
    done

    # Output in priority order
    printf '%s' "${active_ids}${frontier_ids}${ondeck_ids}"
}

# _read_milestone_file ID
# Reads the full content of a milestone file. Returns empty if not found.
_read_milestone_file() {
    local id="$1"
    local file
    file=$(dag_get_file "$id" 2>/dev/null) || return 0
    if [[ -z "$file" ]]; then
        return 0
    fi
    local milestone_dir
    milestone_dir=$(_dag_milestone_dir)
    local path="${milestone_dir}/${file}"
    if [[ -f "$path" ]]; then
        cat "$path"
    fi
}

# _extract_first_paragraph_and_acceptance CONTENT
# Returns the first paragraph (up to first blank line) plus the acceptance
# criteria section. Used for frontier milestones when budget is tight.
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

        if [[ "$line" =~ ^[[:space:]]*(A|a)cceptance[[:space:]]+(C|c)riteria ]]; then
            in_acceptance=true
            acceptance="${acceptance}${line}"$'\n'
            continue
        fi

        if [[ "$in_acceptance" == true ]]; then
            # End on next heading
            if [[ "$line" =~ ^#{1,5}[[:space:]] ]] && [[ ! "$line" =~ (A|a)cceptance ]]; then
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
# Returns just the first heading line. Used for on-deck milestones.
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

    # Require DAG mode with loaded manifest
    if [[ "${MILESTONE_DAG_ENABLED:-true}" != "true" ]]; then
        return 1
    fi
    if [[ "${_DAG_LOADED:-false}" != "true" ]]; then
        return 1
    fi

    local budget
    budget=$(_compute_milestone_budget "$model")

    # Subtract header overhead
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
            # Active milestone: include full content
            local content_len=${#full_content}
            if [[ "$content_len" -le "$remaining" ]]; then
                entry="$full_content"
            else
                # Truncate but keep acceptance criteria
                local truncated
                truncated=$(_extract_first_paragraph_and_acceptance "$full_content")
                if [[ ${#truncated} -le "$remaining" ]]; then
                    entry="$truncated"
                    warn "[milestone_window] Active milestone ${num} truncated to fit budget"
                else
                    # Last resort: just the title
                    entry=$(_extract_title_line "$full_content")
                    warn "[milestone_window] Active milestone ${num} severely truncated"
                fi
            fi
        elif dag_deps_satisfied "$id"; then
            # Frontier milestone: first paragraph + acceptance criteria
            local summary
            summary=$(_extract_first_paragraph_and_acceptance "$full_content")
            if [[ ${#summary} -le "$remaining" ]]; then
                entry="$summary"
            else
                # Trim to title only
                entry=$(_extract_title_line "$full_content")
            fi
        else
            # On-deck milestone: title + one-line description only
            entry=$(_extract_title_line "$full_content")
        fi

        if [[ -z "$entry" ]]; then
            continue
        fi

        local entry_len=${#entry}
        if [[ "$entry_len" -gt "$remaining" ]]; then
            # Budget exhausted
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

    # Assemble the final block with instruction header using heredoc
    # to avoid shellcheck SC2089/SC2090 with printf
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

    # Integrate with context accounting
    _add_context_component "Milestone Window" "$MILESTONE_BLOCK"

    log_verbose "[milestone_window] Included ${included_count} milestone(s), ${budget} budget, ${remaining} remaining"
    return 0
}
