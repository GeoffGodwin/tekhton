#!/usr/bin/env bash
# =============================================================================
# orchestrate_complete.sh — _orch_complete_run implementation
#
# m19: replaces the deleted lib/orchestrate_main.sh. The Go runner
# (internal/runner.RunCompleteLoop) is the canonical owner of the outer retry
# loop; this bash function exists only because tekhton.sh has not been flipped
# to dispatch through `tekhton run --complete` yet (m20). When that flip
# lands, this file goes away.
#
# Function rename rationale: m19 AC bans the legacy name in
# lib/ stages/ tekhton.sh. The bash body is otherwise unchanged — same
# semantics, same global vars, same _orch_record_save_state callers.
#
# Sourced by orchestrate.sh — do not run directly.
# =============================================================================
set -euo pipefail

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


# --- The outer loop -----------------------------------------------------------

# _orch_complete_run
# Entry point for --complete mode. Wraps pipeline execution in a retry loop.
# Handles milestone and non-milestone tasks.
_orch_complete_run() {
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
    # M130: reset persistent retry guards once per --complete invocation.
    if declare -f _reset_orch_recovery_state &>/dev/null; then
        _reset_orch_recovery_state
    fi

    # Restore orchestration state from prior run (resume support)
    if [[ -f "${PIPELINE_STATE_FILE:-}" ]]; then
        local _saved_exit_reason _saved_attempt _saved_calls
        _saved_exit_reason=$(read_pipeline_state_field exit_reason)
        _saved_attempt=$(read_pipeline_state_field pipeline_attempt)
        _saved_calls=$(read_pipeline_state_field agent_calls_total)

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

    if _should_capture_test_baseline 2>/dev/null; then
        capture_test_baseline "${_CURRENT_MILESTONE:-}" || true
    fi

    if declare -f test_dedup_reset &>/dev/null; then
        test_dedup_reset
    fi

    if [[ "$MILESTONE_MODE" = true ]] && [[ -n "${_CURRENT_MILESTONE:-}" ]]; then
        emit_milestone_metadata "$_CURRENT_MILESTONE" "in_progress" || true
        if command -v emit_dashboard_milestones &>/dev/null; then
            emit_dashboard_milestones 2>/dev/null || true
        fi
    fi

    while true; do
        _ORCH_ATTEMPT=$(( _ORCH_ATTEMPT + 1 ))
        out_set_context attempt      "$_ORCH_ATTEMPT"
        out_set_context max_attempts "${MAX_PIPELINE_ATTEMPTS:-5}"
        _ORCH_ELAPSED=$(( $(date +%s) - _ORCH_START_TIME ))

        if declare -f reset_failure_cause_context &>/dev/null; then
            reset_failure_cause_context
        fi

        if [[ "${CAUSAL_LOG_ENABLED:-true}" = "true" ]] && [[ -f "${CAUSAL_LOG_FILE:-}" ]]; then
            _ORCH_CAUSAL_LOG_BASELINE=$(wc -l < "$CAUSAL_LOG_FILE" 2>/dev/null || echo 0)
        else
            _ORCH_CAUSAL_LOG_BASELINE=0
        fi

        # --- Safety bound: wall-clock timeout (checked at TOP of iteration) ---
        if [[ "$_ORCH_ELAPSED" -ge "${AUTONOMOUS_TIMEOUT:-7200}" ]]; then
            warn "Reached AUTONOMOUS_TIMEOUT (${AUTONOMOUS_TIMEOUT:-7200}s). Saving state."
            _orch_record_save_state "timeout" "Wall-clock timeout after ${_ORCH_ELAPSED}s"
            return 1
        fi

        if [[ "$_ORCH_ATTEMPT" -gt "${MAX_PIPELINE_ATTEMPTS:-5}" ]]; then
            warn "Reached MAX_PIPELINE_ATTEMPTS (${MAX_PIPELINE_ATTEMPTS:-5} consecutive failures). Saving state."
            _orch_record_save_state "max_attempts" "Exhausted ${MAX_PIPELINE_ATTEMPTS:-5} consecutive failure attempts"
            return 1
        fi

        if [[ "$_ORCH_AGENT_CALLS" -ge "${MAX_AUTONOMOUS_AGENT_CALLS:-200}" ]]; then
            error "Reached MAX_AUTONOMOUS_AGENT_CALLS (${MAX_AUTONOMOUS_AGENT_CALLS:-200}). This is a safety valve — something may be wrong. Saving state."
            _orch_record_save_state "agent_cap" "Agent call cap (${MAX_AUTONOMOUS_AGENT_CALLS:-200}) reached"
            return 1
        fi
        if [[ "$_ORCH_AGENT_CALLS" -ge 100 ]] && [[ "${_ORCH_AGENT_100_WARNED:-false}" != "true" ]]; then
            warn "Agent call count reached 100. Pipeline will stop at ${MAX_AUTONOMOUS_AGENT_CALLS:-200}."
            _ORCH_AGENT_100_WARNED=true
        fi

        if [[ "$_ORCH_ATTEMPT" -gt 1 ]]; then
            if ! _check_progress; then
                warn "Pipeline appears stuck — diff unchanged for 2 consecutive attempts."
                _orch_record_save_state "stuck" "No progress detected across ${_ORCH_NO_PROGRESS_COUNT} attempts"
                return 1
            fi
        fi

        report_orchestration_status "$_ORCH_ATTEMPT" "${MAX_PIPELINE_ATTEMPTS:-5}" \
            "$_ORCH_ELAPSED" "$_ORCH_AGENT_CALLS"

        local _pre_iter_turns="$TOTAL_TURNS"

        if [[ "$_ORCH_ATTEMPT" -gt 1 ]]; then
            for f in "${CODER_SUMMARY_FILE}" "${REVIEWER_REPORT_FILE}" "${JR_CODER_SUMMARY_FILE}" "${TESTER_REPORT_FILE}" "${INTAKE_REPORT_FILE}" "${PREFLIGHT_ERRORS_FILE}"; do
                if [[ -f "$f" ]]; then
                    mkdir -p "${LOG_DIR}/archive"
                    mv "$f" "${LOG_DIR}/archive/$(date +%Y%m%d_%H%M%S)_attempt${_ORCH_ATTEMPT}_$(basename "$f")"
                fi
            done

            TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
            local task_slug
            task_slug=$(echo "$TASK" | head -1 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-50)
            # shellcheck disable=SC2034  # global used by run_agent/finalize
            LOG_FILE="${LOG_DIR}/${TIMESTAMP}_${task_slug}.log"
        fi

        if ! check_usage_threshold; then
            warn "Usage threshold reached. Pausing orchestration loop."
            _orch_record_save_state "usage_threshold" "Usage threshold exceeded"
            return 1
        fi

        if declare -f run_stage_intake &>/dev/null; then
            run_stage_intake || true
        fi

        local pipeline_exit=0
        _run_pipeline_stages || pipeline_exit=$?

        local _iter_turns=$(( TOTAL_TURNS - _pre_iter_turns ))
        _ORCH_AGENT_CALLS="${TOTAL_AGENT_INVOCATIONS:-0}"

        local _files_changed
        _files_changed=$(git diff --name-only HEAD 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")

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
