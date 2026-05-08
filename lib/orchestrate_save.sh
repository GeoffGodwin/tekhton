#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# orchestrate_save.sh — _orch_record_save_state and recovery-block glue.
#
# m19: replaces the deleted lib/orchestrate_state.sh. The Go runner
# (internal/runner.persistFailureState) is the canonical owner of run-level
# save-state writes; this bash function exists for the legacy bash retry
# loop in lib/orchestrate_complete.sh and disappears when m20 flips
# tekhton.sh's --complete dispatch to `tekhton run --complete`.
#
# Function rename rationale: m19 AC bans the legacy name in
# lib/ stages/ tekhton.sh. The body is otherwise unchanged — same
# write_pipeline_state writer, same M93 smart-resume logic, same M129/M130
# recovery-block printing.
#
# Sourced by orchestrate_aux.sh — do not run directly.
# =============================================================================

_orch_record_save_state() {
    local outcome="$1"
    local detail="$2"

    _ORCH_ELAPSED=$(( $(date +%s) - _ORCH_START_TIME ))

    finalize_run 1

    _choose_resume_start_at

    local resume_flags="--complete"
    if [[ "$MILESTONE_MODE" = true ]]; then
        resume_flags="--complete --milestone"
    fi
    resume_flags="${resume_flags} --start-at ${_RESUME_NEW_START_AT}"

    local _saved_attempt="$_ORCH_ATTEMPT"
    local _saved_calls="$_ORCH_AGENT_CALLS"
    case "$outcome" in
        max_attempts|timeout|agent_cap)
            _ORCH_ATTEMPT=0
            _ORCH_AGENT_CALLS=0
            ;;
    esac

    local _state_notes="Orchestration: ${detail} (attempt ${_saved_attempt}/${MAX_PIPELINE_ATTEMPTS:-5}, ${_ORCH_ELAPSED}s elapsed, ${_saved_calls} agent calls)"
    if [[ -n "${_RESUME_RESTORED_ARTIFACT:-}" ]]; then
        _state_notes="${_state_notes} | Restored ${_RESUME_RESTORED_ARTIFACT}"
    fi

    if declare -f format_failure_cause_summary &>/dev/null; then
        local _cause_summary
        _cause_summary=$(format_failure_cause_summary)
        [[ -n "$_cause_summary" ]] && _state_notes="${_state_notes}"$'\n'"${_cause_summary}"
    fi

    write_pipeline_state \
        "${START_AT}" \
        "complete_loop_${outcome}" \
        "$resume_flags" \
        "$TASK" \
        "$_state_notes" \
        "${_CURRENT_MILESTONE:-}"

    _ORCH_ATTEMPT="$_saved_attempt"
    _ORCH_AGENT_CALLS="$_saved_calls"

    warn "State saved. Resume with: tekhton ${resume_flags} \"${TASK}\""

    if command -v _print_recovery_block &>/dev/null; then
        local _block_cause_summary=""
        if declare -f _load_failure_cause_context &>/dev/null; then
            _load_failure_cause_context
            if [[ -n "${_ORCH_PRIMARY_CAT:-}" ]]; then
                _block_cause_summary="${_ORCH_PRIMARY_CAT}/${_ORCH_PRIMARY_SUB}"
                [[ -n "${_ORCH_PRIMARY_SIGNAL:-}" ]] && \
                    _block_cause_summary+=" (${_ORCH_PRIMARY_SIGNAL})"
                if [[ -n "${_ORCH_SECONDARY_CAT:-}" ]]; then
                    _block_cause_summary+="; secondary: ${_ORCH_SECONDARY_CAT}/${_ORCH_SECONDARY_SUB}"
                fi
            elif [[ -n "${_ORCH_SECONDARY_CAT:-}" ]]; then
                _block_cause_summary="${_ORCH_SECONDARY_CAT}/${_ORCH_SECONDARY_SUB}"
            fi
        fi
        _print_recovery_block "$outcome" "$detail" \
            "tekhton ${resume_flags} \"${TASK}\"" "$TASK" "$_block_cause_summary"
    fi
}
