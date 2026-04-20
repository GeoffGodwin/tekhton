#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# orchestrate.sh — Outer orchestration loop for --complete mode
#
# Wraps _run_pipeline_stages() in a retry-with-recovery loop. Contract:
# run this milestone until it passes acceptance or all recovery options
# are exhausted.
#
# M16: MAX_PIPELINE_ATTEMPTS counts consecutive failures only. Milestone
# success or successful split resets the counter to 0. MAX_AUTONOMOUS_AGENT_CALLS
# is now a safety valve (200) rather than a workflow limit.
#
# Sourced by tekhton.sh — do not run directly.
# Expects: _run_pipeline_stages(), finalize_run(), check_milestone_acceptance(),
#          write_pipeline_state(), classify_error(), report_orchestration_status(),
#          record_pipeline_attempt(), emit_milestone_metadata() sourced.
# Expects: TASK, _CURRENT_MILESTONE, MILESTONE_MODE, LOG_DIR, LOG_FILE,
#          TIMESTAMP, START_AT, MAX_PIPELINE_ATTEMPTS, AUTONOMOUS_TIMEOUT,
#          MAX_AUTONOMOUS_AGENT_CALLS, AUTONOMOUS_PROGRESS_CHECK (from config)
#
# Provides:
#   run_complete_loop — the outer orchestration loop
# =============================================================================

# Source recovery helpers (progress detection + failure classification)
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/orchestrate_recovery.sh"

# Source auto-advance chain and state persistence helpers
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/orchestrate_helpers.sh"

# Source preflight fix helper (extracted from orchestrate_helpers.sh for 300-line ceiling)
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/orchestrate_preflight.sh"

# Source test baseline helpers (pre-existing failure detection)
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/test_baseline.sh"

# Source test baseline cleanup helpers (extracted for 300-line ceiling)
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/test_baseline_cleanup.sh"

# Source per-iteration outcome handlers (extracted for 300-line ceiling)
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/orchestrate_loop.sh"

# --- Orchestration state globals -----------------------------------------------
_ORCH_ATTEMPT=0
_ORCH_AGENT_CALLS=0
_ORCH_START_TIME=0
_ORCH_ELAPSED=0
_ORCH_ATTEMPT_LOG=""
_ORCH_REVIEW_BUMPED=false
_ORCH_BUILD_RETRIED=false
_ORCH_LAST_DIFF_HASH=""
_ORCH_NO_PROGRESS_COUNT=0
_ORCH_AGENT_100_WARNED=false
_ORCH_CAUSAL_LOG_BASELINE=0
_ORCH_LAST_ACCEPTANCE_HASH=""
_ORCH_IDENTICAL_ACCEPTANCE_COUNT=0
# M91: Adaptive rework turn escalation — consecutive max_turns counter + stage
_ORCH_CONSECUTIVE_MAX_TURNS=0
_ORCH_MAX_TURNS_STAGE=""

export _ORCH_ATTEMPT _ORCH_AGENT_CALLS _ORCH_ELAPSED _ORCH_ATTEMPT_LOG
export _ORCH_CONSECUTIVE_MAX_TURNS _ORCH_MAX_TURNS_STAGE


# --- Progress detection and recovery are in orchestrate_recovery.sh -----------

# --- The outer loop -----------------------------------------------------------

