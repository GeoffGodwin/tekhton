#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# orchestrate_state.sh — _save_orchestration_state and recovery-block glue
#
# m12: renamed from orchestrate_state_save.sh as part of the bash relocation
# cutover.
# Sourced by orchestrate_aux.sh — do not run directly.
#
# Provides:
#   _save_orchestration_state OUTCOME DETAIL
#
# Drives finalize_run(1), picks the smartest resume target, writes
# PIPELINE_STATE, and prints the M94 recovery block (with M130 cause_summary).
# =============================================================================

_save_orchestration_state() {
    local outcome="$1"
    local detail="$2"

    _ORCH_ELAPSED=$(( $(date +%s) - _ORCH_START_TIME ))

    # Run finalize hooks for failure path (metrics, archiving, but no commit)
    finalize_run 1

    # M93: Pick the smartest --start-at given what's on disk / archived.
    # _choose_resume_start_at sets _RESUME_NEW_START_AT and may also set
    # _RESUME_RESTORED_ARTIFACT after copying an archived report back into place.
    _choose_resume_start_at

    # Build resume command with appropriate flags
    local resume_flags="--complete"
    if [[ "$MILESTONE_MODE" = true ]]; then
        resume_flags="--complete --milestone"
    fi
    resume_flags="${resume_flags} --start-at ${_RESUME_NEW_START_AT}"

    # Safety-bound exits (max_attempts, timeout, agent_cap) should write zeroed
    # counters so the next invocation starts with a fresh budget. The counter in
    # the state file is what gets restored on resume — if we write the exhausted
    # value, the next run would immediately re-hit the same bound.
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

    # M129: append primary/secondary causal summary when slots populated.
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

    # Restore for metrics/logging if anything reads them after this
    _ORCH_ATTEMPT="$_saved_attempt"
    _ORCH_AGENT_CALLS="$_saved_calls"

    warn "State saved. Resume with: tekhton ${resume_flags} \"${TASK}\""

    # M94: inline recovery block — always present, zero dependencies.
    if command -v _print_recovery_block &>/dev/null; then
        # M130: assemble cause_summary from primary/secondary cause vars so the
        # block can print "Root cause: ..." next to "WHAT HAPPENED".
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
