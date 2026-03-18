#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# milestone_ops.sh — Milestone acceptance checking, commit signatures,
#                     auto-advance orchestration
#
# Sourced by tekhton.sh — do not run directly.
# Expects: milestones.sh to be sourced first (parse_milestones, get_milestone_title,
#          is_milestone_done, get_current_milestone, get_milestone_disposition,
#          get_milestones_completed_this_session, MILESTONE_STATE_FILE)
# Expects: PROJECT_DIR, TEST_CMD, ANALYZE_CMD (from config)
# Expects: log(), warn(), success(), header() from common.sh
# Expects: run_build_gate() from gates.sh
#
# Provides:
#   check_milestone_acceptance — run automatable acceptance criteria
#   get_milestone_commit_prefix — commit message prefix for milestone runs
#   get_milestone_commit_body   — commit body line for milestone status
#   tag_milestone_complete      — optional git tag on completion
#   should_auto_advance         — check auto-advance conditions
#   find_next_milestone         — locate next non-done milestone
#   prompt_auto_advance_confirm — interactive confirmation for auto-advance
#   clear_milestone_state       — remove milestone state file
# =============================================================================

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
