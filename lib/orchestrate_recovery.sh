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
#                         (M130: causal-context-aware, may return retry_ui_gate_env)
#   _check_progress     — detect stuck loops via git diff comparison
#   _compute_diff_hash  — content hash of working tree changes
#   _print_recovery_block — terminal recovery block (M94, M130 cause_summary)
#
# (M130 causal-context state + loader live in orchestrate_recovery_causal.sh.)
# =============================================================================

# shellcheck source=lib/orchestrate_recovery_causal.sh
source "$(dirname "${BASH_SOURCE[0]}")/orchestrate_recovery_causal.sh"

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
    _load_failure_cause_context  # M130: refresh _ORCH_PRIMARY_*/SECONDARY_* vars

    local error_cat="${AGENT_ERROR_CATEGORY:-}"
    local error_sub="${AGENT_ERROR_SUBCATEGORY:-}"

    # NOTE: _classify_failure is invoked via `recovery=$(_classify_failure)` from
    # the dispatcher (subshell). Any state mutations made here are LOST when the
    # function returns. Persistent guards (_ORCH_ENV_GATE_RETRIED,
    # _ORCH_MIXED_BUILD_RETRIED, _ORCH_RECOVERY_ROUTE_TAKEN) are written by the
    # dispatcher case branches in orchestrate_loop.sh:_handle_pipeline_failure.
    # This function only READS them.

    # Transient upstream errors — already retried by M13. If still failing,
    # it's a sustained outage. Save state and exit.
    if [[ "$error_cat" = "UPSTREAM" ]]; then
        echo "save_exit"
        return
    fi

    # M130 Amendment B: max_turns with primary cause ENVIRONMENT/test_infra
    # is a *symptom* — splitting hands more turns to the same broken gate.
    # Re-run the gate with the hardened env profile (M126) instead.
    if [[ "$error_cat"         = "AGENT_SCOPE"  ]] \
       && [[ "$error_sub"         = "max_turns"    ]] \
       && [[ "$_ORCH_PRIMARY_CAT" = "ENVIRONMENT"  ]] \
       && [[ "$_ORCH_PRIMARY_SUB" = "test_infra"   ]] \
       && [[ "${_ORCH_ENV_GATE_RETRIED:-0}" -ne 1 ]] \
       && _causal_env_retry_allowed; then
        echo "retry_ui_gate_env"
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

    # Null activity timeout — exit 124 with zero turns. Re-launching into
    # the same upstream wall (quota/auth/CLI hang) wastes budget and burns
    # cache. Save state with a distinct reason so the recovery block names
    # the actual cause and the user can act on it before re-running.
    if [[ "$error_cat" = "AGENT_SCOPE" ]] && [[ "$error_sub" = "null_activity_timeout" ]]; then
        echo "save_exit"
        return
    fi

    # Activity timeout (turns > 0 — agent went silent mid-run)
    if [[ "$error_cat" = "AGENT_SCOPE" ]] && [[ "$error_sub" = "activity_timeout" ]]; then
        echo "save_exit"
        return
    fi

    # M130 Amendment A: env/test_infra primary cause is recoverable by
    # re-running with the deterministic gate profile (M126) — unless the
    # user has explicitly opted out via pipeline.conf.
    if [[ "$_ORCH_PRIMARY_CAT" = "ENVIRONMENT" ]] \
       && [[ "$_ORCH_PRIMARY_SUB" = "test_infra" ]] \
       && [[ "${_ORCH_ENV_GATE_RETRIED:-0}" -ne 1 ]] \
       && _causal_env_retry_allowed; then
        echo "retry_ui_gate_env"
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

    # M130 Amendment C: build-gate routing is gated by the M127 confidence
    # classification token. The kill-switch BUILD_FIX_CLASSIFICATION_REQUIRED=false
    # reverts to pre-M130 behavior (always retry on non-empty BUILD_ERRORS_FILE).
    if [[ -f "${BUILD_ERRORS_FILE:-/dev/null}" ]] && [[ -s "${BUILD_ERRORS_FILE:-/dev/null}" ]]; then
        if [[ "${BUILD_FIX_CLASSIFICATION_REQUIRED:-true}" != "true" ]]; then
            echo "retry_coder_build"
            return
        fi
        local build_confidence="${LAST_BUILD_CLASSIFICATION:-code_dominant}"
        case "$build_confidence" in
            code_dominant|unknown_only|"")
                echo "retry_coder_build"
                return
                ;;
            mixed_uncertain)
                if [[ "${_ORCH_MIXED_BUILD_RETRIED:-0}" -ne 1 ]]; then
                    echo "retry_coder_build"
                    return
                fi
                echo "save_exit"
                return
                ;;
            noncode_dominant)
                echo "save_exit"
                return
                ;;
        esac
    fi

    # Unclassified — never retry unknown errors
    echo "save_exit"
}

# _print_recovery_block lives in orchestrate_recovery_print.sh — sourced below.
# shellcheck source=lib/orchestrate_recovery_print.sh
source "$(dirname "${BASH_SOURCE[0]}")/orchestrate_recovery_print.sh"
