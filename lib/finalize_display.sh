#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# finalize_display.sh — Action items summary display
#
# Sourced by finalize.sh — do not run directly.
# Expects: Color codes (RED, YELLOW, NC, CYAN, BOLD) from common.sh
# Expects: Helper functions: has_human_actions, count_human_actions,
#          count_open_nonblocking_notes, count_drift_observations, success
# Expects: FINAL_CHECK_RESULT, HUMAN_ACTION_FILE, NON_BLOCKING_LOG_FILE,
#          DRIFT_LOG_FILE variables set by caller
# Expects: ACTION_ITEMS_WARN_THRESHOLD, ACTION_ITEMS_CRITICAL_THRESHOLD,
#          HUMAN_NOTES_WARN_THRESHOLD, HUMAN_NOTES_CRITICAL_THRESHOLD from config
#
# Provides:
#   _print_action_items — display summary of outstanding action items
# =============================================================================

# _severity_for_count count warn_threshold critical_threshold
# Returns "normal", "warning", or "critical" based on count vs thresholds.
_severity_for_count() {
    local count="$1"
    local warn="${2:-5}"
    local crit="${3:-10}"
    if [[ "$count" -ge "$crit" ]]; then
        echo "critical"
    elif [[ "$count" -ge "$warn" ]]; then
        echo "warning"
    else
        echo "normal"
    fi
}

