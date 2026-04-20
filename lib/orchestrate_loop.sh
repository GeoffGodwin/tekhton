#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# orchestrate_loop.sh — Pipeline iteration outcome handlers.
#
# Extracted from orchestrate.sh to keep that file under the 300-line ceiling.
# Sourced by orchestrate.sh — do not run directly.
#
# These helpers encode the outcome of a single _run_pipeline_stages() call:
#   _run_preflight_test_gate    — pre-finalization TEST_CMD gate
#   _handle_pipeline_success    — pipeline_exit == 0 branch
#   _handle_pipeline_failure    — pipeline_exit != 0 branch
#
# Return-code convention used by the outcome handlers (consumed by
# run_complete_loop in orchestrate.sh):
#     0   continue the outer while-loop
#    10   caller should `return 0` (full success — exit run_complete_loop)
#    11   caller should `return 1` (non-recoverable failure — exit loop)
# =============================================================================

# _run_preflight_test_gate ITER_TURNS FILES_CHANGED
# Runs TEST_CMD before finalize_run() so failures feed back into the retry
# loop instead of being swallowed by _hook_final_checks. Sets
# _PREFLIGHT_TESTS_PASSED so finalization can skip the redundant re-run.
# Returns 0 when tests pass (or skipped/fixed), 1 when caller should re-loop.
_run_preflight_test_gate() {
    local _iter_turns="$1"
    local _files_changed="$2"

    _PREFLIGHT_TESTS_PASSED=false
    export _PREFLIGHT_TESTS_PASSED

    [[ "${SKIP_FINAL_CHECKS:-false}" != true ]] || return 0
    [[ -n "${TEST_CMD:-}" ]] || return 0

    log "Pre-finalization test gate: running ${TEST_CMD}..."
    local _preflight_exit=0
    local _preflight_output=""
    if declare -f test_dedup_can_skip &>/dev/null && test_dedup_can_skip; then
        log "[dedup] Tests passed with no file changes since last run — skipping"
        if command -v emit_event &>/dev/null; then
            emit_event "test_dedup_skip" "${_CURRENT_STAGE:-pre_finalization}" \
                "fingerprint_match=true" "" "" "" >/dev/null 2>&1 || true
        fi
        _preflight_output="[dedup] Cached pass — no files changed since last successful test run"
        _preflight_exit=0
    else
        _preflight_output=$(run_op "Verifying tests before finalizing" bash -c "${TEST_CMD}" 2>&1) || _preflight_exit=$?
        if [[ "$_preflight_exit" -eq 0 ]] && declare -f test_dedup_record_pass &>/dev/null; then
            test_dedup_record_pass
        fi
    fi
    printf '%s\n' "$_preflight_output" >> "$LOG_FILE"

    if [[ "$_preflight_exit" -ne 0 ]]; then
        local _preflight_baseline="none"
        if [[ "${TEST_BASELINE_ENABLED:-true}" = "true" ]] && \
           command -v compare_test_with_baseline &>/dev/null; then
            _preflight_baseline=$(compare_test_with_baseline "$_preflight_output" "$_preflight_exit")
        fi

        if [[ "$_preflight_baseline" = "pre_existing" ]] && \
           [[ "${TEST_BASELINE_PASS_ON_PREEXISTING:-false}" = "true" ]]; then
            warn "Pre-finalization test gate failed (exit ${_preflight_exit}) — ALL failures match pre-existing baseline."
            warn "Treating as PASS (PASS_ON_PREEXISTING=true opt-in)."
        else
            # M44: Try cheap Jr Coder fix before expensive full retry
            log_decision "Trying preflight fix" "${_preflight_exit} test failures detected" "FINAL_FIX_ENABLED=${FINAL_FIX_ENABLED:-true}"
            if _try_preflight_fix "$_preflight_output" "$_preflight_exit"; then
                _PREFLIGHT_TESTS_PASSED=true
                [[ -f "${PREFLIGHT_ERRORS_FILE}" ]] && rm -f "${PREFLIGHT_ERRORS_FILE}"
                log "Pre-finalization fix succeeded — proceeding to finalization."
            else
                warn "Pre-finalization test gate failed (exit ${_preflight_exit}). Routing back to coder for fix."
                {
                    echo "# Pre-Finalization Test Failures"
                    echo "Command: \`${TEST_CMD}\` exited with code ${_preflight_exit}"
                    echo ""
                    echo "## Output (last 80 lines)"
                    echo '```'
                    printf '%s\n' "$_preflight_output" | tail -80
                    echo '```'
                } > "${PREFLIGHT_ERRORS_FILE}"
                log "Wrote preflight test errors to ${PREFLIGHT_ERRORS_FILE}"
                record_pipeline_attempt "${_CURRENT_MILESTONE:-none}" "$_ORCH_ATTEMPT" \
                    "failed:final_check/test_failure" "$_iter_turns" "$_files_changed"
                START_AT="coder"
                return 1
            fi
        fi
    fi
    _PREFLIGHT_TESTS_PASSED=true
    [[ -f "${PREFLIGHT_ERRORS_FILE}" ]] && rm -f "${PREFLIGHT_ERRORS_FILE}"
    return 0
}

