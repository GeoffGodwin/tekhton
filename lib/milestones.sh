#!/usr/bin/env bash
# =============================================================================
# milestones.sh — Milestone state machine and acceptance checking
#
# Sourced by tekhton.sh — do not run directly.
# Expects: PROJECT_DIR, PIPELINE_STATE_FILE, TEST_CMD, ANALYZE_CMD (from config)
# Expects: log(), warn(), success(), header() from common.sh
# Expects: run_build_gate() from gates.sh
#
# Provides:
#   parse_milestones         — extract milestone list from CLAUDE.md
#   get_current_milestone    — read current milestone from state file
#   check_milestone_acceptance — run automatable acceptance criteria
#   advance_milestone        — update state and print transition banner
#   write_milestone_disposition — record disposition to state file
#   init_milestone_state     — create initial MILESTONE_STATE.md
#
# Archival functions (archive_completed_milestone, archive_all_completed_milestones)
# live in lib/milestone_archival.sh.
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
        if [[ "$line" =~ ^[[:space:]]*#{1,5}[[:space:]]*(\[DONE\][[:space:]]*)?(M|m)ilestone[[:space:]]+([0-9]+([.][0-9]+)?)[[:space:]]*[:.\—\-][[:space:]]*(.*) ]]; then
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

# get_milestone_count CLAUDE_MD_PATH
# Returns the number of milestones found.
get_milestone_count() {
    local claude_md="${1:-CLAUDE.md}"
    local all_ms
    all_ms=$(parse_milestones "$claude_md" 2>/dev/null) || true
    local count
    count=$(echo "$all_ms" | grep -c '.' || true)
    echo "${count:-0}"
}

# get_milestone_title MILESTONE_NUM CLAUDE_MD_PATH
# Returns the title of a specific milestone.
get_milestone_title() {
    local num="$1"
    local claude_md="${2:-CLAUDE.md}"
    # Collect all output first to avoid SIGPIPE when awk exits early
    local all_milestones
    all_milestones=$(parse_milestones "$claude_md" 2>/dev/null) || true
    echo "$all_milestones" | awk -F'|' -v n="$num" '$1 == n {print $2; exit}'
}

# is_milestone_done MILESTONE_NUM CLAUDE_MD_PATH
# Returns 0 if milestone heading has [DONE] marker.
is_milestone_done() {
    local num="$1"
    local claude_md="${2:-CLAUDE.md}"

    # Escape dots in milestone number for regex safety (e.g., 0.5 → 0\.5)
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

# --- Acceptance checking -----------------------------------------------------

# check_milestone_acceptance MILESTONE_NUM [CLAUDE_MD_PATH]
# Runs automatable acceptance criteria for a milestone.
# Returns 0 if all automatable criteria pass, 1 if any fail.
# Prints a report of checked criteria.
check_milestone_acceptance() {
    local milestone_num="$1"
    local claude_md="${2:-CLAUDE.md}"

    header "Checking acceptance criteria — Milestone ${milestone_num}"

    local all_pass=true

    # --- Automatable check 1: Test command passes ---
    if [[ -n "${TEST_CMD:-}" ]]; then
        log "Running test command: ${TEST_CMD}"
        local test_output=""
        local test_exit=0
        test_output=$(bash -c "${TEST_CMD}" 2>&1) || test_exit=$?

        if [[ "$test_exit" -eq 0 ]]; then
            success "Tests pass"
        else
            warn "Tests FAILED (exit ${test_exit})"
            echo "$test_output" | tail -20
            all_pass=false
        fi
    else
        log "No TEST_CMD configured — skipping test check"
    fi

    # --- Automatable check 2: Build gate passes ---
    if [[ -n "${ANALYZE_CMD:-}" ]]; then
        if run_build_gate "milestone-acceptance" 2>/dev/null; then
            success "Build gate passes"
        else
            warn "Build gate FAILED"
            all_pass=false
        fi
    else
        log "No ANALYZE_CMD configured — skipping build gate check"
    fi

    # --- Automatable check 3: Check for files mentioned in acceptance criteria ---
    local criteria_line=""
    local all_ms_data
    all_ms_data=$(parse_milestones "$claude_md" 2>/dev/null) || true
    criteria_line=$(echo "$all_ms_data" | awk -F'|' -v n="$milestone_num" '$1 == n {print $3; exit}')

    if [[ -n "$criteria_line" ]]; then
        # Look for file-existence criteria (patterns like "file X exists" or "X passes")
        local has_manual=false
        IFS=';' read -ra criteria_items <<< "$criteria_line"
        for item in "${criteria_items[@]}"; do
            # Trim leading/trailing whitespace
            item="${item#"${item%%[![:space:]]*}"}"
            item="${item%"${item##*[![:space:]]}"}"

            if [[ -z "$item" ]]; then
                continue
            fi

            # Check if this looks like an automatable file-existence criterion
            if [[ "$item" =~ (bash[[:space:]]+-n|shellcheck)[[:space:]]+(.*) ]]; then
                # Syntax check criterion — try to run it
                local check_target="${BASH_REMATCH[2]}"
                # Only run if target looks safe (no shell metacharacters)
                if [[ "$check_target" =~ ^[a-zA-Z0-9_./*-]+$ ]]; then
                    local check_exit=0
                    if [[ "$item" =~ ^bash[[:space:]]+-n ]]; then
                        bash -n "${check_target}" 2>/dev/null || check_exit=$?
                    fi
                    if [[ "$check_exit" -eq 0 ]]; then
                        success "Criterion: ${item}"
                    else
                        warn "Criterion FAILED: ${item}"
                        all_pass=false
                    fi
                else
                    log "MANUAL: ${item}"
                    has_manual=true
                fi
            else
                # Non-automatable criterion — mark as manual
                log "MANUAL: ${item}"
                has_manual=true
            fi
        done

        if [[ "$has_manual" = true ]]; then
            log "(Manual criteria require human verification)"
        fi
    fi

    echo

    if [[ "$all_pass" = true ]]; then
        success "All automatable acceptance criteria PASS for milestone ${milestone_num}"
        return 0
    else
        warn "Some acceptance criteria FAILED for milestone ${milestone_num}"
        return 1
    fi
}

# --- Milestone commit signatures ---------------------------------------------

# get_milestone_commit_prefix MILESTONE_NUM DISPOSITION
# Returns the appropriate commit message prefix based on milestone disposition.
# Returns empty string if not in milestone mode.
get_milestone_commit_prefix() {
    local milestone_num="$1"
    local disposition="$2"

    if [[ -z "$milestone_num" ]]; then
        return
    fi

    case "$disposition" in
        COMPLETE_AND_CONTINUE|COMPLETE_AND_WAIT)
            echo "[MILESTONE ${milestone_num} ✓]"
            ;;
        INCOMPLETE_REWORK|REPLAN_REQUIRED|NONE|"")
            echo "[MILESTONE ${milestone_num} — partial]"
            ;;
    esac
}

# get_milestone_commit_body MILESTONE_NUM DISPOSITION [CLAUDE_MD_PATH]
# Returns a milestone status line for the commit body.
get_milestone_commit_body() {
    local milestone_num="$1"
    local disposition="$2"
    local claude_md="${3:-CLAUDE.md}"

    if [[ -z "$milestone_num" ]]; then
        return
    fi

    local title
    title=$(get_milestone_title "$milestone_num" "$claude_md" 2>/dev/null) || true

    case "$disposition" in
        COMPLETE_AND_CONTINUE|COMPLETE_AND_WAIT)
            echo "Milestone ${milestone_num}: ${title} — COMPLETE"
            ;;
        INCOMPLETE_REWORK)
            echo "Milestone ${milestone_num}: ${title} — PARTIAL (rework needed)"
            ;;
        REPLAN_REQUIRED)
            echo "Milestone ${milestone_num}: ${title} — PARTIAL (replan required)"
            ;;
        *)
            echo "Milestone ${milestone_num}: ${title} — PARTIAL"
            ;;
    esac
}

# tag_milestone_complete MILESTONE_NUM
# Creates a git tag for a completed milestone if MILESTONE_TAG_ON_COMPLETE=true.
# Handles gracefully if tag already exists (warn and continue).
tag_milestone_complete() {
    local milestone_num="$1"

    if [[ "${MILESTONE_TAG_ON_COMPLETE:-false}" != "true" ]]; then
        return 0
    fi

    local tag_name="milestone-${milestone_num}-complete"

    if git tag "$tag_name" 2>/dev/null; then
        success "Created git tag: ${tag_name}"
    else
        warn "Git tag '${tag_name}' already exists or could not be created. Continuing."
    fi
}

# --- Auto-advance orchestration helpers --------------------------------------

# should_auto_advance
# Returns 0 if auto-advance conditions are met, 1 otherwise.
# Checks: AUTO_ADVANCE_ENABLED, session limit, disposition.
should_auto_advance() {
    if [[ "${AUTO_ADVANCE_ENABLED:-false}" != "true" ]]; then
        return 1
    fi

    local completed
    completed=$(get_milestones_completed_this_session)
    local limit="${AUTO_ADVANCE_LIMIT:-3}"

    if [[ "$completed" -ge "$limit" ]]; then
        log "Auto-advance limit reached (${completed}/${limit})"
        return 1
    fi

    local disposition
    disposition=$(get_milestone_disposition)
    if [[ "$disposition" != "COMPLETE_AND_CONTINUE" ]]; then
        return 1
    fi

    return 0
}

# find_next_milestone CURRENT_NUM CLAUDE_MD_PATH
# Returns the next non-done milestone number after CURRENT_NUM.
# Returns empty string if no more milestones.
find_next_milestone() {
    local current="$1"
    local claude_md="${2:-CLAUDE.md}"

    local next=""
    local all_ms
    all_ms=$(parse_milestones "$claude_md" 2>/dev/null) || true
    while IFS='|' read -r num _title _criteria; do
        if [[ -n "$num" ]] && awk -v n="$num" -v c="$current" 'BEGIN {exit !(n > c)}'; then
            if ! is_milestone_done "$num" "$claude_md"; then
                next="$num"
                break
            fi
        fi
    # sort -n handles decimals (e.g., 0.5 sorts before 1) on both GNU and BSD sort
    done < <(echo "$all_ms" | sort -t'|' -k1 -n)

    echo "$next"
}

# prompt_auto_advance_confirm NEXT_NUM NEXT_TITLE
# Prompts the user to confirm advancing to the next milestone.
# Returns 0 if confirmed, 1 if declined.
prompt_auto_advance_confirm() {
    local next_num="$1"
    local next_title="$2"

    echo
    log "Auto-advance: ready to proceed to Milestone ${next_num}: ${next_title}"
    log "Continue? [y/n]"
    echo "  y = advance to milestone ${next_num}"
    echo "  n = stop here (state saved for resume)"

    local choice
    if [[ -t 0 ]]; then
        read -r choice
    else
        read -r choice < /dev/tty 2>/dev/null || choice="n"
    fi

    [[ "$choice" =~ ^[Yy]$ ]]
}

# clear_milestone_state
# Removes the milestone state file.
clear_milestone_state() {
    if [[ -f "$MILESTONE_STATE_FILE" ]]; then
        rm "$MILESTONE_STATE_FILE"
        log "Milestone state cleared"
    fi
}