# run_complete_loop
# Entry point for --complete mode. Wraps pipeline execution in a retry loop.
# Handles milestone and non-milestone tasks.
run_complete_loop() {
    _ORCH_START_TIME=$(date +%s)
    _ORCH_ATTEMPT=0
    _ORCH_AGENT_CALLS=0
    _ORCH_LAST_DIFF_HASH=$(_compute_diff_hash)
    _ORCH_NO_PROGRESS_COUNT=0
    _ORCH_REVIEW_BUMPED=false
    _ORCH_ATTEMPT_LOG=""
    _ORCH_LAST_ACCEPTANCE_HASH=""
    _ORCH_IDENTICAL_ACCEPTANCE_COUNT=0
    # M91: Reset escalation counter + unset any inherited EFFECTIVE_* vars so the
    # first attempt always uses the configured base turn budget.
    _ORCH_CONSECUTIVE_MAX_TURNS=0
    _ORCH_MAX_TURNS_STAGE=""
    unset EFFECTIVE_CODER_MAX_TURNS EFFECTIVE_JR_CODER_MAX_TURNS EFFECTIVE_TESTER_MAX_TURNS
    _ORCH_BUILD_RETRIED=false

    # Restore orchestration state from prior run (resume support)
    if [[ -f "${PIPELINE_STATE_FILE:-}" ]]; then
        local _saved_exit_reason _saved_attempt _saved_calls
        _saved_exit_reason=$(awk '/^## Exit Reason/{getline; print; exit}' "$PIPELINE_STATE_FILE" 2>/dev/null || echo "")
        _saved_attempt=$(awk '/^Pipeline attempt:/{print $NF; exit}' "$PIPELINE_STATE_FILE" 2>/dev/null || echo "")
        _saved_calls=$(awk '/^Cumulative agent calls:/{print $NF; exit}' "$PIPELINE_STATE_FILE" 2>/dev/null || echo "")

        # If prior run hit a safety bound, reset counters for fresh budget
        case "$_saved_exit_reason" in
            complete_loop_max_attempts|complete_loop_timeout|complete_loop_agent_cap)
                log "Prior run hit safety bound (${_saved_exit_reason}). Resetting counters for fresh attempt budget."
                _ORCH_ATTEMPT=0
                _ORCH_AGENT_CALLS=0
                ;;
            *)
                if [[ -n "$_saved_attempt" ]] && [[ "$_saved_attempt" =~ ^[0-9]+$ ]]; then
                    _ORCH_ATTEMPT="$_saved_attempt"
                    log "Restored orchestration attempt counter: ${_ORCH_ATTEMPT}"
                fi
                if [[ -n "$_saved_calls" ]] && [[ "$_saved_calls" =~ ^[0-9]+$ ]]; then
                    _ORCH_AGENT_CALLS="$_saved_calls"
                    TOTAL_AGENT_INVOCATIONS="$_saved_calls"
                    log "Restored orchestration agent call counter: ${_ORCH_AGENT_CALLS}"
                fi
                ;;
        esac
    fi

    # Capture test baseline before any pipeline attempt (pre-existing failure detection)
    if _should_capture_test_baseline 2>/dev/null; then
        capture_test_baseline "${_CURRENT_MILESTONE:-}" || true
    fi

    # Reset test dedup fingerprint so stale state from a previous run doesn't
    # carry over into this loop.
    if declare -f test_dedup_reset &>/dev/null; then
        test_dedup_reset
    fi

    # Emit milestone metadata on start (if milestone mode)
    if [[ "$MILESTONE_MODE" = true ]] && [[ -n "${_CURRENT_MILESTONE:-}" ]]; then
        emit_milestone_metadata "$_CURRENT_MILESTONE" "in_progress" || true
        # Refresh dashboard milestones so the "in_progress" status is visible.
        # Guard: always true under tekhton.sh (dashboard_emitters.sh is sourced),
        # but kept for safety if this function is ever sourced standalone.
        if command -v emit_dashboard_milestones &>/dev/null; then
            emit_dashboard_milestones 2>/dev/null || true
        fi
    fi

    while true; do
        _ORCH_ATTEMPT=$(( _ORCH_ATTEMPT + 1 ))
        # M99: mirror attempt state into the Output Bus so the TUI header sees
        # the real pass counter instead of the old PIPELINE_ATTEMPT ghost.
        out_set_context attempt      "$_ORCH_ATTEMPT"
        out_set_context max_attempts "${MAX_PIPELINE_ATTEMPTS:-5}"
        _ORCH_ELAPSED=$(( $(date +%s) - _ORCH_START_TIME ))

        # Capture causal log baseline for this iteration (M16 fix: restrict
        # progress detection to events emitted during THIS attempt only)
        if [[ "${CAUSAL_LOG_ENABLED:-true}" = "true" ]] && [[ -f "${CAUSAL_LOG_FILE:-}" ]]; then
            _ORCH_CAUSAL_LOG_BASELINE=$(wc -l < "$CAUSAL_LOG_FILE" 2>/dev/null || echo 0)
        else
            _ORCH_CAUSAL_LOG_BASELINE=0
        fi

        # --- Safety bound: wall-clock timeout (checked at TOP of iteration) ---
        if [[ "$_ORCH_ELAPSED" -ge "${AUTONOMOUS_TIMEOUT:-7200}" ]]; then
            warn "Reached AUTONOMOUS_TIMEOUT (${AUTONOMOUS_TIMEOUT:-7200}s). Saving state."
            _save_orchestration_state "timeout" "Wall-clock timeout after ${_ORCH_ELAPSED}s"
            return 1
        fi

        # --- Safety bound: max consecutive failures (M16: resets on success) ---
        if [[ "$_ORCH_ATTEMPT" -gt "${MAX_PIPELINE_ATTEMPTS:-5}" ]]; then
            warn "Reached MAX_PIPELINE_ATTEMPTS (${MAX_PIPELINE_ATTEMPTS:-5} consecutive failures). Saving state."
            _save_orchestration_state "max_attempts" "Exhausted ${MAX_PIPELINE_ATTEMPTS:-5} consecutive failure attempts"
            return 1
        fi

        # --- Safety bound: agent call cap (M16: raised to 200, warn at 100) ---
        if [[ "$_ORCH_AGENT_CALLS" -ge "${MAX_AUTONOMOUS_AGENT_CALLS:-200}" ]]; then
            error "Reached MAX_AUTONOMOUS_AGENT_CALLS (${MAX_AUTONOMOUS_AGENT_CALLS:-200}). This is a safety valve — something may be wrong. Saving state."
            _save_orchestration_state "agent_cap" "Agent call cap (${MAX_AUTONOMOUS_AGENT_CALLS:-200}) reached"
            return 1
        fi
        if [[ "$_ORCH_AGENT_CALLS" -ge 100 ]] && [[ "${_ORCH_AGENT_100_WARNED:-false}" != "true" ]]; then
            warn "Agent call count reached 100. Pipeline will stop at ${MAX_AUTONOMOUS_AGENT_CALLS:-200}."
            _ORCH_AGENT_100_WARNED=true
        fi

        # --- Progress detection (after first attempt) ---
        if [[ "$_ORCH_ATTEMPT" -gt 1 ]]; then
            if ! _check_progress; then
                warn "Pipeline appears stuck — diff unchanged for 2 consecutive attempts."
                _save_orchestration_state "stuck" "No progress detected across ${_ORCH_NO_PROGRESS_COUNT} attempts"
                return 1
            fi
        fi

        # Status banner
        report_orchestration_status "$_ORCH_ATTEMPT" "${MAX_PIPELINE_ATTEMPTS:-5}" \
            "$_ORCH_ELAPSED" "$_ORCH_AGENT_CALLS"

        # Track agent calls before this iteration
        local _pre_iter_turns="$TOTAL_TURNS"

        # Archive reports from previous iteration (except first)
        if [[ "$_ORCH_ATTEMPT" -gt 1 ]]; then
            for f in "${CODER_SUMMARY_FILE}" "${REVIEWER_REPORT_FILE}" "${JR_CODER_SUMMARY_FILE}" "${TESTER_REPORT_FILE}" "${INTAKE_REPORT_FILE}" "${PREFLIGHT_ERRORS_FILE}"; do
                if [[ -f "$f" ]]; then
                    mkdir -p "${LOG_DIR}/archive"
                    mv "$f" "${LOG_DIR}/archive/$(date +%Y%m%d_%H%M%S)_attempt${_ORCH_ATTEMPT}_$(basename "$f")"
                fi
            done

            # Update log file for new iteration
            TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
            local task_slug
            task_slug=$(echo "$TASK" | head -1 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-50)
            # shellcheck disable=SC2034  # global used by run_agent/finalize
            LOG_FILE="${LOG_DIR}/${TIMESTAMP}_${task_slug}.log"
        fi

        # Check usage threshold before each attempt
        if ! check_usage_threshold; then
            warn "Usage threshold reached. Pausing orchestration loop."
            _save_orchestration_state "usage_threshold" "Usage threshold exceeded"
            return 1
        fi

        # --- Intake gate (per-milestone evaluation) ---
        if declare -f run_stage_intake &>/dev/null; then
            run_stage_intake || true
        fi

        # --- Run the pipeline ---
        local pipeline_exit=0
        _run_pipeline_stages || pipeline_exit=$?

        # Update agent call count from the global invocation counter (set by run_agent)
        local _iter_turns=$(( TOTAL_TURNS - _pre_iter_turns ))
        _ORCH_AGENT_CALLS="${TOTAL_AGENT_INVOCATIONS:-0}"

        local _files_changed
        _files_changed=$(git diff --name-only HEAD 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")

        # Dispatch to the per-iteration outcome handlers. They use a return-code
        # convention (0=re-loop, 10=exit success, 11=exit failure) so this loop
        # can stay short and the heavy success/failure logic lives next door in
        # orchestrate_loop.sh.
        local _outcome=0
        if [[ "$pipeline_exit" -eq 0 ]]; then
            _handle_pipeline_success "$_iter_turns" "$_files_changed" || _outcome=$?
        else
            _handle_pipeline_failure "$_iter_turns" "$_files_changed" || _outcome=$?
        fi

        case "$_outcome" in
            10) return 0 ;;
            11) return 1 ;;
            0)  ;;
            *)
                error "Unexpected outcome from iteration handler: ${_outcome}"
                return 1
                ;;
        esac
    done
}
