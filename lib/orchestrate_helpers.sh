#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# orchestrate_helpers.sh — Helper functions for the orchestration loop
#
# Extracted from orchestrate.sh to stay under the 300-line ceiling.
# Sourced by orchestrate.sh — do not run directly.
# =============================================================================

# --- Auto-advance chain (reused from existing logic) --------------------------

_run_auto_advance_chain() {
    while should_auto_advance 2>/dev/null; do
        local next_ms
        next_ms=$(find_next_milestone "$_CURRENT_MILESTONE" "CLAUDE.md")
        if [[ -z "$next_ms" ]]; then
            log "No more milestones to advance to."
            write_milestone_disposition "COMPLETE_AND_WAIT"
            break
        fi

        local next_title
        next_title=$(get_milestone_title "$next_ms")

        if [[ "${AUTO_ADVANCE_CONFIRM:-true}" = "true" ]]; then
            if ! prompt_auto_advance_confirm "$next_ms" "$next_title"; then
                log "Auto-advance declined by user."
                write_milestone_disposition "COMPLETE_AND_WAIT"
                break
            fi
        fi

        advance_milestone "$_CURRENT_MILESTONE" "$next_ms"
        _CURRENT_MILESTONE="$next_ms"
        TASK="Implement Milestone ${_CURRENT_MILESTONE}: ${next_title}"
        START_AT="coder"

        # M16: Reset per-milestone tracking — successful milestone is forward progress
        _ORCH_REVIEW_BUMPED=false
        _ORCH_ATTEMPT=0
        _ORCH_NO_PROGRESS_COUNT=0

        emit_milestone_metadata "$_CURRENT_MILESTONE" "in_progress" || true

        # Re-enter the complete loop for the new milestone.
        # Recursion depth is bounded by AUTO_ADVANCE_LIMIT (default 3) — the
        # should_auto_advance() guard at the top of this while loop exits once
        # the session count reaches the limit.
        run_complete_loop
        return $?
    done
}

# --- State persistence helper -------------------------------------------------

_save_orchestration_state() {
    local outcome="$1"
    local detail="$2"

    _ORCH_ELAPSED=$(( $(date +%s) - _ORCH_START_TIME ))

    # Run finalize hooks for failure path (metrics, archiving, but no commit)
    finalize_run 1

    # Build resume command with appropriate flags
    local resume_flags="--complete"
    if [[ "$MILESTONE_MODE" = true ]]; then
        resume_flags="--complete --milestone"
    fi
    resume_flags="${resume_flags} --start-at ${START_AT}"

    write_pipeline_state \
        "${START_AT}" \
        "complete_loop_${outcome}" \
        "$resume_flags" \
        "$TASK" \
        "Orchestration: ${detail} (attempt ${_ORCH_ATTEMPT}/${MAX_PIPELINE_ATTEMPTS:-5}, ${_ORCH_ELAPSED}s elapsed, ${_ORCH_AGENT_CALLS} agent calls)" \
        "${_CURRENT_MILESTONE:-}"

    warn "State saved. Resume with: tekhton ${resume_flags} \"${TASK}\""
}
