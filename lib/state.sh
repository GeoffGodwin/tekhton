#!/usr/bin/env bash
# =============================================================================
# state.sh — Pipeline state persistence for resume support
#
# Sourced by tekhton.sh — do not run directly.
# Expects: PIPELINE_STATE_FILE (set by caller)
# Expects: log() from common.sh
# =============================================================================

# Valid pipeline states for exit_stage:
# intake, coder, review, tester, cleanup, architect, QUOTA_PAUSED

write_pipeline_state() {
    local exit_stage="$1"
    local exit_reason="$2"
    local resume_flag="$3"
    local resume_task="$4"
    local extra_notes="${5:-}"
    local milestone_num="${6:-}"

    # Strip any surrounding quotes from task — they break heredoc and awk reads
    resume_task="${resume_task#\"}"
    resume_task="${resume_task%\"}"
    # Also strip from resume_flag in case it has embedded quotes
    resume_flag="${resume_flag//\"/}"

    local _state_dir
    _state_dir="$(dirname "$PIPELINE_STATE_FILE")"
    if ! mkdir -p "$_state_dir" 2>/dev/null; then
        warn "Could not create state directory: $_state_dir"
        warn "Resume manually with: --start-at ${exit_stage} \"${resume_task}\""
        return 1
    fi

    # Debug: show exactly what we're writing to and verify the path is clean
    log "State file target: [${PIPELINE_STATE_FILE}]"
    log "State dir: [${_state_dir}] exists=$([ -d "$_state_dir" ] && echo yes || echo no)"

    # Write to a temp file first, then move — avoids partial writes and
    # works around WSL/NTFS redirection quirks
    local _tmp_state
    _tmp_state="$(mktemp "${_state_dir}/pipeline_state.XXXXXX" 2>/dev/null || mktemp /tmp/pipeline_state.XXXXXX)"

    cat > "$_tmp_state" << EOF
# Pipeline State — $(date '+%Y-%m-%d %H:%M:%S')
## Exit Stage
${exit_stage}

## Exit Reason
${exit_reason}

## Resume Command
${resume_flag}

## Task
${resume_task}

## Notes
${extra_notes}

## Milestone
${milestone_num:-none}

## Files Present
$(for f in CODER_SUMMARY.md REVIEWER_REPORT.md TESTER_REPORT.md JR_CODER_SUMMARY.md; do
    [ -f "$f" ] && echo "- $f ($(count_lines < "$f") lines)" || echo "- $f (missing)"
done)

## Orchestration Context
$(if [ -n "${_ORCH_ATTEMPT:-}" ]; then
    echo "Pipeline attempt: ${_ORCH_ATTEMPT}"
    echo "Cumulative agent calls: ${_ORCH_AGENT_CALLS:-0}"
    echo "Cumulative turns: ${TOTAL_TURNS:-0}"
    echo "Wall-clock elapsed: ${_ORCH_ELAPSED:-0}s"
    if [ -n "${_ORCH_ATTEMPT_LOG:-}" ]; then
        echo ""
        echo "### Prior Attempt Outcomes"
        echo "$_ORCH_ATTEMPT_LOG"
    fi
else
    echo "(not in --complete mode)"
fi)

## Error Classification
$(if [ -n "${AGENT_ERROR_CATEGORY:-}" ]; then
    echo "Category: ${AGENT_ERROR_CATEGORY}"
    echo "Subcategory: ${AGENT_ERROR_SUBCATEGORY:-unknown}"
    echo "Transient: ${AGENT_ERROR_TRANSIENT:-false}"
    _state_recovery=$(suggest_recovery "${AGENT_ERROR_CATEGORY}" "${AGENT_ERROR_SUBCATEGORY:-unknown}" 2>/dev/null || echo "Check run log.")
    echo "Recovery: ${_state_recovery}"
    echo ""
    echo "### Last Agent Output (redacted)"
    if [ -f "${TEKHTON_SESSION_DIR:-/tmp}/agent_last_output.txt" ]; then
        tail -10 "${TEKHTON_SESSION_DIR}/agent_last_output.txt" 2>/dev/null | \
            if command -v redact_sensitive &>/dev/null; then redact_sensitive; else cat; fi
    else
        echo "(no output captured)"
    fi
else
    echo "(no error classification — normal exit or pre-classification failure)"
fi)
EOF

    if mv -f "$_tmp_state" "$PIPELINE_STATE_FILE" 2>/dev/null; then
        log "Pipeline state saved → ${PIPELINE_STATE_FILE}"
    else
        warn "Could not write state file: ${PIPELINE_STATE_FILE}"
        warn "Temp file preserved at: ${_tmp_state}"
        warn "Resume manually with: --start-at ${exit_stage} \"${resume_task}\""
        cat "$_tmp_state"  # dump contents so user can see the state
    fi
}

clear_pipeline_state() {
    if [ -f "$PIPELINE_STATE_FILE" ]; then
        rm "$PIPELINE_STATE_FILE"
    fi
    # Clear failure context on successful run (M17)
    local failure_ctx="${PROJECT_DIR:-.}/.claude/LAST_FAILURE_CONTEXT.json"
    if [ -f "$failure_ctx" ]; then
        rm -f "$failure_ctx" 2>/dev/null || true
    fi
}

# load_intake_tweaked_task — On resume, load the tweaked task string from session dir.
# Returns 0 and sets TASK if a tweaked task file exists, 1 otherwise.
load_intake_tweaked_task() {
    local tweaked_file="${TEKHTON_SESSION_DIR}/INTAKE_TWEAKED_TASK.md"
    if [[ -f "$tweaked_file" ]]; then
        local tweaked_task
        tweaked_task=$(cat "$tweaked_file")
        if [[ -n "$tweaked_task" ]]; then
            TASK="$tweaked_task"
            export TASK
            log "Loaded tweaked task from prior intake evaluation."
            return 0
        fi
    fi
    return 1
}
