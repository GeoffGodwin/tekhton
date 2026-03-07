#!/usr/bin/env bash
# =============================================================================
# state.sh — Pipeline state persistence for resume support
#
# Sourced by tekhton.sh — do not run directly.
# Expects: PIPELINE_STATE_FILE (set by caller)
# Expects: log() from common.sh
# =============================================================================

write_pipeline_state() {
    local exit_stage="$1"
    local exit_reason="$2"
    local resume_flag="$3"
    local resume_task="$4"
    local extra_notes="$5"

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

## Files Present
$(for f in CODER_SUMMARY.md REVIEWER_REPORT.md TESTER_REPORT.md JR_CODER_SUMMARY.md; do
    [ -f "$f" ] && echo "- $f ($(wc -l < "$f" | tr -d '[:space:]') lines)" || echo "- $f (missing)"
done)
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
    [ -f "$PIPELINE_STATE_FILE" ] && rm "$PIPELINE_STATE_FILE"
}
