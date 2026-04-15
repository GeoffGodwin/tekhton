#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# milestone_progress.sh — Milestone progress rendering and next-action guidance
#
# Sourced by tekhton.sh — do not run directly.
# Expects: common.sh, milestone_dag.sh, milestone_dag_helpers.sh,
#          milestone_progress_helpers.sh sourced first.
# Expects: MILESTONE_DAG_ENABLED, MILESTONE_DIR, MILESTONE_MANIFEST from config.
#
# Provides:
#   _render_milestone_progress  — progress bar + milestone list for --progress
#   _compute_next_action        — single guidance line for post-run output
#   _diagnose_recovery_command  — concrete CLI recovery command from state
# =============================================================================

# _render_milestone_progress [--all] [--deps]
# Reads MANIFEST.cfg and renders a progress view to stdout.
# Globals read: MILESTONE_DAG_ENABLED, MILESTONE_DIR, MILESTONE_MANIFEST
# Falls back to parse_milestones_auto() when DAG is disabled.
_render_milestone_progress() {
    local show_all=false
    local show_deps=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)  show_all=true; shift ;;
            --deps) show_deps=true; shift ;;
            *)      shift ;;
        esac
    done

    # Select UTF-8 or ASCII symbols
    local sym_done="+" sym_ready=">" sym_pending=" "
    if _is_utf8_terminal; then
        sym_done="\xe2\x9c\x93"   # ✓
        sym_ready="\xe2\x96\xb6"  # ▶
    fi

    # DAG-enabled path
    if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
       && declare -f has_milestone_manifest &>/dev/null \
       && has_milestone_manifest; then
        _render_progress_dag "$show_all" "$show_deps" "$sym_done" "$sym_ready" "$sym_pending"
        return
    fi

    # Fallback: inline milestones
    _render_progress_inline "$show_all" "$sym_done" "$sym_ready" "$sym_pending"
}

# _compute_next_action
# Pure function that prints a single "What's next: ..." guidance line.
# Globals read: _PIPELINE_EXIT_CODE, MILESTONE_MODE, _CACHED_DISPOSITION,
#   AGENT_ERROR_CATEGORY, AGENT_ERROR_SUBCATEGORY, VERDICT
_compute_next_action() {
    local exit_code="${_PIPELINE_EXIT_CODE:-0}"
    local is_milestone="${MILESTONE_MODE:-false}"
    local disposition="${_CACHED_DISPOSITION:-}"

    # Success path
    if [[ "$exit_code" -eq 0 ]]; then
        local is_complete=false
        if [[ "$disposition" == "COMPLETE_AND_CONTINUE" ]] \
           || [[ "$disposition" == "COMPLETE_AND_WAIT" ]]; then
            is_complete=true
        fi

        if [[ "$is_milestone" == "true" ]] && [[ "$is_complete" == "true" ]]; then
            # Find next milestone
            local current_id=""
            if [[ -n "${_CURRENT_MILESTONE:-}" ]]; then
                current_id=$(dag_number_to_id "$_CURRENT_MILESTONE" 2>/dev/null) || current_id=""
            fi
            local next_id
            next_id=$(dag_find_next "$current_id" 2>/dev/null) || next_id=""
            if [[ -n "$next_id" ]]; then
                local next_num
                next_num=$(dag_id_to_number "$next_id")
                local next_title
                next_title=$(dag_get_title "$next_id" 2>/dev/null || echo "")
                echo "What's next: tekhton --milestone \"M${next_num}: ${next_title}\""
            else
                echo "All milestones complete. Run tekhton --draft-milestones for next steps."
            fi
            return 0
        fi

        if [[ "$is_milestone" != "true" ]]; then
            echo "Run tekhton --status to review pipeline state."
            return 0
        fi

        # Milestone mode, not complete — partial progress
        echo "Run tekhton --status to review pipeline state."
        return 0
    fi

    # Failure path — classify the error
    local error_cat="${AGENT_ERROR_CATEGORY:-}"
    local error_sub="${AGENT_ERROR_SUBCATEGORY:-}"
    local verdict="${VERDICT:-}"

    # Build gate failure
    if [[ -f "${BUILD_ERRORS_FILE:-}" ]] && [[ -s "${BUILD_ERRORS_FILE:-}" ]]; then
        echo "What's next: fix build errors, then tekhton --start-at coder \"task\""
        return 0
    fi

    # Review exhaustion
    if [[ "$verdict" == "CHANGES_REQUIRED" ]] || [[ "$verdict" == "review_cycle_max" ]]; then
        echo "What's next: tekhton --diagnose for recovery plan"
        return 0
    fi

    # API / transient errors
    if [[ "$error_cat" == "UPSTREAM" ]]; then
        echo "What's next: re-run when API is available (transient error)"
        return 0
    fi

    # Stuck / timeout
    if [[ "$error_sub" == "activity_timeout" ]] || [[ "$error_sub" == "null_run" ]]; then
        echo "What's next: tekhton --diagnose for root cause analysis"
        return 0
    fi

    # Generic failure
    echo "What's next: tekhton --diagnose for details"
}

# _diagnose_recovery_command
# Maps failure state to a concrete CLI invocation string.
# Globals read: PIPELINE_STATE_FILE, CURRENT_STAGE, MILESTONE_MODE,
#   _CURRENT_MILESTONE
# Prints a tekhton command to stdout, or empty string if none derivable.
_diagnose_recovery_command() {
    local state_file="${PIPELINE_STATE_FILE:-${PROJECT_DIR:-.}/.claude/PIPELINE_STATE.md}"
    [[ -f "$state_file" ]] || return 0

    local stage
    stage=$(awk '/^## Exit Stage$/{getline; print; exit}' "$state_file" 2>/dev/null || true)
    local task
    task=$(awk '/^## Task$/{getline; print; exit}' "$state_file" 2>/dev/null || true)

    [[ -z "$stage" ]] && return 0

    # Map stage names to --start-at values
    local start_at="$stage"
    case "$stage" in
        intake|coder|security|review|tester) start_at="$stage" ;;
        reviewer) start_at="review" ;;
        *) start_at="coder" ;;
    esac

    local cmd="tekhton --start-at ${start_at}"

    # Add milestone context if available
    local milestone=""
    milestone=$(awk '/^## Milestone$/{getline; print; exit}' "$state_file" 2>/dev/null || true)
    if [[ -n "$milestone" ]] && [[ "$milestone" != "none" ]]; then
        milestone="${milestone//\"/\\\"}"
        cmd="${cmd} --milestone \"${milestone}\""
    fi

    if [[ -n "$task" ]]; then
        task="${task//\"/\\\"}"
        cmd="${cmd} \"${task}\""
    fi

    echo "$cmd"
}
