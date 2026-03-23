#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# orchestrate.sh — Outer orchestration loop for --complete mode (Milestone 16)
#
# Wraps _run_pipeline_stages() in a retry-with-recovery loop. Contract:
# run this milestone until it passes acceptance or all recovery options
# are exhausted.
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

# --- Orchestration state globals -----------------------------------------------
_ORCH_ATTEMPT=0
_ORCH_AGENT_CALLS=0
_ORCH_START_TIME=0
_ORCH_ELAPSED=0
_ORCH_ATTEMPT_LOG=""
_ORCH_REVIEW_BUMPED=false
_ORCH_LAST_DIFF_HASH=""
_ORCH_NO_PROGRESS_COUNT=0

export _ORCH_ATTEMPT _ORCH_AGENT_CALLS _ORCH_ELAPSED _ORCH_ATTEMPT_LOG


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
    local _build_retried=false

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

    # Emit milestone metadata on start (if milestone mode)
    if [[ "$MILESTONE_MODE" = true ]] && [[ -n "${_CURRENT_MILESTONE:-}" ]]; then
        emit_milestone_metadata "$_CURRENT_MILESTONE" "in_progress" || true
    fi

    while true; do
        _ORCH_ATTEMPT=$(( _ORCH_ATTEMPT + 1 ))
        _ORCH_ELAPSED=$(( $(date +%s) - _ORCH_START_TIME ))

        # --- Safety bound: wall-clock timeout (checked at TOP of iteration) ---
        if [[ "$_ORCH_ELAPSED" -ge "${AUTONOMOUS_TIMEOUT:-7200}" ]]; then
            warn "Reached AUTONOMOUS_TIMEOUT (${AUTONOMOUS_TIMEOUT:-7200}s). Saving state."
            _save_orchestration_state "timeout" "Wall-clock timeout after ${_ORCH_ELAPSED}s"
            return 1
        fi

        # --- Safety bound: max attempts ---
        if [[ "$_ORCH_ATTEMPT" -gt "${MAX_PIPELINE_ATTEMPTS:-5}" ]]; then
            warn "Reached MAX_PIPELINE_ATTEMPTS (${MAX_PIPELINE_ATTEMPTS:-5}). Saving state."
            _save_orchestration_state "max_attempts" "Exhausted ${MAX_PIPELINE_ATTEMPTS:-5} attempts"
            return 1
        fi

        # --- Safety bound: agent call cap ---
        if [[ "$_ORCH_AGENT_CALLS" -ge "${MAX_AUTONOMOUS_AGENT_CALLS:-20}" ]]; then
            warn "Reached MAX_AUTONOMOUS_AGENT_CALLS (${MAX_AUTONOMOUS_AGENT_CALLS:-20}). Saving state."
            _save_orchestration_state "agent_cap" "Agent call cap (${MAX_AUTONOMOUS_AGENT_CALLS:-20}) reached"
            return 1
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
            for f in CODER_SUMMARY.md REVIEWER_REPORT.md JR_CODER_SUMMARY.md TESTER_REPORT.md INTAKE_REPORT.md; do
                if [[ -f "$f" ]]; then
                    mkdir -p "${LOG_DIR}/archive"
                    mv "$f" "${LOG_DIR}/archive/$(date +%Y%m%d_%H%M%S)_attempt${_ORCH_ATTEMPT}_${f}"
                fi
            done

            # Update log file for new iteration
            TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
            local task_slug
            task_slug=$(echo "$TASK" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-50)
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

        if [[ "$pipeline_exit" -eq 0 ]]; then
            # Pipeline succeeded — check acceptance
            local acceptance_pass=true

            if [[ "$MILESTONE_MODE" = true ]] && [[ -n "${_CURRENT_MILESTONE:-}" ]]; then
                check_milestone_acceptance "$_CURRENT_MILESTONE" "CLAUDE.md" || acceptance_pass=false
            else
                # Non-milestone: acceptance = build gate passes (already checked by pipeline)
                # Invariant: A null run from a stage already sets non-zero exit before reaching
                # here, so this check is normally unreachable on exit 0. However, API-error
                # paths in tester.sh return (not exit), which can theoretically reach this
                # code with SKIP_FINAL_CHECKS=true. This guard is a safety net for that edge case.
                if [[ "${SKIP_FINAL_CHECKS:-false}" = true ]]; then
                    acceptance_pass=false
                fi
            fi

            record_pipeline_attempt "${_CURRENT_MILESTONE:-none}" "$_ORCH_ATTEMPT" \
                "success" "$_iter_turns" "$_files_changed"

            if [[ "$acceptance_pass" = true ]]; then
                # --- SUCCESS ---
                if [[ "$MILESTONE_MODE" = true ]] && [[ -n "${_CURRENT_MILESTONE:-}" ]]; then
                    local _next_ms
                    _next_ms=$(find_next_milestone "$_CURRENT_MILESTONE" "CLAUDE.md")
                    if [[ -n "$_next_ms" ]]; then
                        write_milestone_disposition "COMPLETE_AND_CONTINUE"
                    else
                        write_milestone_disposition "COMPLETE_AND_WAIT"
                    fi
                fi

                finalize_run 0

                # Handle auto-advance after successful completion
                if [[ "$MILESTONE_MODE" = true ]] && should_auto_advance 2>/dev/null; then
                    _run_auto_advance_chain
                fi

                return 0
            fi

            # Acceptance failed but pipeline succeeded — full retry from coder
            warn "Acceptance criteria not met. Re-running pipeline (attempt ${_ORCH_ATTEMPT}/${MAX_PIPELINE_ATTEMPTS:-5})..."
            if [[ "$MILESTONE_MODE" = true ]] && [[ -n "${_CURRENT_MILESTONE:-}" ]]; then
                write_milestone_disposition "INCOMPLETE_REWORK"
            fi
            START_AT="coder"
            continue

        else
            # Pipeline failed — diagnose and recover
            record_pipeline_attempt "${_CURRENT_MILESTONE:-none}" "$_ORCH_ATTEMPT" \
                "failed:${AGENT_ERROR_CATEGORY:-unknown}/${AGENT_ERROR_SUBCATEGORY:-unknown}" \
                "$_iter_turns" "$_files_changed"

            local recovery
            recovery=$(_classify_failure)
            log "Recovery decision: ${recovery}"

            case "$recovery" in
                bump_review)
                    if [[ "$_ORCH_REVIEW_BUMPED" = true ]]; then
                        warn "Review cycles already bumped once. Saving state and exiting."
                        _save_orchestration_state "review_exhausted" "Review cycle max even after bump"
                        return 1
                    fi
                    MAX_REVIEW_CYCLES=$(( MAX_REVIEW_CYCLES + 2 ))
                    _ORCH_REVIEW_BUMPED=true
                    warn "Bumping MAX_REVIEW_CYCLES to ${MAX_REVIEW_CYCLES} (one-time)"
                    START_AT="review"
                    continue
                    ;;
                retry_coder_build)
                    if [[ "$_build_retried" = true ]]; then
                        warn "Build fix already retried. Saving state and exiting."
                        _save_orchestration_state "build_exhausted" "Build failure persists after retry"
                        return 1
                    fi
                    _build_retried=true
                    warn "Retrying from coder stage with build errors context."
                    # shellcheck disable=SC2034  # global used by loop iteration
                    START_AT="coder"
                    continue
                    ;;
                split)
                    # M11 handles splitting automatically. If we get here, it already
                    # tried. Save state and exit.
                    warn "Split/continuation exhausted. Saving state."
                    _save_orchestration_state "split_exhausted" "Turn exhaustion or null run after recovery attempts"
                    return 1
                    ;;
                save_exit|*)
                    # Unclassified, upstream sustained, environment, pipeline internal,
                    # REPLAN_REQUIRED — all save state and exit.
                    local reason="${AGENT_ERROR_CATEGORY:-unclassified}/${AGENT_ERROR_SUBCATEGORY:-unknown}"
                    if [[ "${VERDICT:-}" = "REPLAN_REQUIRED" ]]; then
                        reason="replan_required"
                    fi
                    _save_orchestration_state "$reason" "Non-recoverable: ${reason}"
                    return 1
                    ;;
            esac
        fi
    done
}
