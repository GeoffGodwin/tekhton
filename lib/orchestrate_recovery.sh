#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# orchestrate_recovery.sh — Recovery decision tree for --complete mode (M16)
#
# Sourced by orchestrate.sh — do not run directly.
# Expects: AGENT_ERROR_CATEGORY, AGENT_ERROR_SUBCATEGORY, VERDICT (from agent.sh)
#
# Provides:
#   _classify_failure   — diagnose pipeline failure and return recovery action
#   _check_progress     — detect stuck loops via git diff comparison
#   _compute_diff_hash  — content hash of working tree changes
# =============================================================================

# --- Progress detection --------------------------------------------------------

# _compute_diff_hash
# Returns a content hash of the current working tree changes.
# Used to detect whether the pipeline made meaningful progress between iterations.
_compute_diff_hash() {
    git diff HEAD 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1 || echo "no-git"
}

# _check_progress
# Multi-signal progress detection (M16). Uses causal log events as primary
# signal when available, falls back to git diff hash comparison.
# Returns 0 if progress detected, 1 if stuck.
_check_progress() {
    if [[ "${AUTONOMOUS_PROGRESS_CHECK:-true}" != "true" ]]; then
        return 0
    fi

    # Primary: causal log signals (richer than git diff alone)
    if _check_progress_causal_log; then
        _ORCH_NO_PROGRESS_COUNT=0
        return 0
    fi

    # Fallback: git diff hash comparison
    local current_hash
    current_hash=$(_compute_diff_hash)

    if [[ "$current_hash" = "$_ORCH_LAST_DIFF_HASH" ]]; then
        _ORCH_NO_PROGRESS_COUNT=$(( _ORCH_NO_PROGRESS_COUNT + 1 ))
        if [[ "$_ORCH_NO_PROGRESS_COUNT" -ge 2 ]]; then
            return 1  # stuck
        fi
        warn "No progress detected (${_ORCH_NO_PROGRESS_COUNT}/2 — will retry once more)"
        return 0
    fi

    _ORCH_NO_PROGRESS_COUNT=0
    _ORCH_LAST_DIFF_HASH="$current_hash"
    return 0
}

# _check_progress_causal_log
# Returns 0 if causal log shows forward-progress events for the current attempt.
# Returns 1 if no causal log or no progress events found.
_check_progress_causal_log() {
    # Requires causal log to be enabled and file to exist
    if [[ "${CAUSAL_LOG_ENABLED:-true}" != "true" ]]; then
        return 1
    fi
    if [[ ! -f "${CAUSAL_LOG_FILE:-}" ]]; then
        return 1
    fi

    # Only examine events emitted during THIS attempt (lines after baseline).
    # _ORCH_CAUSAL_LOG_BASELINE is captured at the start of each iteration.
    local baseline="${_ORCH_CAUSAL_LOG_BASELINE:-0}"
    local attempt_lines
    attempt_lines=$(tail -n "+$(( baseline + 1 ))" "$CAUSAL_LOG_FILE" 2>/dev/null) || attempt_lines=""

    if [[ -z "$attempt_lines" ]]; then
        return 1  # No new events this attempt
    fi

    # Check for forward-progress event types emitted since this attempt started.
    # These indicate work was done even if git diff didn't change.
    local progress_patterns='verdict.*APPROVED\|verdict.*TWEAKED\|verdict.*PASS\|milestone_advance\|stage_end.*success\|rework_cycle'
    if echo "$attempt_lines" | grep -q "$progress_patterns" 2>/dev/null; then
        return 0
    fi

    # Check for non-error events in this attempt's portion
    local recent_events
    recent_events=$(echo "$attempt_lines" | grep -cv '"type":"error"' 2>/dev/null | tr -d '[:space:]' || echo "0")
    [[ "$recent_events" =~ ^[0-9]+$ ]] || recent_events=0
    if [[ "$recent_events" -gt 5 ]]; then
        return 0  # Active work happening
    fi

    return 1
}

# --- Recovery decision tree ----------------------------------------------------
#
# After _run_pipeline_stages returns non-zero, classify the failure and return
# a recovery action string. The caller (run_complete_loop) acts on the action.
#
# Decision tree:
#   UPSTREAM errors         → save_exit (sustained outage after M13 retries)
#   AGENT_SCOPE/max_turns   → split (M11 handles; if depth exhausted → save_exit)
#   AGENT_SCOPE/null_run    → split (M11 handles; if depth exhausted → save_exit)
#   AGENT_SCOPE/timeout     → save_exit
#   ENVIRONMENT errors      → save_exit (not recoverable by retry)
#   PIPELINE errors         → save_exit (internal bug)
#   CHANGES_REQUIRED/max    → bump_review (one-time +2 cycles)
#   REPLAN_REQUIRED         → save_exit (never retry wrong scope)
#   Build gate failure      → retry_coder_build (one retry with BUILD_ERRORS_CONTENT)
#   Unclassified            → save_exit (never retry unknown errors)

_classify_failure() {
    local error_cat="${AGENT_ERROR_CATEGORY:-}"
    local error_sub="${AGENT_ERROR_SUBCATEGORY:-}"

    # Transient upstream errors — already retried by M13. If still failing,
    # it's a sustained outage. Save state and exit.
    if [[ "$error_cat" = "UPSTREAM" ]]; then
        echo "save_exit"
        return
    fi

    # Turn exhaustion — already continued by M14. If still exhausting after
    # MAX_CONTINUATION_ATTEMPTS, trigger split.
    if [[ "$error_cat" = "AGENT_SCOPE" ]] && [[ "$error_sub" = "max_turns" ]]; then
        echo "split"
        return
    fi

    # Null run — already split by M11. If split depth exhausted, save exit.
    if [[ "$error_cat" = "AGENT_SCOPE" ]] && [[ "$error_sub" = "null_run" ]]; then
        echo "split"
        return
    fi

    # Activity timeout
    if [[ "$error_cat" = "AGENT_SCOPE" ]] && [[ "$error_sub" = "activity_timeout" ]]; then
        echo "save_exit"
        return
    fi

    # Environment errors are not recoverable by retrying
    if [[ "$error_cat" = "ENVIRONMENT" ]]; then
        echo "save_exit"
        return
    fi

    # Pipeline internal errors
    if [[ "$error_cat" = "PIPELINE" ]]; then
        echo "save_exit"
        return
    fi

    # No error classification — check VERDICT for review cycle exhaustion
    local verdict="${VERDICT:-}"
    if [[ "$verdict" = "CHANGES_REQUIRED" ]] || [[ "$verdict" = "review_cycle_max" ]]; then
        echo "bump_review"
        return
    fi

    # REPLAN_REQUIRED — never retry
    if [[ "$verdict" = "REPLAN_REQUIRED" ]]; then
        echo "save_exit"
        return
    fi

    # Build gate failure — check if rework already happened
    if [[ -f "BUILD_ERRORS.md" ]] && [[ -s "BUILD_ERRORS.md" ]]; then
        echo "retry_coder_build"
        return
    fi

    # Unclassified — never retry unknown errors
    echo "save_exit"
}
