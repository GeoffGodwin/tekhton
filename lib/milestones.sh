#!/usr/bin/env bash
set -euo pipefail
# milestones.sh — Milestone state machine and acceptance checking
# Sourced by tekhton.sh — expects: PROJECT_DIR, PIPELINE_STATE_FILE, TEST_CMD, ANALYZE_CMD, log(), warn(), success(), header(), run_build_gate()
# Provides: parse_milestones, get_current_milestone, advance_milestone, write_milestone_disposition, init_milestone_state
# Acceptance checking, commit signatures, auto-advance in milestone_ops.sh; archival in milestone_archival.sh
# =============================================================================

# --- Constants ---------------------------------------------------------------

MILESTONE_STATE_FILE="${PROJECT_DIR}/.claude/MILESTONE_STATE.md"

# --- Milestone parsing -------------------------------------------------------

# parse_milestones CLAUDE_MD_PATH
# Extracts numbered milestones from a CLAUDE.md file.
# Outputs lines in format: NUMBER|TITLE|ACCEPTANCE_CRITERIA
# Acceptance criteria are semicolon-separated.
# Returns 0 if at least one milestone found, 1 otherwise.
parse_milestones() {
    local claude_md="${1:-CLAUDE.md}"

    if [[ ! -f "$claude_md" ]]; then
        warn "parse_milestones: ${claude_md} not found"
        return 1
    fi

    local found=0
    local current_num=""
    local current_title=""
    local in_acceptance=false
    local acceptance_lines=""

    while IFS= read -r line; do
        # Match milestone headings: #### Milestone N: Title
        # Also handles: #### Milestone N — Title, #### Milestone N. Title
        # And [DONE] markers: #### [DONE] Milestone N: Title
        # Supports arbitrary depth: 13, 13.2, 13.2.1, 13.2.1.1, etc.
        if [[ "$line" =~ ^[[:space:]]*#{1,5}[[:space:]]*(\[DONE\][[:space:]]*)?(M|m)ilestone[[:space:]]+([0-9]+([.][0-9]+)*)[[:space:]]*[:.\.\—\-][[:space:]]*(.*) ]]; then
            # Flush previous milestone if any
            if [[ -n "$current_num" ]]; then
                echo "${current_num}|${current_title}|${acceptance_lines}"
                found=1
            fi
            current_num="${BASH_REMATCH[3]}"
            current_title="${BASH_REMATCH[5]}"
            # Trim trailing whitespace
            current_title="${current_title%"${current_title##*[![:space:]]}"}"
            in_acceptance=false
            acceptance_lines=""
            continue
        fi

        # Detect acceptance criteria section within a milestone
        if [[ -n "$current_num" ]] && [[ "$line" =~ ^[[:space:]]*(A|a)cceptance[[:space:]]+(C|c)riteria ]]; then
            in_acceptance=true
            continue
        fi

        # A new heading of same or higher level ends the current milestone
        if [[ -n "$current_num" ]] && [[ "$line" =~ ^#{1,4}[[:space:]] ]] && [[ ! "$line" =~ ^#{5,} ]]; then
            # Check if this is a sub-heading within the milestone (##### or deeper)
            # or a sibling/parent heading that ends the milestone
            local heading_level
            heading_level=$(echo "$line" | grep -oE '^#{1,}' | wc -c)
            heading_level=$((heading_level - 1))  # wc -c counts newline
            if [[ "$heading_level" -le 4 ]]; then
                # Flush current milestone
                echo "${current_num}|${current_title}|${acceptance_lines}"
                found=1
                current_num=""
                current_title=""
                in_acceptance=false
                acceptance_lines=""
            fi
        fi

        # Collect acceptance criteria lines (bullet points starting with -)
        if [[ "$in_acceptance" = true ]] && [[ "$line" =~ ^[[:space:]]*[-*][[:space:]]+(.*) ]]; then
            local criterion="${BASH_REMATCH[1]}"
            if [[ -n "$acceptance_lines" ]]; then
                acceptance_lines="${acceptance_lines};${criterion}"
            else
                acceptance_lines="${criterion}"
            fi
        fi

        # End acceptance criteria on next section heading or empty line after content
        if [[ "$in_acceptance" = true ]] && [[ "$line" =~ ^[[:space:]]*$ ]] && [[ -n "$acceptance_lines" ]]; then
            # Keep collecting — acceptance criteria can have blank lines between items
            :
        fi

        # Stop acceptance if we hit a non-acceptance heading within the milestone
        if [[ "$in_acceptance" = true ]] && [[ -n "$current_num" ]] && [[ "$line" =~ ^#{5,}[[:space:]] ]]; then
            in_acceptance=false
        fi
    done < "$claude_md"

    # Flush last milestone
    if [[ -n "$current_num" ]]; then
        echo "${current_num}|${current_title}|${acceptance_lines}"
        found=1
    fi

    [[ "$found" -eq 1 ]]
}

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

# --- Milestone state file management ----------------------------------------

# init_milestone_state MILESTONE_NUM [TOTAL_MILESTONES]
# Creates or resets MILESTONE_STATE.md with the starting milestone.
init_milestone_state() {
    local start_num="${1:-1}"
    local total="${2:-0}"

    local state_dir
    state_dir="$(dirname "$MILESTONE_STATE_FILE")"
    mkdir -p "$state_dir"

    cat > "$MILESTONE_STATE_FILE" << EOF
# Milestone State — $(date '+%Y-%m-%d %H:%M:%S')
## Current Milestone
${start_num}

## Total Milestones
${total}

## Status
PENDING

## Disposition
NONE

## Milestones Completed This Session
0

## Transition History
- $(date '+%Y-%m-%d %H:%M:%S') — Initialized at milestone ${start_num}
EOF
    log "Milestone state initialized at milestone ${start_num}"
}

# get_current_milestone
# Reads the current milestone number from MILESTONE_STATE.md.
# Returns 0 and prints the number, or returns 1 if no state file.
get_current_milestone() {
    if [[ ! -f "$MILESTONE_STATE_FILE" ]]; then
        return 1
    fi

    awk '/^## Current Milestone$/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit}' \
        "$MILESTONE_STATE_FILE"
}

# get_milestone_disposition
# Reads the current disposition from MILESTONE_STATE.md.
get_milestone_disposition() {
    if [[ ! -f "$MILESTONE_STATE_FILE" ]]; then
        echo "NONE"
        return
    fi

    awk '/^## Disposition$/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit}' \
        "$MILESTONE_STATE_FILE"
}

# get_milestones_completed_this_session
# Returns the count of milestones completed in the current auto-advance session.
get_milestones_completed_this_session() {
    if [[ ! -f "$MILESTONE_STATE_FILE" ]]; then
        echo "0"
        return
    fi

    awk '/^## Milestones Completed This Session$/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit}' \
        "$MILESTONE_STATE_FILE"
}

# write_milestone_disposition DISPOSITION
# Updates the disposition field in MILESTONE_STATE.md.
# Valid dispositions: COMPLETE_AND_CONTINUE, COMPLETE_AND_WAIT,
#                     INCOMPLETE_REWORK, REPLAN_REQUIRED
write_milestone_disposition() {
    local disposition="$1"

    if [[ ! -f "$MILESTONE_STATE_FILE" ]]; then
        warn "write_milestone_disposition: no state file found"
        return 1
    fi

    # Validate disposition
    case "$disposition" in
        COMPLETE_AND_CONTINUE|COMPLETE_AND_WAIT|INCOMPLETE_REWORK|REPLAN_REQUIRED) ;;
        *) warn "write_milestone_disposition: invalid disposition '${disposition}'"; return 1 ;;
    esac

    # Update disposition in-place using a temp file
    local tmp_file
    tmp_file="$(mktemp "${MILESTONE_STATE_FILE}.XXXXXX")"

    awk -v disp="$disposition" '
        /^## Disposition$/ { print; getline; print disp; next }
        /^## Status$/ {
            print; getline;
            if (disp ~ /^COMPLETE/) print "COMPLETE"
            else if (disp == "INCOMPLETE_REWORK") print "REWORK"
            else if (disp == "REPLAN_REQUIRED") print "REPLAN"
            else print
            next
        }
        { print }
    ' "$MILESTONE_STATE_FILE" > "$tmp_file"

    mv -f "$tmp_file" "$MILESTONE_STATE_FILE"

    # Append to transition history
    echo "- $(date '+%Y-%m-%d %H:%M:%S') — Disposition: ${disposition}" >> "$MILESTONE_STATE_FILE"

    log "Milestone disposition: ${disposition}"
}

# advance_milestone FROM_NUM TO_NUM
# Updates MILESTONE_STATE.md to the next milestone and prints a transition banner.
advance_milestone() {
    local from_num="$1"
    local to_num="$2"

    if [[ ! -f "$MILESTONE_STATE_FILE" ]]; then
        warn "advance_milestone: no state file found"
        return 1
    fi

    local completed_count
    completed_count=$(get_milestones_completed_this_session)
    completed_count=$(( completed_count + 1 ))

    local to_title
    to_title=$(get_milestone_title "$to_num")

    # Update state file
    local tmp_file
    tmp_file="$(mktemp "${MILESTONE_STATE_FILE}.XXXXXX")"

    awk -v new_num="$to_num" -v new_count="$completed_count" '
        /^## Current Milestone$/ { print; getline; print new_num; next }
        /^## Status$/ { print; getline; print "PENDING"; next }
        /^## Disposition$/ { print; getline; print "NONE"; next }
        /^## Milestones Completed This Session$/ { print; getline; print new_count; next }
        { print }
    ' "$MILESTONE_STATE_FILE" > "$tmp_file"

    mv -f "$tmp_file" "$MILESTONE_STATE_FILE"

    # Append transition to history
    echo "- $(date '+%Y-%m-%d %H:%M:%S') — Advanced: milestone ${from_num} → ${to_num}" >> "$MILESTONE_STATE_FILE"

    # Print transition banner
    echo
    header "Milestone ${from_num} COMPLETE — Advancing to Milestone ${to_num}"
    if [[ -n "$to_title" ]]; then
        log "Next: Milestone ${to_num}: ${to_title}"
    fi
    log "Milestones completed this session: ${completed_count}"
    echo
}


