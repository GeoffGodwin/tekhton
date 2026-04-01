#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# milestone_acceptance.sh — Milestone acceptance criteria checking
#
# Sourced by tekhton.sh via milestone_ops.sh — do not run directly.
# Expects: milestones.sh to be sourced first (parse_milestones, get_milestone_title)
# Expects: TEST_CMD, ANALYZE_CMD from config
# Expects: log(), warn(), success(), header() from common.sh
# Expects: run_build_gate() from gates.sh
#
# Provides:
#   check_milestone_acceptance — run automatable acceptance criteria
# =============================================================================

# check_milestone_acceptance MILESTONE_NUM [CLAUDE_MD_PATH]
# Runs automatable acceptance criteria for a milestone.
# Returns 0 if all automatable criteria pass, 1 if any fail.
# Prints a report of checked criteria.
check_milestone_acceptance() {
    local milestone_num="$1"
    local claude_md="${2:-${PROJECT_RULES_FILE:-CLAUDE.md}}"

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
            # Save output for Tier 2 stuck detection
            if command -v save_acceptance_test_output &>/dev/null; then
                save_acceptance_test_output "$test_output" "$test_exit"
            fi

            # Tier 1: compare against baseline
            local _baseline_assessment="none"
            if [[ "${TEST_BASELINE_ENABLED:-true}" = "true" ]] \
               && declare -f compare_test_with_baseline &>/dev/null \
               && declare -f has_test_baseline &>/dev/null \
               && has_test_baseline; then
                _baseline_assessment=$(compare_test_with_baseline "$test_output" "$test_exit")
            fi

            case "$_baseline_assessment" in
                pre_existing)
                    if [[ "${TEST_BASELINE_PASS_ON_PREEXISTING:-true}" = "true" ]]; then
                        warn "Tests FAILED (exit ${test_exit}) — ALL failures match pre-existing baseline"
                        warn "Treating as PASS for acceptance (pre-existing failures)"
                        if command -v emit_event &>/dev/null; then
                            emit_event "acceptance_preexisting_pass" "acceptance" \
                                "test_exit=${test_exit}, assessment=pre_existing" \
                                "" "" "" 2>/dev/null || true
                        fi
                    else
                        warn "Tests FAILED (exit ${test_exit}) — pre-existing, but PASS_ON_PREEXISTING=false"
                        echo "$test_output" | tail -20
                        all_pass=false
                    fi
                    ;;
                new_failures)
                    warn "Tests FAILED (exit ${test_exit}) — NEW failures detected since baseline"
                    echo "$test_output" | tail -20
                    all_pass=false
                    ;;
                *)
                    # inconclusive or no baseline — standard failure behavior
                    warn "Tests FAILED (exit ${test_exit})"
                    echo "$test_output" | tail -20
                    all_pass=false
                    ;;
            esac
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