# _handle_pipeline_success ITER_TURNS FILES_CHANGED
# Branch taken when _run_pipeline_stages() exited 0. Checks acceptance, runs
# stuck detection, runs the preflight test gate, and finalizes on success.
# Returns 0 (re-loop), 10 (run_complete_loop should return 0), or 11 (return 1).
_handle_pipeline_success() {
    local _iter_turns="$1"
    local _files_changed="$2"

    # M91: any pipeline success resets the consecutive-max_turns escalation counter.
    _update_escalation_counter "${START_AT:-}" "" "" || true

    local acceptance_pass=true
    if [[ "$MILESTONE_MODE" = true ]] && [[ -n "${_CURRENT_MILESTONE:-}" ]]; then
        check_milestone_acceptance "$_CURRENT_MILESTONE" "CLAUDE.md" || acceptance_pass=false
    else
        # Non-milestone: invariant means this is unreachable on exit 0 from any
        # well-behaved stage; SKIP_FINAL_CHECKS is the safety net for tester.sh
        # API-error returns.
        if [[ "${SKIP_FINAL_CHECKS:-false}" = true ]]; then
            acceptance_pass=false
        fi
    fi

    record_pipeline_attempt "${_CURRENT_MILESTONE:-none}" "$_ORCH_ATTEMPT" \
        "success" "$_iter_turns" "$_files_changed"

    # Tier 2: acceptance-failure stuck detection
    if [[ "$acceptance_pass" = false ]] && [[ "${TEST_BASELINE_ENABLED:-true}" = "true" ]]; then
        local _stuck_result=0
        _check_acceptance_stuck || _stuck_result=$?
        case "$_stuck_result" in
            0)  acceptance_pass=true
                warn "Acceptance overridden by stuck detection (auto-pass)."
                ;;
            2)  _save_orchestration_state "pre_existing_failure" \
                    "Acceptance stuck on identical pre-existing test failures (${_ORCH_IDENTICAL_ACCEPTANCE_COUNT} attempts)"
                return 11
                ;;
            *)  ;;
        esac
    fi

    if [[ "$acceptance_pass" = true ]]; then
        _run_preflight_test_gate "$_iter_turns" "$_files_changed" || return 0

        local _should_advance=false
        if [[ "$MILESTONE_MODE" = true ]] && [[ -n "${_CURRENT_MILESTONE:-}" ]]; then
            local _next_ms
            _next_ms=$(find_next_milestone "$_CURRENT_MILESTONE" "${PROJECT_RULES_FILE:-CLAUDE.md}")
            if [[ -n "$_next_ms" ]]; then
                write_milestone_disposition "COMPLETE_AND_CONTINUE"
            else
                write_milestone_disposition "COMPLETE_AND_WAIT"
            fi
            # Cache auto-advance decision BEFORE finalize_run deletes state file
            if should_auto_advance 2>/dev/null; then
                _should_advance=true
            fi
        fi

        finalize_run 0

        # M16: Milestone success resets attempt counter — productive work
        # should not be penalized by prior failures.
        if [[ "$MILESTONE_MODE" = true ]]; then
            _ORCH_ATTEMPT=0
            _ORCH_NO_PROGRESS_COUNT=0
            log "Milestone complete. Resetting attempt counter."
        fi

        if [[ "$_should_advance" = true ]]; then
            _run_auto_advance_chain
        fi

        return 10
    fi

    warn "Acceptance criteria not met. Re-running pipeline (attempt ${_ORCH_ATTEMPT}/${MAX_PIPELINE_ATTEMPTS:-5})..."
    if [[ "$MILESTONE_MODE" = true ]] && [[ -n "${_CURRENT_MILESTONE:-}" ]]; then
        write_milestone_disposition "INCOMPLETE_REWORK"
    fi
    START_AT="coder"
    return 0
}