# _print_action_items
# Displays a summary of outstanding action items: tester bugs, test failures,
# human action items, non-blocking notes, and drift observations.
# Uses progressive color: cyan (normal), yellow (warning), red (critical).
_print_action_items() {
    # Parallel arrays: item_msgs[i] + item_sevs[i] (normal|warning|critical).
    local item_msgs=() item_sevs=()

    # Check for tester bugs
    if [[ -f "${TESTER_REPORT_FILE:-.tekhton/TESTER_REPORT.md}" ]] && \
       awk '/^## Bugs Found/{f=1;next} /^## /{f=0} f && /^-?[[:space:]]*[Nn]one/{exit 1} f && /^- /{found=1} END{exit !found}' "${TESTER_REPORT_FILE:-.tekhton/TESTER_REPORT.md}" 2>/dev/null; then
        local bug_count
        bug_count=$(awk '/^## Bugs Found/{f=1;next} /^## /{f=0} f && /^-?[[:space:]]*[Nn]one/{print 0; exit} f && /^- /{c++} END{print c+0}' "${TESTER_REPORT_FILE:-.tekhton/TESTER_REPORT.md}")
        item_msgs+=("${TESTER_REPORT_FILE:-.tekhton/TESTER_REPORT.md} — ${bug_count} bug(s) found (see ## Bugs Found)")
        item_sevs+=("warning")
    fi

    # Check for test failures from final checks
    if [[ "${FINAL_CHECK_RESULT:-0}" -ne 0 ]]; then
        item_msgs+=("Test suite — final checks failed (see output above)")
        item_sevs+=("warning")
    fi

    # Check for human action items
    if has_human_actions 2>/dev/null; then
        local ha_count
        ha_count=$(count_human_actions)
        item_msgs+=("${HUMAN_ACTION_FILE:-.tekhton/HUMAN_ACTION_REQUIRED.md} — ${ha_count} item(s) needing manual work")
        item_sevs+=("warning")
    fi

    # Check for non-blocking notes with progressive severity
    if [[ -f "${NON_BLOCKING_LOG_FILE:-}" ]] && [[ -s "${NON_BLOCKING_LOG_FILE:-}" ]]; then
        local nb_count
        nb_count=$(count_open_nonblocking_notes 2>/dev/null || echo 0)
        if [[ "$nb_count" -gt 0 ]]; then
            local nb_severity
            nb_severity=$(_severity_for_count "$nb_count" \
                "${ACTION_ITEMS_WARN_THRESHOLD:-5}" \
                "${ACTION_ITEMS_CRITICAL_THRESHOLD:-10}")
            case "$nb_severity" in
                critical)
                    item_msgs+=("${NON_BLOCKING_LOG_FILE:-.tekhton/NON_BLOCKING_LOG.md} — ${nb_count} accumulated observation(s)")
                    item_sevs+=("critical")
                    item_msgs+=("  → Suggested: tekhton --fix-nonblockers --complete")
                    item_sevs+=("critical")
                    ;;
                warning)
                    item_msgs+=("${NON_BLOCKING_LOG_FILE:-.tekhton/NON_BLOCKING_LOG.md} — ${nb_count} accumulated observation(s)")
                    item_sevs+=("warning")
                    ;;
                *)
                    item_msgs+=("${NON_BLOCKING_LOG_FILE:-.tekhton/NON_BLOCKING_LOG.md} — ${nb_count} accumulated observation(s)")
                    item_sevs+=("normal")
                    ;;
            esac
        fi
    fi

    # Check for drift observations (info only)
    if [[ -f "${DRIFT_LOG_FILE:-}" ]] && [[ -s "${DRIFT_LOG_FILE:-}" ]]; then
        local drift_count
        drift_count=$(count_drift_observations 2>/dev/null || echo 0)
        if [[ "$drift_count" -gt 0 ]]; then
            item_msgs+=("${DRIFT_LOG_FILE:-.tekhton/DRIFT_LOG.md} — ${drift_count} unresolved drift observation(s)")
            item_sevs+=("normal")
        fi
    fi

    # Check for unchecked human notes (M25) with progressive severity
    if command -v get_notes_summary &>/dev/null && [[ -f "${HUMAN_NOTES_FILE:-.tekhton/HUMAN_NOTES.md}" ]]; then
        local notes_summary
        notes_summary=$(get_notes_summary 2>/dev/null || echo "0|0|0|0|0|0")
        local notes_unchecked
        # Field contract: get_notes_summary returns 6 pipe-separated fields:
        # total|bug|feat|polish|checked|unchecked
        IFS='|' read -r _ _ _ _ _ notes_unchecked <<< "$notes_summary"
        if [[ "$notes_unchecked" -gt 0 ]]; then
            local notes_severity
            notes_severity=$(_severity_for_count "$notes_unchecked" \
                "${HUMAN_NOTES_WARN_THRESHOLD:-10}" \
                "${HUMAN_NOTES_CRITICAL_THRESHOLD:-20}")
            case "$notes_severity" in
                critical)
                    item_msgs+=("${HUMAN_NOTES_FILE:-.tekhton/HUMAN_NOTES.md} — ${notes_unchecked} item(s) remaining")
                    item_sevs+=("critical")
                    item_msgs+=("  → Suggested: tekhton --human --complete")
                    item_sevs+=("critical")
                    ;;
                warning)
                    item_msgs+=("${HUMAN_NOTES_FILE:-.tekhton/HUMAN_NOTES.md} — ${notes_unchecked} item(s) remaining")
                    item_sevs+=("warning")
                    ;;
                *)
                    item_msgs+=("${HUMAN_NOTES_FILE:-.tekhton/HUMAN_NOTES.md} — ${notes_unchecked} item(s) remaining")
                    item_sevs+=("normal")
                    ;;
            esac
            # Shared tip for warning + normal severity (critical has its own)
            if [[ "$notes_severity" != "critical" ]]; then
                item_msgs+=("  Tip: Run \`tekhton --human\` to process notes, or")
                item_sevs+=("normal")
                item_msgs+=("       \`tekhton note --list\` to see them")
                item_sevs+=("normal")
            fi
        fi
    fi

    # UI validation results (M29)
    if command -v get_ui_validation_summary &>/dev/null; then
        local ui_summary
        ui_summary=$(get_ui_validation_summary 2>/dev/null || echo "")
        if [[ -n "$ui_summary" ]] && [[ "$ui_summary" != "not run" ]]; then
            if [[ "${UI_VALIDATION_FAIL_COUNT:-0}" -gt 0 ]]; then
                item_msgs+=("UI Validation: ${ui_summary}")
                item_sevs+=("warning")
            else
                item_msgs+=("UI Validation: ${ui_summary}")
                item_sevs+=("normal")
            fi
            local screenshot_dir="${PROJECT_DIR:-.}/.claude/ui-validation/screenshots"
            if [[ "${UI_VALIDATION_SCREENSHOTS:-true}" = "true" ]] && [[ -d "$screenshot_dir" ]]; then
                item_msgs+=("  Screenshots: ${screenshot_dir}/")
                item_sevs+=("normal")
            fi
        fi
    fi

    # Quota pause summary (M16)
    if command -v format_quota_pause_summary &>/dev/null; then
        local quota_summary
        quota_summary=$(format_quota_pause_summary)
        if [[ -n "$quota_summary" ]]; then
            item_msgs+=("$quota_summary")
            item_sevs+=("normal")
        fi
    fi

    if [[ ${#item_msgs[@]} -gt 0 ]]; then
        out_banner "Action Items"
        local i
        for (( i = 0; i < ${#item_msgs[@]}; i++ )); do
            out_action_item "${item_msgs[$i]}" "${item_sevs[$i]}"
        done
        out_msg ""
    else
        success "No action items — clean run."
        out_msg ""
    fi

    # Diagnose hint for failed runs (M17)
    if [[ "${_PIPELINE_EXIT_CODE:-0}" -ne 0 ]] || [[ "${FINAL_CHECK_RESULT:-0}" -ne 0 ]]; then
        local cyan nc
        cyan=$(_out_color "${CYAN:-}")
        nc=$(_out_color "${NC:-}")
        out_msg "  ${cyan}Run 'tekhton --diagnose' for recovery suggestions.${nc}"
        out_msg ""
    fi
}

# _print_next_action
# Prints the M82 "What's next" guidance line. M96 IA3: extracted from
# _print_action_items so it can be emitted as the final line, after the
# commit confirmation rather than buried before the commit prompt.
_print_next_action() {
    command -v _compute_next_action &>/dev/null || return 0
    local next_action
    next_action=$(_compute_next_action 2>/dev/null || echo "")
    if [[ -n "$next_action" ]]; then
        local bold nc
        bold=$(_out_color "${BOLD:-}")
        nc=$(_out_color "${NC:-}")
        out_msg ""
        out_msg "${bold}${next_action}${nc}"
        out_msg ""
    fi
}
