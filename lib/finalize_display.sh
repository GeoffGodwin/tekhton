#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# finalize_display.sh — Action items summary display
#
# Sourced by finalize.sh — do not run directly.
# Expects: Color codes (YELLOW, NC, CYAN, BOLD) from common.sh
# Expects: Helper functions: has_human_actions, count_human_actions,
#          count_open_nonblocking_notes, count_drift_observations, success
# Expects: FINAL_CHECK_RESULT, HUMAN_ACTION_FILE, NON_BLOCKING_LOG_FILE,
#          DRIFT_LOG_FILE variables set by caller
#
# Provides:
#   _print_action_items — display summary of outstanding action items
# =============================================================================

# _print_action_items
# Displays a summary of outstanding action items: tester bugs, test failures,
# human action items, non-blocking notes, and drift observations.
_print_action_items() {
    local action_items=()

    # Check for tester bugs
    if [[ -f "TESTER_REPORT.md" ]] && \
       awk '/^## Bugs Found/{f=1;next} /^## /{f=0} f && /^[Nn]one/{exit 1} f && /^- /{found=1} END{exit !found}' TESTER_REPORT.md 2>/dev/null; then
        local bug_count
        bug_count=$(awk '/^## Bugs Found/{f=1;next} /^## /{f=0} f && /^[Nn]one/{print 0; exit} f && /^- /{c++} END{print c+0}' TESTER_REPORT.md)
        action_items+=("$(echo -e "${YELLOW}  ⚠ TESTER_REPORT.md — ${bug_count} bug(s) found (see ## Bugs Found)${NC}")")
    fi

    # Check for test failures from final checks
    if [[ "${FINAL_CHECK_RESULT:-0}" -ne 0 ]]; then
        action_items+=("$(echo -e "${YELLOW}  ⚠ Test suite — final checks failed (see output above)${NC}")")
    fi

    # Check for human action items
    if has_human_actions 2>/dev/null; then
        local ha_count
        ha_count=$(count_human_actions)
        action_items+=("$(echo -e "${YELLOW}  ⚠ ${HUMAN_ACTION_FILE} — ${ha_count} item(s) needing manual work${NC}")")
    fi

    # Check for non-blocking notes (info only)
    if [[ -f "${NON_BLOCKING_LOG_FILE:-}" ]] && [[ -s "${NON_BLOCKING_LOG_FILE:-}" ]]; then
        local nb_count
        nb_count=$(count_open_nonblocking_notes 2>/dev/null || echo 0)
        if [[ "$nb_count" -gt 0 ]]; then
            action_items+=("$(echo -e "${CYAN}  ℹ ${NON_BLOCKING_LOG_FILE} — ${nb_count} accumulated observation(s)${NC}")")
        fi
    fi

    # Check for drift observations (info only)
    if [[ -f "${DRIFT_LOG_FILE:-}" ]] && [[ -s "${DRIFT_LOG_FILE:-}" ]]; then
        local drift_count
        drift_count=$(count_drift_observations 2>/dev/null || echo 0)
        if [[ "$drift_count" -gt 0 ]]; then
            action_items+=("$(echo -e "${CYAN}  ℹ ${DRIFT_LOG_FILE} — ${drift_count} unresolved drift observation(s)${NC}")")
        fi
    fi

    # Check for unchecked human notes (M25)
    if command -v get_notes_summary &>/dev/null && [[ -f "HUMAN_NOTES.md" ]]; then
        local notes_summary
        notes_summary=$(get_notes_summary 2>/dev/null || echo "0|0|0|0|0|0")
        local notes_unchecked
        IFS='|' read -r _ _ _ _ _ notes_unchecked <<< "$notes_summary"
        if [[ "$notes_unchecked" -gt 0 ]]; then
            action_items+=("$(echo -e "${YELLOW}  ⚠ HUMAN_NOTES.md — ${notes_unchecked} item(s) remaining${NC}")")
            action_items+=("$(echo -e "${CYAN}    Tip: Run \`tekhton --human\` to process notes, or${NC}")")
            action_items+=("$(echo -e "${CYAN}         \`tekhton note --list\` to see them${NC}")")
        fi
    fi

    # Quota pause summary (M16)
    if command -v format_quota_pause_summary &>/dev/null; then
        local quota_summary
        quota_summary=$(format_quota_pause_summary)
        if [[ -n "$quota_summary" ]]; then
            action_items+=("$(echo -e "${CYAN}  \u2139 ${quota_summary}${NC}")")
        fi
    fi

    if [[ ${#action_items[@]} -gt 0 ]]; then
        echo -e "${BOLD}══════════════════════════════════════${NC}"
        echo -e "${BOLD}  Action Items${NC}"
        echo -e "${BOLD}══════════════════════════════════════${NC}"
        for item in "${action_items[@]}"; do
            echo -e "$item"
        done
        echo -e "${BOLD}══════════════════════════════════════${NC}"
        echo
    else
        success "No action items — clean run."
        echo
    fi

    # Diagnose hint for failed runs (M17)
    if [[ "${_PIPELINE_EXIT_CODE:-0}" -ne 0 ]] || [[ "${FINAL_CHECK_RESULT:-0}" -ne 0 ]]; then
        echo -e "${CYAN}  Run 'tekhton --diagnose' for recovery suggestions.${NC}"
        echo
    fi
}
