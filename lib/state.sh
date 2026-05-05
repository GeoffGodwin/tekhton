#!/usr/bin/env bash
# state.sh — m03 wedge shim for PIPELINE_STATE_FILE. Writer logic lives in
# state_helpers.sh + `tekhton state` (on-disk: tekhton.state.v1). Valid
# exit_stage values: intake, coder, review, tester, cleanup, architect, QUOTA_PAUSED.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/state_helpers.sh"

_build_resume_flag() {
    local start_at="${1:-coder}" flag=""
    [[ "${HUMAN_MODE:-false}" = "true" ]] && flag="--human${HUMAN_NOTES_TAG:+ $HUMAN_NOTES_TAG}"
    [[ -z "$flag" && "${MILESTONE_MODE:-false}" = "true" ]] && flag="--milestone"
    echo "${flag:+$flag }--start-at $start_at"
}

write_pipeline_state() {
    _state_write_snapshot "$@" || return $?
    log "Pipeline state saved → ${PIPELINE_STATE_FILE}"
}

read_pipeline_state_field() {
    local path field
    if [[ $# -ge 2 ]]; then path="$1"; field="$2"
    else                    path="$PIPELINE_STATE_FILE"; field="$1"; fi
    [[ -f "$path" ]] || return 0
    if command -v tekhton >/dev/null 2>&1; then
        tekhton state read --path "$path" --field "$field" 2>/dev/null || true
    else
        _state_bash_read_field "$path" "$field"
    fi
}

clear_pipeline_state() {
    if command -v tekhton >/dev/null 2>&1; then
        tekhton state clear --path "$PIPELINE_STATE_FILE" 2>/dev/null || true
    elif [[ -f "$PIPELINE_STATE_FILE" ]]; then
        rm -f "$PIPELINE_STATE_FILE" 2>/dev/null || true
    fi
    local fctx="${PROJECT_DIR:-.}/.claude/LAST_FAILURE_CONTEXT.json"
    [[ -f "$fctx" ]] && rm -f "$fctx" 2>/dev/null
    return 0
}

load_intake_tweaked_task() {
    local f="${TEKHTON_SESSION_DIR:-/tmp}/INTAKE_TWEAKED_TASK.md"
    [[ -f "$f" ]] || return 1
    local t; t=$(cat "$f")
    [[ -n "$t" ]] || return 1
    TASK="$t"; export TASK
    log "Loaded tweaked task from prior intake evaluation."
}