# _handle_pipeline_failure ITER_TURNS FILES_CHANGED
# Branch taken when _run_pipeline_stages() exited non-zero. Classifies the
# failure and routes to one of the recovery strategies. Reads/writes
# _ORCH_BUILD_RETRIED to enforce the one-shot build-fix retry policy.
# Returns 0 (re-loop) or 11 (run_complete_loop should return 1).
_handle_pipeline_failure() {
    local _iter_turns="$1"
    local _files_changed="$2"

    record_pipeline_attempt "${_CURRENT_MILESTONE:-none}" "$_ORCH_ATTEMPT" \
        "failed:${AGENT_ERROR_CATEGORY:-unknown}/${AGENT_ERROR_SUBCATEGORY:-unknown}" \
        "$_iter_turns" "$_files_changed"

    # M91: refresh the consecutive-max_turns counter before the recovery dispatch
    _update_escalation_counter "${START_AT:-}" "${AGENT_ERROR_CATEGORY:-}" "${AGENT_ERROR_SUBCATEGORY:-}" || true

    local recovery
    recovery=$(_classify_failure)
    log_decision "Recovery: ${recovery}" "failure class ${AGENT_ERROR_CATEGORY:-unknown}/${AGENT_ERROR_SUBCATEGORY:-unknown}" ""

    case "$recovery" in
        bump_review)
            if [[ "$_ORCH_REVIEW_BUMPED" = true ]]; then
                warn "Review cycles already bumped once. Saving state and exiting."
                _save_orchestration_state "review_exhausted" "Review cycle max even after bump"
                return 11
            fi
            MAX_REVIEW_CYCLES=$(( MAX_REVIEW_CYCLES + 2 ))
            _ORCH_REVIEW_BUMPED=true
            warn "Bumping MAX_REVIEW_CYCLES to ${MAX_REVIEW_CYCLES} (one-time)"
            START_AT="review"
            return 0
            ;;
        retry_coder_build)
            if [[ "${_ORCH_BUILD_RETRIED:-false}" = true ]]; then
                warn "Build fix already retried. Saving state and exiting."
                _save_orchestration_state "build_exhausted" "Build failure persists after retry"
                return 11
            fi
            _ORCH_BUILD_RETRIED=true
            warn "Retrying from coder stage with build errors context."
            # shellcheck disable=SC2034  # global used by loop iteration
            START_AT="coder"
            return 0
            ;;
        split)
            # M91: Before giving up, try adaptive turn-budget escalation —
            # but only for max_turns (not null_run). Split's already exhausted
            # so retrying with MORE turns on the same stage is the last lever.
            if [[ "${AGENT_ERROR_SUBCATEGORY:-}" = "max_turns" ]] \
               && [[ "$_ORCH_CONSECUTIVE_MAX_TURNS" -gt 0 ]] \
               && _can_escalate_further; then
                _apply_turn_escalation "$_ORCH_CONSECUTIVE_MAX_TURNS"
                START_AT="${_ORCH_MAX_TURNS_STAGE:-coder}"
                return 0
            fi
            warn "Split/continuation exhausted. Saving state."
            _save_orchestration_state "split_exhausted" "Turn exhaustion or null run after recovery attempts"
            return 11
            ;;
        save_exit|*)
            # Unclassified, upstream sustained, environment, pipeline internal,
            # REPLAN_REQUIRED — all save state and exit.
            local reason="${AGENT_ERROR_CATEGORY:-unclassified}/${AGENT_ERROR_SUBCATEGORY:-unknown}"
            if [[ "${VERDICT:-}" = "REPLAN_REQUIRED" ]]; then
                reason="replan_required"
            fi
            _save_orchestration_state "$reason" "Non-recoverable: ${reason}"
            return 11
            ;;
    esac
}
